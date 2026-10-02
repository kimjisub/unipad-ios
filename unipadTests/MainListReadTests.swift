import Foundation
import os
import SwiftData
import Testing
@testable import unipad

/// Reloading the home list reads folders and pack info files. That read runs off the main actor
/// and only packs that were read completely reach the list.
@MainActor
struct MainListReadTests {
    /// Sits in the folder listing and in every pack read, records where they ran, and can hold them.
    /// A read that has to wait for `requiredTicks` main-actor ticks times out when it runs on the main actor itself.
    final class ListProbe: @unchecked Sendable {
        private let state = NSCondition()
        private var held: Bool
        private let requiredTicks: Int
        private var ticks = 0
        private var listings = 0
        private var listingsOnMain = 0
        private var packReads = 0
        private var packReadsOnMain = 0
        private var heldDetails: Set<String>
        private var detailReads = 0
        private var detailReadsOnMain = 0
        private var walks = 0
        private var walksOnMain = 0
        private var timeouts = 0

        init(held: Bool = false, requiredTicks: Int = 0, heldDetails: Set<String> = []) {
            self.held = held
            self.requiredTicks = requiredTicks
            self.heldDetails = heldDetails
        }

        var listingCount: Int { state.withLock { listings } }
        var listingsOnMainThread: Int { state.withLock { listingsOnMain } }
        var packReadCount: Int { state.withLock { packReads } }
        var packReadsOnMainThread: Int { state.withLock { packReadsOnMain } }
        var detailReadCount: Int { state.withLock { detailReads } }
        var detailReadsOnMainThread: Int { state.withLock { detailReadsOnMain } }
        var folderWalks: Int { state.withLock { walks } }
        var folderWalksOnMainThread: Int { state.withLock { walksOnMain } }
        var timedOutWaits: Int { state.withLock { timeouts } }

        func tick() {
            state.withLock {
                ticks += 1
                state.broadcast()
            }
        }

        func release() {
            state.withLock {
                held = false
                state.broadcast()
            }
        }

        func listing(_ list: () -> [URL]) -> [URL] {
            let folders = list()
            state.withLock {
                listings += 1
                if Thread.isMainThread { listingsOnMain += 1 }
                pause()
            }
            return folders
        }

        func packRead<T>(_ read: () -> T) -> T {
            state.withLock {
                packReads += 1
                if Thread.isMainThread { packReadsOnMain += 1 }
                pause()
            }
            return read()
        }

        /// Records a detail read of the pack in `folderName`, held while that folder is in `heldDetails`.
        func detailRead<T>(of folderName: String, _ read: () -> T) -> T {
            state.withLock {
                detailReads += 1
                if Thread.isMainThread { detailReadsOnMain += 1 }
                let deadline = Date().addingTimeInterval(1.5)
                while heldDetails.contains(folderName) {
                    if !state.wait(until: deadline) {
                        timeouts += 1
                        break
                    }
                }
            }
            return read()
        }

        func releaseDetail(of folderName: String) {
            state.withLock {
                heldDetails.remove(folderName)
                state.broadcast()
            }
        }

        func walkedFolder() {
            state.withLock {
                walks += 1
                if Thread.isMainThread { walksOnMain += 1 }
            }
        }

        private func pause() {
            let deadline = Date().addingTimeInterval(1.5)
            while held || ticks < requiredTicks {
                if !state.wait(until: deadline) {
                    timeouts += 1
                    return
                }
            }
        }
    }

    /// A pack folder that reports its folder walks and detail reads to a probe. Its modification
    /// time comes from its folder name, so the download-date order is known without touching the disk.
    final class ProbedPack: UniPackFolder, @unchecked Sendable {
        static let times = ["old": 100.0, "mid": 200.0, "new": 300.0]
        private let folderName: String
        private let probe: ListProbe

        init(rootFolder: URL, probe: ListProbe) {
            folderName = rootFolder.lastPathComponent
            self.probe = probe
            super.init(rootFolder: rootFolder)
        }

        override func lastModified() -> TimeInterval {
            probe.walkedFolder()
            return Self.times[folderName] ?? 0
        }

