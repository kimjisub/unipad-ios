import Foundation
import Testing
@testable import unipad

/// Each scenario records the production analytics calls in its own sink, without parsing the
/// process-wide log or touching Firebase. The common parent suite also serializes pack-loading
/// tests, whose readiness callbacks install a receiver on the same MidiManager.
@MainActor
final class PlayUsageScenario {
    let sink = UsageAnalyticsTests.RecordingAnalytics()
    let vm: PlayViewModel
    private let packFolder: URL
    private var restoresMidiDriver = false

    init() throws {
        vm = PlayViewModel(usageAnalytics: UsageAnalytics(sink: sink))
        packFolder = FileManager.default.temporaryDirectory.appendingPathComponent("PlayUsage-\(UUID().uuidString)")
        try Self.writePack(to: packFolder)
    }

    static func run(_ body: (PlayUsageScenario) async throws -> Void) async throws {
        let s = try PlayUsageScenario()
        defer { s.finish() }
        try await body(s)
    }

    func load() async throws { try await vm.loadUnipack(path: packFolder.path) }

    func ready() async throws {
        let deadline = Date().addingTimeInterval(15)
        while !vm.startReady && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(vm.startReady, "pack never became ready")
        let loaded = try #require(sink.events(named: "pack_load").first, "load event missing")
        #expect(loaded.parameters["result"] == "success")
    }

    func loadReady() async throws { try await load(); try await ready() }

    func autoplayEnded() async throws {
        let deadline = Date().addingTimeInterval(10)
        while vm.isAutoPlayPlaying && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!vm.isAutoPlayPlaying, "autoplay never ended")
    }

    func press(_ x: Int = 0, _ y: Int = 0) { vm.padTouch(x: x, y: y, isDown: true) }
    func release(_ x: Int = 0, _ y: Int = 0) { vm.padTouch(x: x, y: y, isDown: false) }
    var starts: [String?] { sink.events(named: "play_start").map { $0.parameters["trigger"] } }
    var firstInputs: [String?] { sink.events(named: "play_first_input").map { $0.parameters["trigger"] } }

    func midi(cmd: Int, note: Int, velocity: Int) async throws {
        if !restoresMidiDriver {
            MidiManager.shared.overrideDriver(LaunchpadMK2Driver())
            restoresMidiDriver = true
        }
        MidiManager.shared.driver.getSignal(cmd: cmd, sig: cmd == 9 ? -112 : -80, note: note, velocity: velocity)
        // The production MIDI controller dispatches to the main actor.
        try await Task.sleep(for: .milliseconds(20))
    }

    func finish() {
        vm.cleanup()
        if restoresMidiDriver { MidiManager.shared.overrideDriver(NotingDriver()) }
        try? FileManager.default.removeItem(at: packFolder)
    }

    private static func writePack(to folder: URL) throws {
        let files: [(String, Data)] = [
            ("info", Data("title=PlayUsage\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\nsquareButton=true\n".utf8)),
            ("keySound", Data("1 1 1 a.wav\n1 1 2 a.wav\n1 1 3 a.wav\n".utf8)),
            ("autoPlay", Data("on 1 1\ndelay 400\non 1 2\ndelay 400\non 1 3\n".utf8)),
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
