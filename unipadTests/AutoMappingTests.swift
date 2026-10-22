import Foundation
import os
import Testing
@testable import unipad

/// The option panel's auto mapping stops the auto play runner, rewrites the pack's autoPlay and
/// then has to finish: the progress row goes away and auto play is available again.
extension PlayUsageRecordTests {
    @MainActor
    struct AutoMappingTests {
        @Test func autoMappingFinishesAndRestoresAutoPlay() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                try #require(s.vm.autoPlayRunner != nil, "the fixture pack has no auto play")

                s.vm.autoMapping()
                #expect(s.vm.autoMappingActive)

                try await s.waitWhile { s.vm.autoMappingActive }
                #expect(!s.vm.autoMappingActive, "auto mapping never finished")
                #expect(s.vm.autoPlayRunner != nil, "auto play was not restored after auto mapping")
            }
        }

        @Test func failedAutoMappingStillRestoresAutoPlay() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                // Without the file the mapper has nothing to back up and fails before writing.
                try s.removePackFile("autoPlay")

                s.vm.autoMapping()
                try await s.waitWhile { s.vm.autoMappingActive }
                #expect(!s.vm.autoMappingActive, "auto mapping never finished")
                #expect(s.vm.toastMessage == String(localized: "remapFail"))
                #expect(s.vm.autoPlayRunner != nil, "auto play was not restored after a failed auto mapping")
            }
        }

        @Test func autoMappingDuringAutoPlayResetsPlayState() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                s.vm.switchPlayMode(.autoPlay)
                try #require(s.vm.isAutoPlayPlaying)

                s.vm.autoMapping()
                #expect(s.vm.playMode == .none)
                #expect(!s.vm.isAutoPlayPlaying, "auto play still shows as playing after its runner was stopped")
                try await s.waitWhile { s.vm.autoMappingActive }
                #expect(!s.vm.autoMappingActive, "auto mapping never finished")
            }
        }

        @Test func autoMappingWritesTheSoundLengths() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }
            let listener = RecordingListener()
            let wroteOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
            let replacer = AutoPlayFileReplacer { content, url in
                wroteOnMain.withLock { $0 = Thread.isMainThread }
                try content.write(to: url, atomically: true, encoding: .utf8)
            }

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener, replacer: replacer).start().value

            #expect(listener.events == ["start", "size 3", "progress 1", "progress 2", "progress 3", "done"])
            #expect(try pack.autoPlay() == "t 1 1\nd 60\nd 400\nt 1 2\nd 60\nd 400\nt 1 3\nd 60\n")
            #expect(pack.backups().count == 1)
            #expect(wroteOnMain.withLock { $0 } == false, "the mapping ran on the main thread")
        }

        /// A header claiming 0 Hz gave an infinite length that trapped; 20 Hz a wait thousands of
        /// times too long. Such a sound gets no length, like one that cannot be opened.
        @Test(arguments: [UInt32(0), 1, 20])
        func aSoundWithAnImplausibleSampleRateGetsNoLength(sampleRate: UInt32) async throws {
            let broken = try SoundEngineTestSupport.writeWav(sampleRate: sampleRate, frames: 4_410)
            defer { try? FileManager.default.removeItem(at: broken) }
            let pack = try MapperPack(keySound: "1 1 1 a.wav\n1 1 2 broken.wav\n1 1 3 a.wav\n", sounds: ["broken.wav": broken])
            defer { pack.remove() }
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(try pack.autoPlay() == "t 1 1\nd 60\nd 400\nt 1 2\nd 400\nt 1 3\nd 60\n")
        }

        /// `AVAudioFile` cannot open Ogg Vorbis, which playback decodes itself: the 0.5 s tone
        /// gets its wait like a WAV does.
        @Test func anOggVorbisSoundGetsItsLength() async throws {
            let tone = try #require(Bundle(for: OnePadPack.self).url(forResource: "vorbis-tone", withExtension: "ogg"))
            let pack = try MapperPack(keySound: "1 1 1 a.wav\n1 1 2 tone.ogg\n1 1 3 a.wav\n", sounds: ["tone.ogg": tone])
            defer { pack.remove() }
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(try pack.autoPlay() == "t 1 1\nd 60\nd 400\nt 1 2\nd 500\nd 400\nt 1 3\nd 60\n")
        }

        /// Playback refuses these Ogg Vorbis sounds, so they add no wait: one declaring 601 s, and
        /// one whose declared length at 192 kHz exceeds the buffer budget.
        @Test(arguments: ["vorbis-overlong", "vorbis-over-budget"])
        func anOggVorbisSoundPlaybackRefusesGetsNoLength(fixture: String) async throws {
            let refused = try #require(Bundle(for: OnePadPack.self).url(forResource: fixture, withExtension: "ogg"))
            let pack = try MapperPack(keySound: "1 1 1 a.wav\n1 1 2 refused.ogg\n1 1 3 a.wav\n", sounds: ["refused.ogg": refused])
            defer { pack.remove() }
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(try pack.autoPlay() == "t 1 1\nd 60\nd 400\nt 1 2\nd 400\nt 1 3\nd 60\n")
        }

        @Test func aSoundOverTenMinutesGetsNoLength() async throws {
            let long = try SoundEngineTestSupport.writeWav(sampleRate: 8_000, frames: 8_000 * 601)
            defer { try? FileManager.default.removeItem(at: long) }
            let pack = try MapperPack(keySound: "1 1 1 a.wav\n1 1 2 long.wav\n1 1 3 a.wav\n", sounds: ["long.wav": long])
            defer { pack.remove() }
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(try pack.autoPlay() == "t 1 1\nd 60\nd 400\nt 1 2\nd 400\nt 1 3\nd 60\n")
        }

        @Test func aSoundExceedingTheBufferBudgetGetsNoLength() async throws {
            let frames = UInt32(SoundFileLimits.maximumBufferBytes / (2 * 4)) + 1
            let oversized = try SoundEngineTestSupport.writeWav(sampleRate: 384_000, frames: frames, channels: 2)
            defer { try? FileManager.default.removeItem(at: oversized) }
            let pack = try MapperPack(keySound: "1 1 1 a.wav\n1 1 2 oversized.wav\n1 1 3 a.wav\n", sounds: ["oversized.wav": oversized])
            defer { pack.remove() }
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(try pack.autoPlay() == "t 1 1\nd 60\nd 400\nt 1 2\nd 400\nt 1 3\nd 60\n")
        }

        /// Waits that add up past Int32.max are written as several lines the pack reader accepts,
        /// so the pack reloads with the whole wait.
        @Test func aWaitLongerThanTheReaderTakesIsSplit() async throws {
            let pack = try MapperPack(autoPlay: "d 2147483647\nd 2147483647\nd 5\non 1 1\nd 2147483647\nd 1\n")
            defer { pack.remove() }
            let totalDelay = { pack.unipack.autoPlayTable?.elements.reduce(0) { sum, element in
                if case .delay(let d) = element { sum + d } else { sum }
            } }
            let before = try #require(totalDelay())
            let errorsBefore = pack.unipack.errorDetail
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(try pack.autoPlay() == "d 2147483647\nd 2147483647\nd 5\nt 1 1\nd 60\nd 2147483647\nd 1\n")
            #expect(pack.unipack.errorDetail == errorsBefore, "the pack reader refused the mapped autoPlay")
            #expect(totalDelay() == before + 60)
        }

        @Test func autoMappingCancelledBeforeWritingLeavesThePack() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }
            let original = try pack.autoPlay()
            let listener = RecordingListener()
            let mapper = UniPackAutoMapper(unipack: pack.unipack, listener: listener)
            // The screen is left while the last press is being mapped: nothing is left to loop
            // over, so only the check before writing can stop it.
            listener.onLastProgress = { mapper.cancel() }

            await mapper.start().value

            #expect(listener.events == ["start", "size 3", "progress 1", "progress 2", "progress 3"])
            #expect(try pack.autoPlay() == original)
            #expect(pack.backups().isEmpty)
        }

        @Test func failedWriteLeavesThePackAsItWas() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }
            let original = try pack.autoPlay()
            let listener = RecordingListener()
            let replacer = AutoPlayFileReplacer { _, _ in throw CocoaError(.fileWriteOutOfSpace) }

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener, replacer: replacer).start().value

            #expect(listener.events.last == "error \(CocoaError(.fileWriteOutOfSpace).localizedDescription)")
            #expect(try pack.autoPlay() == original)
            #expect(pack.backups().isEmpty, "the backup of a failed write was left in the pack")
            #expect(try pack.files() == ["autoPlay", "info", "keySound", "sounds"])
        }
    }
}

