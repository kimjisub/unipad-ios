#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
@testable import unipad

/// The real engine decodes only the files the shared rules select, and says why each other file of
/// the pack will not play.
@MainActor
struct SoundSelectionLoadingTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    private static func safety(_ name: String) -> URL {
        fixtures.appending(path: "AudioSafety").appending(path: name)
    }

    /// A copy under a new name, so a pack can hold the same bytes twice as different files.
    private static func copy(_ url: URL, as ext: String? = nil) throws -> URL {
        let target = FileManager.default.temporaryDirectory
            .appending(path: "SoundSelectionLoadingTests-\(UUID().uuidString).\(ext ?? url.pathExtension)")
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    /// Which files the engine opened for decoding.
    private final class OpenedFiles: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        let refuse: Set<URL>
        init(refusing refuse: Set<URL> = []) { self.refuse = refuse }
        var opened: [String] { lock.withLock { names } }
        func open(_ url: URL) throws -> AVAudioFile {
            lock.withLock { names.append(url.lastPathComponent) }
            if refuse.contains(url) { throw CocoaError(.fileReadCorruptFile) }
            return try AVAudioFile(forReading: url)
        }
    }

    /// The inspector's answer for each file, with `claims` standing in for long files the test does
    /// not have to write.
    private static func inspecting(_ claims: [URL: AudioAdmission.Facts]) -> (URL) -> AudioAdmission.Inspection {
        { url in claims[url].map { .accepted($0) } ?? AudioFileInspection.inspect(url: url) }
    }

    private static let tenMinutes = AudioAdmission.Facts(sampleRate: 48_000, channels: 2, frames: 48_000 * 600)

    private func presses(_ engine: SoundEngine, _ count: Int) -> [Int] {
        (0..<count).map { _ in
            engine.soundOn(x: 0, y: 0)
            return engine.playsStarted
        }
    }

    /// Ten minutes of 48 kHz stereo cost 57,600,000 each: the first two fit, the third does not,
    /// and the short fourth still fits in what is left.
    @Test func filesPastThePackLimitAreToldTooLargeAndTheRestPlay() async throws {
        let files = try (0..<3).map { _ in try SoundEngineTestSupport.writeWav(sampleRate: 48_000, frames: 4_800, channels: 2) }
        let short = try SoundEngineTestSupport.writeWav(sampleRate: 44_100, frames: 44_100 * 5, channels: 2)
        defer { for url in files + [short] { try? FileManager.default.removeItem(at: url) } }
        let opened = OpenedFiles()
        let pack = OnePadPack(chains: [(files + [short]).map { Sound(file: $0, loop: 0) }])
        let claims = Dictionary(uniqueKeysWithValues: files.map { ($0, Self.tenMinutes) })
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(
            pack, openAudioFile: opened.open, inspect: Self.inspecting(claims))
        defer { engine.destroy() }

        let report = try #require(listener.report)
        #expect(listener.failure == nil)
        #expect(report.entries == [.init(file: files[2], failure: .tooLarge)])
        #expect(report.usedFiles == 4)
        #expect(report.loadedFiles == 3)
        #expect(!opened.opened.contains(files[2].lastPathComponent), "an excluded file was decoded")
        #expect(presses(engine, 4) == [1, 2, 2, 3])
    }

    /// A selected file that fails to decode keeps what it reserved: the file the limit refused stays
    /// refused, and decoding never changes what was selected.
    @Test func aDecodeFailureKeepsItsReservation() async throws {
        let files = try (0..<3).map { _ in try SoundEngineTestSupport.writeWav(sampleRate: 48_000, frames: 4_800, channels: 2) }
        let short = try SoundEngineTestSupport.writeWav(sampleRate: 44_100, frames: 4_410, channels: 2)
        defer { for url in files + [short] { try? FileManager.default.removeItem(at: url) } }
        let opened = OpenedFiles(refusing: [files[0]])
        let pack = OnePadPack(chains: [(files + [short]).map { Sound(file: $0, loop: 0) }])
        let claims = Dictionary(uniqueKeysWithValues: files.map { ($0, Self.tenMinutes) })
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(
            pack, openAudioFile: opened.open, inspect: Self.inspecting(claims))
        defer { engine.destroy() }

        let report = try #require(listener.report)
        #expect(report.entries == [.init(file: files[0], failure: .undecodable), .init(file: files[2], failure: .tooLarge)])
        #expect(report.loadedFiles == 2)
        #expect(opened.opened == [files[0], files[1], short].map(\.lastPathComponent))
        #expect(presses(engine, 4) == [0, 1, 1, 2])
    }

    /// A device without memory for a sound is told apart from a file the rules refuse, and a pack
    /// none of whose sounds load does not open.
    @Test func aDeviceOutOfMemoryIsToldApart() async throws {
        let files = try (0..<2).map { _ in try SoundEngineTestSupport.writeWav(sampleRate: 48_000, frames: 4_800) }
        defer { for url in files { try? FileManager.default.removeItem(at: url) } }
        let pack = OnePadPack(chains: [files.map { Sound(file: $0, loop: 0) }])
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack, availableMemory: { SoundEngine.memoryHeadroom })
        defer { engine.destroy() }

        let report = try #require(listener.report)
        #expect(report.entries.map(\.failure) == [.outOfMemory, .outOfMemory])
        #expect(report.nothingPlays)
        #expect(listener.loadFailure != nil)
        #expect(presses(engine, 2) == [0, 0])
    }

    /// Contents the shared reader refuses are unreadable whatever they are called, and the native
    /// decoder never gets a second try at them. G.711 WAV, AIFF and CAF decode in Core Audio, but no
    /// app reads them the same way, so none of the three plays them.
    @Test(arguments: [
        ("NativeAudio", "alaw.wav", nil), ("NativeAudio", "ulaw.wav", nil),
        ("AudioSafety", "tone.aiff", nil), ("AudioSafety", "tone.aiff", "mp3"), ("AudioSafety", "aiff-named.mp3", nil),
        ("AudioSafety", "tone.caf", nil), ("AudioSafety", "tone.caf", "mp3"), ("AudioSafety", "aac.caf", nil),
        ("AudioSafety", "chained-false-headers.mp3", nil),
    ] as [(String, String, String?)])
    func contentsTheReaderRefusesAreUnreadableAndNeverDecoded(_ folder: String, _ name: String, _ renamed: String?) async throws {
        let refused = try Self.copy(Self.fixtures.appending(path: folder).appending(path: name), as: renamed)
        let good = try SoundEngineTestSupport.writeWav(sampleRate: 48_000, frames: 4_800)
        defer { for url in [refused, good] { try? FileManager.default.removeItem(at: url) } }
        let opened = OpenedFiles()
        let pack = OnePadPack(chains: [[Sound(file: refused, loop: 0), Sound(file: good, loop: 0)]])
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack, openAudioFile: opened.open)
        defer { engine.destroy() }

        let report = try #require(listener.report)
        #expect(report.entries == [.init(file: refused, failure: .unreadable)])
        #expect(opened.opened == [good.lastPathComponent], "\(name) went to the native decoder")
        #expect(presses(engine, 2) == [0, 1])
    }

    @Test func emptyAndMissingFilesAreUnreadable() async throws {
        let empty = FileManager.default.temporaryDirectory.appending(path: "SoundSelectionLoadingTests-\(UUID().uuidString).wav")
        try Data().write(to: empty)
        let missing = FileManager.default.temporaryDirectory.appending(path: "SoundSelectionLoadingTests-missing.wav")
        let good = try SoundEngineTestSupport.writeWav(sampleRate: 48_000, frames: 4_800)
        defer { for url in [empty, good] { try? FileManager.default.removeItem(at: url) } }
        let pack = OnePadPack(chains: [[Sound(file: empty, loop: 0), Sound(file: missing, loop: 0), Sound(file: good, loop: 0)]])
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack)
        defer { engine.destroy() }

        let report = try #require(listener.report)
        #expect(report.entries == [.init(file: empty, failure: .unreadable), .init(file: missing, failure: .unreadable)])
        #expect(report.count(.unreadable) == 2)
    }

    /// The header's length is not believed either way: a 5-second sound claiming 700 seconds plays,
    /// and 700 seconds claiming far less are refused before they are decoded.
    @Test(arguments: ["claimed-700-tone.mp3", "claimed-700-tone.m4a"])
    func aShortSoundClaimingSevenHundredSecondsPlays(_ name: String) async throws {
        let sound = try Self.copy(Self.safety(name))
        defer { try? FileManager.default.removeItem(at: sound) }
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(OnePadPack(soundFile: sound))
        defer { engine.destroy() }
        let report = try #require(listener.report)
        #expect(report.entries.isEmpty)
        #expect(report.loadedFiles == 1)
        #expect(presses(engine, 1) == [1])
    }

    @Test func sevenHundredSecondsAreTooLargeWithoutBeingDecoded() async throws {
        let long = try Self.copy(Self.safety("alac-48000-2-long.m4a"))
        let good = try SoundEngineTestSupport.writeWav(sampleRate: 48_000, frames: 4_800)
        defer { for url in [long, good] { try? FileManager.default.removeItem(at: url) } }
        let opened = OpenedFiles()
        let pack = OnePadPack(chains: [[Sound(file: long, loop: 0), Sound(file: good, loop: 0)]])
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack, openAudioFile: opened.open)
        defer { engine.destroy() }
        let report = try #require(listener.report)
        #expect(report.entries == [.init(file: long, failure: .tooLarge)])
        #expect(opened.opened == [good.lastPathComponent])
    }

    /// The same file on several pads is selected, decoded and reported once.
    @Test func aFileUsedTwiceIsCountedOnce() async throws {
        let good = try SoundEngineTestSupport.writeWav(sampleRate: 48_000, frames: 4_800)
        let empty = FileManager.default.temporaryDirectory.appending(path: "SoundSelectionLoadingTests-\(UUID().uuidString).wav")
        try Data().write(to: empty)
        defer { for url in [empty, good] { try? FileManager.default.removeItem(at: url) } }
        let opened = OpenedFiles()
        let pack = OnePadPack(chains: [
            [Sound(file: good, loop: 0), Sound(file: empty, loop: 0)],
            [Sound(file: empty, loop: 0), Sound(file: good, loop: 0)],
        ])
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack, openAudioFile: opened.open)
        defer { engine.destroy() }
        let report = try #require(listener.report)
        #expect(report.usedFiles == 2)
        #expect(report.entries == [.init(file: empty, failure: .unreadable)])
        #expect(opened.opened == [good.lastPathComponent])
    }

    /// Whatever the file and the output device, a sound is kept as 48 kHz stereo.
    @Test(arguments: [(UInt32(44_100), UInt16(1)), (22_050, 2), (96_000, 1), (48_000, 2)])
    func soundsAreKeptAsFortyEightKilohertzStereo(_ rate: UInt32, _ channels: UInt16) async throws {
        let sound = try SoundEngineTestSupport.writeWav(sampleRate: rate, frames: rate / 10, channels: channels)
        defer { try? FileManager.default.removeItem(at: sound) }
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(OnePadPack(soundFile: sound))
        defer { engine.destroy() }
        #expect(listener.report?.loadedFiles == 1)
        // Observes the engine's private store only in tests; a renamed field fails, never passes.
        let buffers = try #require(Mirror(reflecting: engine).children.first { $0.label == "buffers" }?.value as? [Int: AVAudioPCMBuffer])
        let buffer = try #require(buffers.values.first)
        #expect(buffer.format.sampleRate == 48_000)
        #expect(buffer.format.channelCount == 2)
        #expect(abs(Int(buffer.frameLength) - 4_800) <= 8)
    }

    /// A pack of lights only has no sound to fail.
    @Test func aPackWithoutSoundsIsNotAFailure() async throws {
        let pack = OnePadPack(chains: [[]])
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack)
        defer { engine.destroy() }
        let report = try #require(listener.report)
        #expect(report.usedFiles == 0)
        #expect(!report.nothingPlays)
        #expect(listener.failure == nil)
    }
}

