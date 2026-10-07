import Foundation
import Testing
@testable import unipad

/// Pack setup and cleanup shared by the interruption regressions.
@Suite(.serialized)
struct PlayUsageRecordTests {}

@MainActor
final class PlayUsageScenario {
    let vm: PlayViewModel
    private let packFolder: URL

    nonisolated static let defaultKeySound = "1 1 1 a.wav\n1 1 2 a.wav\n1 1 3 a.wav\n"
    nonisolated static let defaultAutoPlay = "on 1 1\ndelay 400\non 1 2\ndelay 400\non 1 3\n"

    init(keySound: String = defaultKeySound, autoPlay: String = defaultAutoPlay) throws {
        vm = PlayViewModel()
        packFolder = FileManager.default.temporaryDirectory.appendingPathComponent("PlayUsage-\(UUID().uuidString)")
        try Self.writePack(to: packFolder, keySound: keySound, autoPlay: autoPlay)
    }

    static func run(
        keySound: String = defaultKeySound,
        autoPlay: String = defaultAutoPlay,
        _ body: (PlayUsageScenario) async throws -> Void
    ) async throws {
        let s = try PlayUsageScenario(keySound: keySound, autoPlay: autoPlay)
        defer { s.finish() }
        try await body(s)
    }

    func load() async throws { try await vm.loadUnipack(path: packFolder.path) }

    func ready() async throws {
        try await waitWhile(timeout: 15) { !vm.startReady }
        try #require(vm.startReady, "pack never became ready")
    }

    func loadReady() async throws { try await load(); try await ready() }

    func autoplayEnded() async throws {
        try await waitWhile { vm.isAutoPlayPlaying }
        try #require(!vm.isAutoPlayPlaying, "autoplay never ended")
    }

    func waitWhile(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    func removePackFile(_ name: String) throws { try FileManager.default.removeItem(at: packFolder.appending(path: name)) }

    func press(_ x: Int = 0, _ y: Int = 0) { vm.padTouch(x: x, y: y, isDown: true) }
    func release(_ x: Int = 0, _ y: Int = 0) { vm.padTouch(x: x, y: y, isDown: false) }
    func finish() {
        vm.cleanup()
        try? FileManager.default.removeItem(at: packFolder)
    }

    private static func writePack(to folder: URL, keySound: String, autoPlay: String) throws {
        let files: [(String, Data)] = [
            ("info", Data("title=PlayUsage\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=2\nsquareButton=true\n".utf8)),
            ("keySound", Data(keySound.utf8)),
            ("autoPlay", Data(autoPlay.utf8)),
            ("sounds/a.wav", silentWav(milliseconds: 60)),
        ]
        for (name, data) in files {
            let url = folder.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    static func silentWav(milliseconds: Int) -> Data {
        let sampleRate = 44100
        let dataSize = sampleRate * milliseconds / 1000 * 2
        var wav = Data()
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); append32(36 + dataSize)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append32(16)
        append16(1); append16(1); append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        wav.append(contentsOf: Array("data".utf8)); append32(dataSize)
        wav.append(Data(count: dataSize))
        return wav
    }
}
