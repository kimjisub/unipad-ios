import Foundation
import Testing
@testable import unipad

/// The main screen reads a selected pack's detail (keySound, keyLed, autoPlay) off the main actor
/// while the panel keeps reading that pack on it. However a pack is selected meanwhile it has to be
/// parsed once, and the panel has to see either no detail or the whole of it.
/// Holding a read stands in for a slow disk so that selections overlap it for certain; it is a
/// test condition, not a measurement of a user.
@MainActor
struct MainDetailReadTests {
    /// Counts the detail reads of one pack object, how many ran at once and on which thread.
    /// A held probe keeps every read at its start until `release()`.
    final class ReadProbe: @unchecked Sendable {
        private let state = NSCondition()
        private var held: Bool
        private var started = 0
        private var running = 0
        private var mostAtOnce = 0
        private var startedOnMain = 0

        init(held: Bool = false) {
            self.held = held
        }

        var reads: Int { state.withLock { started } }
        var maxAtOnce: Int { state.withLock { mostAtOnce } }
        var readsOnMain: Int { state.withLock { startedOnMain } }
        var isIdle: Bool { state.withLock { running == 0 } }

        func release() {
            state.withLock {
                held = false
                state.broadcast()
            }
        }

        func run<T>(_ read: () -> T) -> T {
            state.withLock {
                started += 1
                if Thread.isMainThread { startedOnMain += 1 }
                // A read held on the main thread could never be released by the test; let it go on.
                let deadline = Date().addingTimeInterval(2)
                while held, state.wait(until: deadline) {}
                running += 1
                mostAtOnce = max(mostAtOnce, running)
            }
            defer { state.withLock { running -= 1 } }
            return read()
        }
    }

    final class ProbedPackFolder: UniPackFolder {
        let probe: ReadProbe

        init(rootFolder: URL, probe: ReadProbe) {
            self.probe = probe
            super.init(rootFolder: rootFolder)
        }

        override func makeDetailRead() -> DetailRead? {
            guard let read = super.makeDetailRead() else { return nil }
            return { [probe] onPhase in
                probe.run { read(onPhase) }
            }
        }
    }