        override func makeDetailRead() -> DetailRead? {
            guard let read = super.makeDetailRead() else { return nil }
            let probe = probe
            let folderName = folderName
            return { onPhase in probe.detailRead(of: folderName) { read(onPhase) } }
        }
    }

    private let workspace: URL
    private let vm = MainViewModel()

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "MainListReadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        vm.modelContainer = try ModelContainerFactory.openInMemory()
        vm.sortMethod = .title
        vm.sortAscending = true
        connect(ListProbe())
    }

    private func connect(_ probe: ListProbe) {
        let workspace = workspace
        vm.packFolderSource = {
            probe.listing {
                let folders = (try? FileManager.default.contentsOfDirectory(
                    at: workspace, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                )) ?? []
                return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
        }
        vm.readPack = { folder in
            probe.packRead { ProbedPack(rootFolder: folder, probe: probe).load() }
        }
    }

    @discardableResult
    private func installPack(_ folderName: String, title: String, producer: String = "Tester") throws -> URL {
        let folder = workspace.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "sounds"), withIntermediateDirectories: true)
        try "title=\(title)\nproducerName=\(producer)\nbuttonX=8\nbuttonY=8\nchain=1\n"
            .write(to: folder.appending(path: "info"), atomically: true, encoding: .utf8)
        try "1 1 1 a.wav\n".write(to: folder.appending(path: "keySound"), atomically: true, encoding: .utf8)
        try Data().write(to: folder.appending(path: "sounds/a.wav"))
        return folder
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: workspace)
    }

    /// Runs the main actor while the reload is under way, the way the screen keeps drawing.
    private func settle(ticking probe: ListProbe? = nil) async throws {
        while vm.isRefreshing {
            probe?.tick()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntil(
        _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        var polls = 0
        while !condition() {
            guard polls < 400 else {
                Issue.record("the condition did not come true within 2 seconds", sourceLocation: sourceLocation)
                return
            }
            polls += 1
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private var titles: [String] {
        vm.unipackItems.map(\.unipack.title)
    }

    @Test func listReadRunsOffTheMainThreadWhileTheMainActorKeepsRunning() async throws {
        defer { cleanUp() }
        try installPack("a", title: "A")
        try installPack("b", title: "B")
        let probe = ListProbe(requiredTicks: 5)
        connect(probe)

        vm.refreshList()
        try await settle(ticking: probe)

        #expect(probe.listingCount == 1)
        #expect(probe.packReadCount == 2)
        #expect(probe.listingsOnMainThread == 0, "the folder listing ran on the main thread")
        #expect(probe.packReadsOnMainThread == 0, "\(probe.packReadsOnMainThread) pack reads ran on the main thread")
        #expect(probe.timedOutWaits == 0, "the main actor made no progress while the list was being read")
        #expect(titles == ["A", "B"])
    }

    @Test func listShowsOnlyWhatWasReadCompletelyAndKeepsTheOldListWhileReading() async throws {
        defer { cleanUp() }
        try installPack("a", title: "A")
        vm.refreshList()
        try await settle()
        try installPack("b", title: "B")
        let probe = ListProbe(held: true)
        connect(probe)

        vm.refreshList()
        try await waitUntil { probe.listingCount >= 1 }

        #expect(vm.isRefreshing)
        #expect(titles == ["A"], "the list changed before the read finished")

        probe.release()
        try await settle()

        #expect(titles == ["A", "B"])
        #expect(vm.unipackItems.allSatisfy { $0.unipack.loaded && !$0.unipack.criticalError })
        #expect(!vm.isRefreshing)
    }

    @Test func emptyLibraryShowsNothingAndStopsRefreshing() async throws {
        defer { cleanUp() }
        let probe = ListProbe()
        connect(probe)

        vm.refreshList()
        try await settle()

        #expect(vm.unipackItems.isEmpty)
        #expect(vm.selectedItem == nil)
        #expect(probe.packReadCount == 0)
        #expect(!vm.isRefreshing)
    }

    @Test func packThatDisappearedLeavesTheListAndTheSelection() async throws {
        defer { cleanUp() }
        let folder = try installPack("a", title: "A")
        vm.refreshList()
        try await settle()
        vm.selectedItem = vm.unipackItems.first

        try FileManager.default.removeItem(at: folder)
        vm.refreshList()
        try await settle()

        #expect(vm.unipackItems.isEmpty)
        #expect(vm.selectedItem == nil)
    }

    @Test func brokenPackIsListedWithItsErrorNextToAGoodOne() async throws {
        defer { cleanUp() }
        try installPack("good", title: "Good")
        try FileManager.default.createDirectory(
            at: workspace.appending(path: "broken", directoryHint: .isDirectory), withIntermediateDirectories: true
        )

        vm.refreshList()
        try await settle()

        let good = try #require(vm.unipackItems.first { $0.unipack.title == "Good" })
        let broken = try #require(vm.unipackItems.first { $0.unipack.title.isEmpty })
        #expect(vm.unipackItems.count == 2)
        #expect(!good.unipack.criticalError)
        #expect(broken.unipack.criticalError)
        #expect(broken.unipack.errorDetail != nil)
    }

    @Test func refreshesRequestedDuringAReadShareOneFollowUpRead() async throws {
        defer { cleanUp() }
        try installPack("a", title: "A")
        let probe = ListProbe(held: true)
        connect(probe)

        vm.refreshList()
        try await waitUntil { probe.listingCount >= 1 }
        try installPack("b", title: "B")
        vm.refreshList()
        vm.refreshList()
        vm.refreshList()
        probe.release()
        try await settle()

        #expect(probe.listingCount == 2, "the folders were listed \(probe.listingCount) times")
        #expect(titles == ["A", "B"], "a pack added during the read is missing")
        #expect(!vm.isRefreshing)
    }

    @Test func aReadOvertakenByADeleteIsNotShown() async throws {
        defer { cleanUp() }
        try installPack("a", title: "A")
        try installPack("b", title: "B")
        vm.refreshList()
        try await settle()
        let b = try #require(vm.unipackItems.first { $0.unipack.title == "B" })
        let probe = ListProbe(held: true)
        connect(probe)

        vm.refreshList()
        try await waitUntil { probe.listingCount >= 1 }
        vm.deleteItem(b)
        #expect(titles == ["A"], "the deleted pack stayed in the list until the read finished")
        probe.release()
        try await settle()

        #expect(!vm.deleteFailed)
        #expect(titles == ["A"], "the deleted pack came back from the read that started before it")
    }

    @Test func selectionSearchSortBookmarkAndPlayCountSurviveAReload() async throws {
        defer { cleanUp() }
        try installPack("faded", title: "Faded", producer: "Alan Walker")
        try installPack("spectre", title: "Spectre", producer: "Alan Walker")
        try installPack("sunflower", title: "Sunflower", producer: "Post Malone")
        vm.refreshList()
        try await settle()
        let spectre = try #require(vm.unipackItems.first { $0.unipack.title == "Spectre" })
        vm.toggleSelection(spectre)
        try await waitUntil { spectre.unipack.detailLoaded }

        vm.updateSearchQuery("alan")
        vm.sortMethod = .playCount
        vm.sortAscending = false
        vm.toggleBookmark(spectre)
        vm.recordOpen(spectre)
        vm.refreshList()
        try await settle()

        let reloaded = try #require(vm.selectedItem)
        #expect(titles == ["Spectre", "Faded"])
        #expect(reloaded.id == spectre.id)
        #expect(reloaded.unipack !== spectre.unipack, "the reload should have read the pack again")
        #expect(reloaded.isBookmarked)
        #expect(reloaded.openCount == 1)
        #expect(reloaded.lastOpenedAt != nil)
        try await waitUntil { reloaded.unipack.detailLoaded }
        #expect(reloaded.unipack.detailLoaded, "the selected pack's detail was not read again")
        #expect(reloaded.unipack.soundCount == 1)
    }

    @Test func selectingAnotherPackWhileTheListIsReadKeepsThatSelection() async throws {
        defer { cleanUp() }
        try installPack("a", title: "A")
        try installPack("b", title: "B")
        vm.refreshList()
        try await settle()
        let a = try #require(vm.unipackItems.first { $0.unipack.title == "A" })
        let b = try #require(vm.unipackItems.first { $0.unipack.title == "B" })
        vm.toggleSelection(a)
        try await waitUntil { a.unipack.detailLoaded }
        let probe = ListProbe(held: true)
        connect(probe)

        vm.refreshList()
        try await waitUntil { probe.listingCount >= 1 }
        vm.toggleSelection(b)
        #expect(vm.selectedItem?.id == b.id)
        probe.release()
        try await settle()

        let selected = try #require(vm.selectedItem)
        #expect(selected.id == b.id)
        #expect(vm.unipackItems.contains { $0.unipack === selected.unipack }, "the selection points at a pack that is not in the list")
        try await waitUntil { selected.unipack.detailLoaded }
        #expect(selected.unipack.detailLoaded)
        #expect(selected.unipack.soundCount == 1)
    }

    @Test func importResultWaitsForTheReloadThatFindsTheImportedPack() async throws {
        defer { cleanUp() }
        try installPack("a", title: "A")
        vm.refreshList()
        try await settle()
        let probe = ListProbe(held: true)
        connect(probe)

        let imported = try installPack("b", title: "B")
        vm.refreshList()
        let showing = Task { await vm.showImportResult(forImportedFolder: imported) }
        try await waitUntil { probe.listingCount >= 1 }
        #expect(vm.importResult == nil, "the import result was decided before the reload found the pack")
        probe.release()
        await showing.value

        guard case .success(let pack) = vm.importResult else {
            Issue.record("expected the import result of the new pack, got \(String(describing: vm.importResult))")
            return
        }
        #expect(pack.title == "B")
    }

    @Test func aRefreshRequestedDuringAReadStillShowsThatReadWhileTheFollowUpRuns() async throws {
        defer { cleanUp() }
        try installPack("a", title: "A")
        let probe = ListProbe(held: true)
        connect(probe)

        vm.refreshList()
        try await waitUntil { probe.listingCount >= 1 }
        vm.refreshList()
        probe.release()
        try await waitUntil { !vm.unipackItems.isEmpty }
        #expect(titles == ["A"], "the first read was thrown away by a request that did not change the disk")
        try await settle()

        #expect(probe.listingCount == 2)
        #expect(titles == ["A"])
    }

    // MARK: - Download-date sort keys

    @Test func sortingByDownloadDateDoesNotWalkPackFoldersOnTheMainThread() async throws {
        defer { cleanUp() }
        try installPack("mid", title: "Mid")
        try installPack("new", title: "New")
        try installPack("old", title: "Old")
        let probe = ListProbe()
        connect(probe)
        vm.sortMethod = .downloadDate
        vm.sortAscending = false

        vm.refreshList()
        try await settle()
        vm.updateSearchQuery("e")
        vm.updateSearchQuery("")

        #expect(titles == ["New", "Mid", "Old"])
        #expect(probe.folderWalksOnMainThread == 0, "the modification time was read on the main thread")
    }

    @Test func aReloadSortedByTitleDoesNotWalkPackFolders() async throws {
        defer { cleanUp() }
        try installPack("a", title: "A")
        try installPack("b", title: "B")
        let probe = ListProbe()
        connect(probe)

        vm.refreshList()
        try await settle()

        #expect(titles == ["A", "B"])
        #expect(probe.folderWalks == 0, "a title-sorted reload walked \(probe.folderWalks) pack folders")
    }

    @Test func downloadDateReloadsWalkEachPackOnceAndFilteringReusesTheSnapshot() async throws {
        defer { cleanUp() }
        try installPack("mid", title: "Mid")
        let new = try installPack("new", title: "New")
        try installPack("old", title: "Old")
        let probe = ListProbe()
        connect(probe)
        vm.sortMethod = .downloadDate
        vm.sortAscending = true

        vm.refreshList()
        try await settle()
        vm.refreshList()
        try await settle()
        #expect(titles == ["Old", "Mid", "New"])
        #expect(probe.folderWalks == 6, "each disk reload should walk each pack once: \(probe.folderWalks) walks")
        vm.updateSearchQuery("mid")
        vm.updateSearchQuery("")
        #expect(probe.folderWalks == 6, "filtering walked the pack folders again")

        try Data().write(to: new.appending(path: "autoPlay"))
        vm.refreshList()
        try await settle()

        #expect(titles == ["Old", "Mid", "New"])
        #expect(probe.folderWalks == 9, "a disk reload should read fresh sort keys once: \(probe.folderWalks) walks")
        #expect(probe.folderWalksOnMainThread == 0)
    }

    @Test func aFileAddedToAPacksSoundsFolderWalksThatPackAgain() async throws {
        defer { cleanUp() }
        let pack = try installPack("new", title: "New")
        let probe = ListProbe()
        connect(probe)
        vm.sortMethod = .downloadDate

        vm.refreshList()
        try await settle()
        try Data().write(to: pack.appending(path: "sounds/b.wav"))
        vm.refreshList()
        try await settle()

        #expect(probe.folderWalks == 2, "a change in sounds/ reused the old sort key: \(probe.folderWalks) walks")
    }

    /// Set deterministic dates on real files, rather than the probed pack's synthetic sort key.
    private func setFileDates(in folder: URL, to time: TimeInterval) throws {
        let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in files {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: file.path)
            }
        }
    }

    @Test func downloadDateReloadReflectsAnExistingFileRewrite() async throws {
        defer { cleanUp() }
        let older = try installPack("a", title: "A")
        let newer = try installPack("b", title: "B")
        try setFileDates(in: older, to: 100)
        try setFileDates(in: newer, to: 150)
        vm.readPack = { UniPackFolder(rootFolder: $0).load() }
        vm.sortMethod = .downloadDate
        vm.sortAscending = false
        vm.refreshList()
        try await settle()
        #expect(titles == ["B", "A"])
        let folderDate = try older.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        // A non-atomic rewrite preserves the parent directory's modification date.
        let keySound = older.appending(path: "keySound")
        try "1 1 1 a.wav\n".write(to: keySound, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: keySound.path)
        #expect(try older.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == folderDate)
        vm.refreshList()
        try await settle()

        #expect(titles == ["A", "B"])
        #expect(vm.unipackItems.first?.lastModified == 200)
    }

    @Test func downloadDateReloadReflectsADeepFolderChange() async throws {
        defer { cleanUp() }
        let older = try installPack("a", title: "A")
        let newer = try installPack("b", title: "B")
        let sounds = older.appending(path: "sounds")
        let deep = sounds.appending(path: "nested/deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data().write(to: deep.appending(path: "existing.wav"))
        try setFileDates(in: older, to: 100)
        try setFileDates(in: newer, to: 150)
        vm.readPack = { UniPackFolder(rootFolder: $0).load() }
        vm.sortMethod = .downloadDate
        vm.sortAscending = false
        vm.refreshList()
        try await settle()
        #expect(titles == ["B", "A"])
        let soundsDate = try sounds.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let added = deep.appending(path: "added.wav")
        try Data().write(to: added)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: added.path)
        #expect(try sounds.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == soundsDate)
        vm.refreshList()
        try await settle()

        #expect(titles == ["A", "B"])
        #expect(vm.unipackItems.first?.lastModified == 200)
    }

    @Test func switchingToDownloadDateDuringAReadShowsTheDownloadDateOrder() async throws {
        defer { cleanUp() }
        try installPack("mid", title: "Mid")
        try installPack("new", title: "New")
        try installPack("old", title: "Old")
        vm.sortAscending = true
        let probe = ListProbe(held: true)
        connect(probe)

        vm.refreshList()
        try await waitUntil { probe.listingCount >= 1 }
        vm.sortMethod = .downloadDate
        probe.release()
        try await settle()

        #expect(titles == ["Old", "Mid", "New"])
        #expect(probe.folderWalks == 3)
    }

    // MARK: - Import result

    /// Runs what the main screen runs once the importer has put the pack in place.
    private func finishImport(of folder: URL) async {
        MainViewImportDelegate(viewModel: vm).onImportComplete(folder: folder)
        await vm.completeImport(importedFolder: folder)
    }

    private func importedPack() -> UniPack? {
        if case .success(let pack) = vm.importResult { return pack }
        Issue.record("expected a success result, got \(String(describing: vm.importResult))")
        return nil
    }

    @Test func importResultIsReadOnceAndOffTheMainThread() async throws {
        defer { cleanUp() }
        try installPack("a", title: "A")
        let probe = ListProbe()
        connect(probe)
        vm.refreshList()
        try await settle()
        let imported = try installPack("b", title: "B")

        await finishImport(of: imported)

        #expect(probe.packReadsOnMainThread == 0, "\(probe.packReadsOnMainThread) pack info reads ran on the main thread")
        #expect(probe.detailReadsOnMainThread == 0, "\(probe.detailReadsOnMainThread) detail reads ran on the main thread")
        #expect(probe.detailReadCount == 1, "the imported pack's detail was read \(probe.detailReadCount) times")
        let pack = importedPack()
        #expect(pack?.title == "B")
        #expect(pack?.soundCount == 1)
        #expect(vm.unipackItems.contains { $0.unipack === pack }, "the result is not the pack in the list")
    }

    @Test func importProgressStaysUntilTheResultIsReady() async throws {
        defer { cleanUp() }
        let probe = ListProbe(heldDetails: ["b"])
        connect(probe)
        let imported = try installPack("b", title: "B")
        vm.isImportingInProgress = true

        let finishing = Task { await finishImport(of: imported) }
        try await waitUntil { probe.detailReadCount >= 1 }
        #expect(vm.isImportingInProgress, "the progress went away before the import result was ready")
        #expect(vm.importResult == nil)
        probe.releaseDetail(of: "b")
        await finishing.value

        #expect(!vm.isImportingInProgress)
        #expect(importedPack()?.title == "B")
    }

    @Test func anOlderImportResultDoesNotReplaceANewerOne() async throws {
        defer { cleanUp() }
        let older = try installPack("a", title: "A")
        let newer = try installPack("b", title: "B")
        let probe = ListProbe(heldDetails: ["a"])
        connect(probe)
        vm.refreshList()
        try await settle()

        let showingOlder = Task { await vm.showImportResult(forImportedFolder: older) }
        try await waitUntil { probe.detailReadCount >= 1 }
        await vm.showImportResult(forImportedFolder: newer)
        #expect(importedPack()?.title == "B")
        probe.releaseDetail(of: "a")
        await showingOlder.value

        #expect(importedPack()?.title == "B", "the older import result replaced the newer one")
    }

    @Test func anOlderImportFinishingDoesNotTakeDownTheProgressOfANewerOne() async throws {
        defer { cleanUp() }
        let older = try installPack("a", title: "A")
        let newer = try installPack("b", title: "B")
        let probe = ListProbe(heldDetails: ["a", "b"])
        connect(probe)
        vm.isImportingInProgress = true

        let finishingOlder = Task { await vm.completeImport(importedFolder: older) }
        try await waitUntil { probe.detailReadCount >= 1 }
        let finishingNewer = Task { await vm.completeImport(importedFolder: newer) }
        try await waitUntil { probe.detailReadCount >= 2 }
        probe.releaseDetail(of: "a")
        await finishingOlder.value
        #expect(vm.isImportingInProgress, "the older import took down the progress of the newer one")
        probe.releaseDetail(of: "b")
        await finishingNewer.value

        #expect(!vm.isImportingInProgress)
        #expect(importedPack()?.title == "B")
    }

    @Test func aLaterImportFailureIsNotReplacedByAnEarlierSuccess() async throws {
        defer { cleanUp() }
        let older = try installPack("a", title: "A")
        let probe = ListProbe(heldDetails: ["a"])
        connect(probe)
        vm.isImportingInProgress = true
        let finishingOlder = Task { await vm.completeImport(importedFolder: older) }
        try await waitUntil { probe.detailReadCount >= 1 }

        let error = NSError(domain: "MainListReadTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Later import failed"])
        MainViewImportDelegate(viewModel: vm).onImportError(error)
        await vm.completeImport(importedFolder: nil)
        #expect(!vm.isImportingInProgress)
        probe.releaseDetail(of: "a")
        await finishingOlder.value
        try await settle()

        guard case .error(let message) = vm.importResult else {
            Issue.record("the earlier success replaced the later error: \(String(describing: vm.importResult))")
            return
        }
        #expect(message == "Later import failed")
        #expect(!vm.isImportingInProgress)
    }

    @Test func externalFailureDuringCompletionDoesNotLeaveProgressStuck() async throws {
        defer { cleanUp() }
        let older = try installPack("a", title: "A")
        let probe = ListProbe(heldDetails: ["a"])
        connect(probe)
        vm.isImportingInProgress = true
        let finishingOlder = Task { await vm.completeImport(importedFolder: older) }
        try await waitUntil { probe.detailReadCount >= 1 }

        // The external failure notification only shows the error; no completion follows it.
        vm.showImportError("External import failed")
        #expect(!vm.isImportingInProgress, "the error dialog is still covered by progress")
        probe.releaseDetail(of: "a")
        await finishingOlder.value

        guard case .error(let message) = vm.importResult else {
            Issue.record("the earlier success replaced the external error")
            return
        }
        #expect(message == "External import failed")
        #expect(!vm.isImportingInProgress, "the invalidated completion left progress stuck")
        #expect(probe.timedOutWaits == 0)
    }

    @Test func anImportErrorInvalidatesEarlierSuccessBeforeCompletion() async throws {
        defer { cleanUp() }
        let older = try installPack("a", title: "A")
        let probe = ListProbe(heldDetails: ["a"])
        connect(probe)
        vm.refreshList()
        try await settle()
        let showingOlder = Task { await vm.showImportResult(forImportedFolder: older) }
        try await waitUntil { probe.detailReadCount >= 1 }

        let error = NSError(domain: "MainListReadTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Later import failed"])
        MainViewImportDelegate(viewModel: vm).onImportError(error)
        probe.releaseDetail(of: "a")
        #expect(await showingOlder.value == false)
        guard case .error(let message) = vm.importResult else {
            Issue.record("the earlier success replaced the error before completion")
            return
        }
        #expect(message == "Later import failed")
    }

    @Test func selectingTheImportedPackWhileItsResultIsReadReadsItsDetailOnce() async throws {
        defer { cleanUp() }
        let imported = try installPack("b", title: "B")
        let probe = ListProbe(heldDetails: ["b"])
        connect(probe)
        vm.refreshList()
        try await settle()

        let showing = Task { await vm.showImportResult(forImportedFolder: imported) }
        try await waitUntil { probe.detailReadCount >= 1 }
        let item = try #require(vm.unipackItems.first)
        vm.toggleSelection(item)
        probe.releaseDetail(of: "b")
        await showing.value
        try await waitUntil { vm.selectedItem?.unipack.detailLoaded == true }

        #expect(probe.detailReadCount == 1)
        #expect(importedPack() === vm.selectedItem?.unipack)
        #expect(vm.selectedItem?.unipack.soundCount == 1)
    }

    @Test func importResultOfAPackMissingFromTheListIsStillReadOffTheMainThread() async throws {
        defer { cleanUp() }
        let elsewhere = FileManager.default.temporaryDirectory
            .appending(path: "MainListReadTests-elsewhere-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let folder = elsewhere.appending(path: "b", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "sounds"), withIntermediateDirectories: true)
        try "title=B\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\n"
            .write(to: folder.appending(path: "info"), atomically: true, encoding: .utf8)
        try "1 1 1 a.wav\n1 1 2 b.wav\n".write(to: folder.appending(path: "keySound"), atomically: true, encoding: .utf8)
        try Data().write(to: folder.appending(path: "sounds/a.wav"))
        let probe = ListProbe()
        connect(probe)

        await finishImport(of: folder)

        guard case .warning(let message) = vm.importResult else {
            Issue.record("expected a warning, got \(String(describing: vm.importResult))")
            return
        }
        #expect(message.contains("[1 1 2 b.wav] sound was not found"))
        #expect(probe.packReadsOnMainThread == 0)
        #expect(probe.detailReadsOnMainThread == 0)
    }

    @Test func importResultOfAnUnreadablePackIsAWarning() async throws {
        defer { cleanUp() }
        let missing = workspace.appending(path: "gone", directoryHint: .isDirectory)
        let probe = ListProbe()
        connect(probe)

        await finishImport(of: missing)

        guard case .warning(let message) = vm.importResult else {
            Issue.record("expected a warning, got \(String(describing: vm.importResult))")
            return
        }
        #expect(message.contains("Cannot read directory contents"))
        #expect(probe.packReadsOnMainThread == 0)
    }
}
