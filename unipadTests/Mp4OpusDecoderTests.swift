#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
@testable import unipad

struct Mp4OpusDecoderTests {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/AudioSafety/\(name).m4a")
    }

    @Test(arguments: ["libopus-48000-1", "libopus-48000-6",
                      "short-table-libopus-48000-1", "short-table-libopus-48000-6"])
    func nativeReadFailureFallsBackWithinTheReservation(_ name: String) throws {
        let url = fixture(name)
        let facts = try #require(AudioFileInspection.inspect(url: url).facts)
        #expect(facts.frames == 96_960)
        let buffer = try SoundEngine.decode(url, facts: facts, availableMemory: { nil })
        #expect(buffer.frameLength > 0)
        #expect(buffer.frameLength <= facts.frames)
        #expect(buffer.frameCapacity <= facts.frames)
        #expect(buffer.format.sampleRate == 48_000)
        #expect(buffer.format.channelCount == 2)
        if !name.hasPrefix("short-table") {
            #expect(buffer.frameLength == 96_648)
            let pcm = try #require(buffer.floatChannelData?[0])
            let start = 24_000, end = 72_000
            let crossings = (start..<end).filter { pcm[$0] <= 0 && pcm[$0 + 1] > 0 }.count
            #expect(abs(crossings - 440) <= 2, "middle second must remain a 440 Hz tone")
            #expect((start..<end).contains { abs(pcm[$0]) > 0.02 })
            #expect((0..<Int(buffer.frameLength)).allSatisfy { pcm[$0].isFinite })
        }
    }

    @Test func nativeOpenFailureAlsoFallsBack() throws {
        let url = fixture("libopus-48000-6")
        let facts = try #require(AudioFileInspection.inspect(url: url).facts)
        let buffer = try SoundEngine.decode(url, facts: facts, opening: { _ in
            throw CocoaError(.fileReadCorruptFile)
        }, availableMemory: { nil })
        #expect(buffer.frameLength == 96_648)
    }

    @Test func insufficientMemoryStillRefusesTheSound() throws {
        let url = fixture("libopus-48000-6")
        let facts = try #require(AudioFileInspection.inspect(url: url).facts)
        #expect(throws: SoundEngine.SoundEngineError.outOfMemory) {
            try SoundEngine.decode(url, facts: facts, opening: { _ in
                throw CocoaError(.fileReadCorruptFile)
            }, availableMemory: { SoundEngine.memoryHeadroom })
        }
    }
    @Test func aSmallerReservationCannotBeExceeded() throws {
        let url = fixture("libopus-48000-6")
        let facts = AudioAdmission.Facts(sampleRate: 48_000, channels: 6, frames: 100)
        #expect(throws: SoundFileLimits.Violation.tooLong) {
            try SoundEngine.decode(url, facts: facts, opening: { _ in
                throw CocoaError(.fileReadCorruptFile)
            }, availableMemory: { nil })
        }
    }

    @Test func nativeFailuresForAACRemainNativeFailures() throws {
        struct NativeFailure: Error {}
        let url = fixture("claimed-700-tone")
        let facts = try #require(AudioFileInspection.inspect(url: url).facts)
        #expect(throws: NativeFailure.self) {
            try SoundEngine.decode(url, facts: facts, opening: { _ in throw NativeFailure() },
                                   availableMemory: { nil })
        }
    }

    @Test func opusHeaderGainIsApplied() throws {
        let url = fixture("libopus-48000-6")
        var bytes = try Data(contentsOf: url)
        let config = try #require(bytes.range(of: Data("dOps".utf8))).upperBound
        bytes[config + 8] = 6; bytes[config + 9] = 0 // +6 dB in signed Q8.
        let changed = FileManager.default.temporaryDirectory.appending(path: "Mp4Gain-\(UUID().uuidString).m4a")
        try bytes.write(to: changed)
        defer { try? FileManager.default.removeItem(at: changed) }
        let facts = try #require(AudioFileInspection.inspect(url: url).facts)
        let original = try SoundEngine.decode(url, facts: facts, availableMemory: { nil })
        let gained = try SoundEngine.decode(changed, facts: facts, availableMemory: { nil })
        let a = try #require(original.floatChannelData?[0]), b = try #require(gained.floatChannelData?[0])
        let energyA = (24_000..<72_000).reduce(0.0) { $0 + Double(a[$1] * a[$1]) }
        let energyB = (24_000..<72_000).reduce(0.0) { $0 + Double(b[$1] * b[$1]) }
        #expect(abs(sqrt(energyB / energyA) - pow(10, 6.0 / 20)) < 0.01)
    }

    @Test func damagedOpusConfigurationAndTruncationAreRefused() throws {
        let original = try Data(contentsOf: fixture("libopus-48000-6"))
        let config = try #require(original.range(of: Data("dOps".utf8))).upperBound
        for (offset, value) in [(0, 255), (1, 255), (10, 0), (11, 255), (12, 255), (13, 254)] {
            var damaged = original
            damaged[config + offset] = UInt8(value)
            #expect(throws: (any Error).self) { try Mp4AudioInspection.opusOgg(AudioRead(damaged)) }
        }
        for size in stride(from: 0, to: original.count, by: 97) {
            #expect(throws: (any Error).self) { try Mp4AudioInspection.opusOgg(AudioRead(original.prefix(size))) }
        }
    }

}
#endif