    private let workspace: URL
    private let vm = MainViewModel()

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "MainDetailReadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: workspace)
    }

    /// An 8×8 pack with 4 chains: `sounds` valid keySound lines and one line the parser reports.
    private func makePackFolder(_ name: String, sounds: Int = 1024) throws -> URL {
        let folder = workspace.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "sounds"), withIntermediateDirectories: true)
        try "title=\(name)\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=4\n"
            .write(to: folder.appending(path: "info"), atomically: true, encoding: .utf8)
        let lines = (0..<sounds).map { "\($0 / 64 % 4 + 1) \($0 / 8 % 8 + 1) \($0 % 8 + 1) a.wav" }
        try (lines + ["1 1 1"]).joined(separator: "\n")
            .write(to: folder.appending(path: "keySound"), atomically: true, encoding: .utf8)
        try Data().write(to: folder.appending(path: "sounds/a.wav"))
        return folder
    }

    private func makeItem(_ folder: URL, probe: ReadProbe) -> UniPackItem {
        let pack = ProbedPackFolder(rootFolder: folder, probe: probe)
        pack.load()
        return UniPackItem(unipack: pack)
    }

    private func errorLines(_ pack: UniPack) -> Int {
        pack.errorDetail?.components(separatedBy: "\n").count ?? 0
    }

    /// Reads the packs the way `MainPackPanel` does, every millisecond until their reads are over,
    /// and returns how often a pack marked as loaded showed anything but its whole result.
    private func wrongPanelReads(of packs: [(item: UniPackItem, probe: ReadProbe, sounds: Int)]) async throws -> Int {
        var wrong = 0
        var settled = 0
        var polls = 0
        // Goes on for a while after the last read ended, in case another one was still to start.
        // A read that never ends stops the wait and fails the expectations that follow.
        while settled < 20, polls < 10_000 {
            polls += 1
            var allDone = true
            for (item, probe, sounds) in packs {
                let pack = item.unipack
                if pack.detailLoaded, pack.soundCount != sounds || errorLines(pack) != 1 { wrong += 1 }
                if !pack.detailLoaded || !probe.isIdle { allDone = false }
            }
            settled = allDone ? settled + 1 : 0
            try await Task.sleep(for: .milliseconds(1))
        }
        return wrong
    }

    /// Lets a second read, if the code under test starts one, reach the hold before it is released.
    private func letReadsStart() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    private func expectReadOnce(_ item: UniPackItem, _ probe: ReadProbe, sounds: Int = 1024) {
        #expect(probe.reads == 1, "the pack object was parsed \(probe.reads) times")
        #expect(probe.maxAtOnce == 1, "\(probe.maxAtOnce) parses of one pack object ran at once")
        #expect(probe.readsOnMain == 0, "\(probe.readsOnMain) parses ran on the main thread")
        #expect(item.unipack.detailLoaded)
        #expect(item.unipack.soundCount == sounds)
        #expect(errorLines(item.unipack) == 1)
    }

    @Test func aSingleSelectionReadsThePackOnceOffTheMainThread() async throws {
        defer { cleanUp() }
        let probe = ReadProbe()
        let item = makeItem(try makePackFolder("Single"), probe: probe)

        vm.toggleSelection(item)
        let wrong = try await wrongPanelReads(of: [(item, probe, 1024)])

        expectReadOnce(item, probe)
        #expect(wrong == 0)
        #expect(vm.detailLoadVersion == 1)
    }

    @Test func reselectingAPackWhileItsReadIsHeldReadsItOnce() async throws {
        defer { cleanUp() }
        let probe = ReadProbe(held: true)
        let item = makeItem(try makePackFolder("Reselect"), probe: probe)

        vm.toggleSelection(item)
        vm.toggleSelection(item)
        vm.toggleSelection(item)
        try await letReadsStart()
        probe.release()
        let wrong = try await wrongPanelReads(of: [(item, probe, 1024)])

        expectReadOnce(item, probe)
        #expect(wrong == 0)
        #expect(vm.selectedItem?.id == item.id)
    }

    @Test func comingBackToAPackWhileItsReadIsHeldReadsItOnce() async throws {
        defer { cleanUp() }
        let probeA = ReadProbe(held: true)
        let probeB = ReadProbe()
        let a = makeItem(try makePackFolder("A"), probe: probeA)
        let b = makeItem(try makePackFolder("B", sounds: 512), probe: probeB)

        vm.toggleSelection(a)
        vm.toggleSelection(b)
        vm.toggleSelection(a)
        try await letReadsStart()
        probeA.release()
        let wrong = try await wrongPanelReads(of: [(a, probeA, 1024), (b, probeB, 512)])

        expectReadOnce(a, probeA)
        expectReadOnce(b, probeB, sounds: 512)
        #expect(wrong == 0)
        #expect(vm.selectedItem?.id == a.id)
    }

    @Test func switchingToAnotherPackKeepsEachResultWithItsPack() async throws {
        defer { cleanUp() }
        let probeA = ReadProbe(held: true)
        let probeB = ReadProbe()
        let a = makeItem(try makePackFolder("A"), probe: probeA)
        let b = makeItem(try makePackFolder("B", sounds: 512), probe: probeB)

        vm.toggleSelection(a)
        vm.toggleSelection(b)
        let wrongWhileHeld = try await wrongPanelReads(of: [(b, probeB, 512)])
        #expect(!a.unipack.detailLoaded)
        #expect(vm.detailLoadVersion == 1)

        probeA.release()
        let wrong = try await wrongPanelReads(of: [(a, probeA, 1024), (b, probeB, 512)])

        expectReadOnce(a, probeA)
        expectReadOnce(b, probeB, sounds: 512)
        #expect(wrongWhileHeld == 0)
        #expect(wrong == 0)
        #expect(vm.selectedItem?.id == b.id)
        // A was no longer selected when its read ended, so the panel was not told to redraw for it.
        #expect(vm.detailLoadVersion == 1)
    }

    /// No hold: the three taps land in one turn of the main actor, faster than a person taps.
    @Test func reselectingWithoutAHoldReadsEachPackOnce() async throws {
        defer { cleanUp() }
        let folder = try makePackFolder("Rounds")
        var roundsReadTwice = 0
        var roundsOverlapping = 0
        var roundsReadOnMain = 0
        var roundsWithWrongResult = 0
        var roundsWithWrongPanelRead = 0

        for _ in 0..<30 {
            let probe = ReadProbe()
            let item = makeItem(folder, probe: probe)
            vm.selectedItem = nil

            vm.toggleSelection(item)
            vm.toggleSelection(item)
            vm.toggleSelection(item)
            let wrong = try await wrongPanelReads(of: [(item, probe, 1024)])

            if probe.reads != 1 { roundsReadTwice += 1 }
            if probe.maxAtOnce != 1 { roundsOverlapping += 1 }
            if probe.readsOnMain != 0 { roundsReadOnMain += 1 }
            if item.unipack.soundCount != 1024 || errorLines(item.unipack) != 1 { roundsWithWrongResult += 1 }
            if wrong != 0 { roundsWithWrongPanelRead += 1 }
        }

        #expect(roundsReadTwice == 0)
        #expect(roundsOverlapping == 0)
        #expect(roundsReadOnMain == 0)
        #expect(roundsWithWrongResult == 0)
        #expect(roundsWithWrongPanelRead == 0)
    }

    @Test func importFinishingWhileTheSelectedPackIsHeldSharesThatRead() async throws {
        defer { cleanUp() }
        let probe = ReadProbe(held: true)
        let folder = try makePackFolder("Imported")
        let item = makeItem(folder, probe: probe)
        vm.unipackItems = [item]

        vm.toggleSelection(item)
        let showing = Task { await vm.showImportResult(forImportedFolder: folder) }
        try await letReadsStart()
        #expect(vm.importResult == nil, "the import result was shown before the pack was read")
        probe.release()
        await showing.value
        let wrong = try await wrongPanelReads(of: [(item, probe, 1024)])

        expectReadOnce(item, probe)
        #expect(wrong == 0)
        guard case .warning(let message) = vm.importResult else {
            Issue.record("expected the parser's warning, got \(String(describing: vm.importResult))")
            return
        }
        #expect(message == "keySound : [1 1 1] format is incorrect")
    }

    @Test func importFinishingRightAfterSelectingSharesThatRead() async throws {
        defer { cleanUp() }
        let probe = ReadProbe()
        let folder = try makePackFolder("Imported")
        let item = makeItem(folder, probe: probe)
        vm.unipackItems = [item]

        vm.toggleSelection(item)
        await vm.showImportResult(forImportedFolder: folder)
        let wrong = try await wrongPanelReads(of: [(item, probe, 1024)])

        expectReadOnce(item, probe)
        #expect(wrong == 0)
        guard case .warning(let message) = vm.importResult else {
            Issue.record("expected the parser's warning, got \(String(describing: vm.importResult))")
            return
        }
        #expect(message == "keySound : [1 1 1] format is incorrect")
    }

    @Test func importResultOfAnUnselectedPackIsReadOffTheMainThread() async throws {
        defer { cleanUp() }
        let probe = ReadProbe()
        let folder = try makePackFolder("Imported")
        let item = makeItem(folder, probe: probe)
        vm.unipackItems = [item]

        await vm.showImportResult(forImportedFolder: folder)

        expectReadOnce(item, probe)
        guard case .warning = vm.importResult else {
            Issue.record("expected the parser's warning, got \(String(describing: vm.importResult))")
            return
        }
    }

    @Test func aPackThatCannotBeReadStaysWithoutDetail() async throws {
        defer { cleanUp() }
        let folder = workspace.appending(path: "Broken", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = makeItem(folder, probe: ReadProbe())
        let errorsBefore = item.unipack.errorDetail

        vm.toggleSelection(item)
        try await letReadsStart()

        #expect(item.unipack.criticalError)
        #expect(!item.unipack.detailLoaded)
        #expect(item.unipack.errorDetail == errorsBefore)
    }
}
