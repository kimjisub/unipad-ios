import Foundation
import SwiftData
import Testing
@testable import unipad

/// Typing in the pack search filters the packs already read from disk; only a reload scans the folders again.
@MainActor
struct MainSearchTests {
    private let workspace: URL
    private let container: ModelContainer
    private let repo: UnipackRepository
    private let vm = MainViewModel()
    private let scans = ScanCounter()

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "MainSearchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        container = try ModelContainerFactory.openInMemory()
        repo = UnipackRepository(modelContainer: container)
        vm.modelContainer = container
        vm.sortMethod = .title
        vm.sortAscending = true
        let workspace = workspace
        let scans = scans
        vm.packFolderSource = {
            scans.count += 1
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: workspace, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )) ?? []
            return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    @discardableResult
    private func installPack(_ folderName: String, title: String, producer: String) throws -> URL {
        let folder = workspace.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "sounds"), withIntermediateDirectories: true)
        try "title=\(title)\nproducerName=\(producer)\nbuttonX=8\nbuttonY=8\nchain=1\n"
            .write(to: folder.appending(path: "info"), atomically: true, encoding: .utf8)
        try "1 1 1 a.wav\n".write(to: folder.appending(path: "keySound"), atomically: true, encoding: .utf8)
        try Data().write(to: folder.appending(path: "sounds/a.wav"))
        return folder
    }

    private func installLibrary() throws {
        try installPack("faded", title: "Faded", producer: "Alan Walker")
        try installPack("spectre", title: "The Spectre", producer: "Alan Walker")
        try installPack("sunflower", title: "Sunflower", producer: "Post Malone")
        try installPack("spring", title: "봄날", producer: "방탄소년단")
    }

    /// Lets the main-actor reload task that `refreshList()` schedules run to completion.
    private func settle() async {
        while vm.isRefreshing {
            await Task.yield()
        }
    }

    private func reload() async {
        vm.refreshList()
        await settle()
    }

    private func type(_ text: String) async {
        var typed = ""
        for character in text {
            typed.append(character)
            vm.updateSearchQuery(typed)
            await settle()
        }
    }

    private var titles: [String] {
        vm.unipackItems.map(\.unipack.title)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: workspace)
    }

    @Test func typingDoesNotRescanDisk() async throws {
        defer { cleanUp() }
        try installLibrary()
        await reload()
        #expect(scans.count == 1)

        await type("spec")
        vm.updateSearchQuery("")
        await settle()

        #expect(scans.count == 1)
    }

    @Test func matchesTitleIgnoringCase() async throws {
        defer { cleanUp() }
        try installLibrary()
        await reload()

        await type("SUN")

        #expect(titles == ["Sunflower"])
    }

    @Test func matchesProducer() async throws {
        defer { cleanUp() }
        try installLibrary()
        await reload()

        await type("alan")

        #expect(titles == ["Faded", "The Spectre"])
    }

    @Test func matchesKorean() async throws {
        defer { cleanUp() }
        try installLibrary()
        await reload()

        vm.updateSearchQuery("봄")
        await settle()
        #expect(titles == ["봄날"])

        vm.updateSearchQuery("방탄")
        await settle()
        #expect(titles == ["봄날"])
    }

    @Test func noMatchShowsEmptyList() async throws {
        defer { cleanUp() }
        try installLibrary()
        await reload()

        await type("zzz")

        #expect(vm.unipackItems.isEmpty)
    }

    @Test func clearingQueryRestoresSortedLibrary() async throws {
        defer { cleanUp() }
        try installLibrary()
        await reload()
        let all = titles

        await type("alan")
        vm.updateSearchQuery("")
        await settle()

        #expect(titles == all)
        #expect(titles.count == 4)
    }

    @Test func resultsKeepSortOrder() async throws {
        defer { cleanUp() }
        try installLibrary()
        vm.sortAscending = false
        await reload()

        await type("alan")

        #expect(titles == ["The Spectre", "Faded"])
    }

    @Test func selectionSurvivesWhileItStillMatches() async throws {
        defer { cleanUp() }
        try installLibrary()
        await reload()
        let faded = try #require(vm.unipackItems.first { $0.unipack.title == "Faded" })
        vm.selectedItem = faded

        await type("alan")
        #expect(vm.selectedItem?.id == faded.id)

        vm.updateSearchQuery("sun")
        await settle()
        #expect(vm.selectedItem == nil)
    }

    @Test func recentPacksFollowSearch() async throws {
        defer { cleanUp() }
        try installLibrary()
        _ = try repo.getOrCreate(id: "faded")
        try repo.recordOpen(id: "faded")
        await reload()
        #expect(MainRecentPacks.select(from: vm.unipackItems).map(\.unipack.title) == ["Faded"])

        await type("sun")
        #expect(MainRecentPacks.select(from: vm.unipackItems).isEmpty)

        vm.updateSearchQuery("")
        await settle()
        #expect(MainRecentPacks.select(from: vm.unipackItems).map(\.unipack.title) == ["Faded"])
    }

    @Test func reloadPicksUpImportedPackUnderActiveQuery() async throws {
        defer { cleanUp() }
        try installLibrary()
        await reload()
        await type("alan")

        try installPack("alone", title: "Alone", producer: "Alan Walker")
        await reload()

        #expect(scans.count == 2)
        #expect(titles == ["Alone", "Faded", "The Spectre"])
    }

    @Test func deleteRefreshesFilteredList() async throws {
        defer { cleanUp() }
        try installLibrary()
        await reload()
        await type("alan")
        let faded = try #require(vm.unipackItems.first { $0.unipack.title == "Faded" })

        vm.deleteItem(faded)
        await settle()

        #expect(!vm.deleteFailed)
        #expect(titles == ["The Spectre"])
    }

    @Test func queryTypedDuringReloadAppliesToReloadedList() async throws {
        defer { cleanUp() }
        try installLibrary()
        await reload()

        try installPack("alone", title: "Alone", producer: "Alan Walker")
        vm.refreshList()
        vm.updateSearchQuery("alan")
        await settle()

        #expect(titles == ["Alone", "Faded", "The Spectre"])
    }

    /// Prints what one keystroke costs with a small and a large library. Runs only when
    /// `TEST_RUNNER_UNIPAD_SEARCH_BENCH_OUT=<existing file>` is set; each line is appended to that file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["UNIPAD_SEARCH_BENCH_OUT"] != nil),
          arguments: [5, 500])
    func measureKeystrokeCost(packCount: Int) async throws {
        defer { cleanUp() }
        for index in 0..<packCount {
            try installPack(String(format: "pack%04d", index), title: "Pack \(index)", producer: "Producer \(index % 7)")
        }

        let reloadStart = ContinuousClock.now
        await reload()
        let reloadTime = reloadStart.duration(to: .now)
        let scansBefore = scans.count

        let query = "pack 12"
        let typingStart = ContinuousClock.now
        await type(query)
        let typingTime = typingStart.duration(to: .now)
        let keystrokeScans = scans.count - scansBefore

        let line = """
            UNIPAD_SEARCH_BENCH packs=\(packCount) fullReload=\(reloadTime) \
            keystrokes=\(query.count) typingTotal=\(typingTime) perKeystroke=\(typingTime / query.count) \
            folderScansWhileTyping=\(keystrokeScans) packLoadsWhileTyping=\(keystrokeScans * packCount) \
            results=\(vm.unipackItems.count)
            """
        print(line)
        if let out = ProcessInfo.processInfo.environment["UNIPAD_SEARCH_BENCH_OUT"],
           let handle = FileHandle(forWritingAtPath: out) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            handle.closeFile()
        }
    }
}

@MainActor
private final class ScanCounter {
    var count = 0
}
