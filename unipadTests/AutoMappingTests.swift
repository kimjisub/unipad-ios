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
private struct MapperPack {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AutoMapping-\(UUID().uuidString)")
    let unipack: UniPackFolder

    init() throws {
        try PlayUsageScenario.writePack(to: folder)
        unipack = UniPackFolder(rootFolder: folder)
        unipack.load()
        unipack.loadDetail()
    }

    func autoPlay() throws -> String { try String(contentsOf: folder.appending(path: "autoPlay"), encoding: .utf8) }
    func files() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() }
    func backups() -> [String] { ((try? files()) ?? []).filter { $0.hasPrefix("autoPlay_") } }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}