@MainActor
private final class RecordingListener: UniPackAutoMapperListener {
    private(set) var events: [String] = []
    private var size = 0
    var onLastProgress: () -> Void = {}

    func onStart() { events.append("start") }
    func onGetWorkSize(_ size: Int) { self.size = size; events.append("size \(size)") }
    func onProgress(_ progress: Int) {
        events.append("progress \(progress)")
        if progress == size { onLastProgress() }
    }
    func onDone() { events.append("done") }
    func onException(_ error: Error) { events.append("error \(error.localizedDescription)") }
}

/// The scenario's pack, loaded for the mapper alone.
@MainActor
private struct MapperPack {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AutoMapping-\(UUID().uuidString)")
    let unipack: UniPackFolder

    init(
        keySound: String = PlayUsageScenario.defaultKeySound,
        autoPlay: String = PlayUsageScenario.defaultAutoPlay,
        sounds: [String: URL] = [:]
    ) throws {
        try PlayUsageScenario.writePack(to: folder, keySound: keySound, autoPlay: autoPlay)
        for (name, source) in sounds {
            try FileManager.default.copyItem(at: source, to: folder.appending(path: "sounds/\(name)"))
        }
        unipack = UniPackFolder(rootFolder: folder)
        unipack.load()
        unipack.loadDetail()
    }

    func autoPlay() throws -> String { try String(contentsOf: folder.appending(path: "autoPlay"), encoding: .utf8) }
    func files() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() }
    func backups() -> [String] { ((try? files()) ?? []).filter { $0.hasPrefix("autoPlay_") } }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}