/// What the play screen makes of a sound report.
@MainActor
struct SoundLoadNoticeTests {
    private func report(_ failures: [SoundLoadReport.Failure], loaded: Int) -> SoundLoadReport {
        var report = SoundLoadReport()
        for _ in 0..<loaded { report.loaded() }
        for (index, failure) in failures.enumerated() {
            report.failed(URL(fileURLWithPath: "/pack/sounds/\(index).wav"), failure)
        }
        return report
    }

    @Test func everyReasonGetsItsOwnLineWithItsCount() {
        let lines = PlayViewModel.soundLoadSummary(report([.outOfMemory, .tooLarge, .tooLarge, .unreadable, .undecodable, .undecodable, .undecodable], loaded: 1))
        #expect(lines == [
            String(localized: "sound_load_too_large \(2)"),
            String(localized: "sound_load_unreadable \(1)"),
            String(localized: "sound_load_undecodable \(3)"),
            String(localized: "sound_load_out_of_memory \(1)"),
        ])
        #expect(lines.allSatisfy { !$0.hasPrefix("sound_load_") }, "a key has no text")
        #expect(PlayViewModel.soundLoadSummary(report([], loaded: 3)).isEmpty)
    }

    @Test func aPartlyLoadedPackOpensAndTellsOnce() {
        let vm = PlayViewModel()
        vm.onSoundLoadingComplete(report([.tooLarge], loaded: 2))
        #expect(vm.startReady)
        #expect(vm.soundLoadNotice?.count(.tooLarge) == 1)
        #expect(vm.soundLoadFailure == nil)
        vm.cleanup()
    }

    @Test func aPackWhoseSoundsAllFailDoesNotOpen() {
        let vm = PlayViewModel()
        vm.onSoundLoadingComplete(report([.unreadable, .outOfMemory], loaded: 0))
        #expect(!vm.startReady)
        #expect(vm.soundLoadFailure?.entries.count == 2)
        #expect(vm.soundLoadNotice == nil)
        vm.cleanup()
    }

    @Test func aPackWithoutSoundsOpensSilently() {
        let vm = PlayViewModel()
        vm.onSoundLoadingComplete(SoundLoadReport())
        #expect(vm.startReady)
        #expect(vm.soundLoadNotice == nil)
        #expect(vm.soundLoadFailure == nil)
        vm.cleanup()
    }
}
#endif
