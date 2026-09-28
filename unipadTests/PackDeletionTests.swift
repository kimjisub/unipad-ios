import Foundation
import SwiftData
import Testing
@testable import unipad

/// Deleting a pack removes its files first and its saved row (bookmark, play count) only after that.
@MainActor
struct PackDeletionTests {
    private let workspace: URL
    private let container: ModelContainer
    private let repo: UnipackRepository
    private let vm = MainViewModel()

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "PackDeletionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        container = try ModelContainerFactory.openInMemory()
        repo = UnipackRepository(modelContainer: container)
        vm.modelContainer = container
    }

    private func installPack(_ name: String) throws -> UniPackItem {
        let folder = workspace.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "sounds"), withIntermediateDirectories: true)
        try "title=Test\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\n"
            .write(to: folder.appending(path: "info"), atomically: true, encoding: .utf8)
        try "1 1 1 a.wav\n".write(to: folder.appending(path: "keySound"), atomically: true, encoding: .utf8)
        try Data().write(to: folder.appending(path: "sounds/a.wav"))
        return UniPackItem(unipack: UniPackFolder(rootFolder: folder))
    }

    /// One play and a bookmark, the history a reinstall must not bring back.
    private func seedHistory(_ id: String) throws {
        _ = try repo.getOrCreate(id: id)
        try repo.recordOpen(id: id)
        try repo.toggleBookmark(id: id)
    }

    private func cleanUp() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.path)
        try? FileManager.default.removeItem(at: workspace)
    }

    @Test func deleteRemovesFilesAndRow() throws {
        defer { cleanUp() }
        let item = try installPack("Pack A")
        try seedHistory("Pack A")

        vm.deleteItem(item)

        #expect(!FileManager.default.fileExists(atPath: item.unipack.getPathString()))
        #expect(try repo.find(id: "Pack A") == nil)
        #expect(!vm.deleteFailed)
    }

    @Test func reinstallAfterDeleteStartsWithoutHistory() throws {
        defer { cleanUp() }
        try seedHistory("Pack A")
        vm.deleteItem(try installPack("Pack A"))

        _ = try installPack("Pack A")
        let entity = try repo.getOrCreate(id: "Pack A")

        #expect(entity.openCount == 0)
        #expect(!entity.bookmark)
        #expect(entity.lastOpenedAt == nil)
    }

    @Test func deleteLeavesOtherPacksAlone() throws {
        defer { cleanUp() }
        let item = try installPack("Pack A")
        let other = try installPack("Pack B")
        try seedHistory("Pack A")
        try seedHistory("Pack B")

        vm.deleteItem(item)

        #expect(FileManager.default.fileExists(atPath: other.unipack.getPathString()))
        let kept = try #require(try repo.find(id: "Pack B"))
        #expect(kept.openCount == 1)
        #expect(kept.bookmark)
    }

    @Test func fileDeleteFailureKeepsRowAndReportsIt() throws {
        defer { cleanUp() }
        let item = try installPack("Pack A")
        try seedHistory("Pack A")
        // A read-only workspace: the pack folder cannot be unlinked from it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: workspace.path)

        vm.deleteItem(item)

        #expect(vm.deleteFailed)
        #expect(FileManager.default.fileExists(atPath: item.unipack.getPathString()))
        let kept = try #require(try repo.find(id: "Pack A"))
        #expect(kept.openCount == 1)
        #expect(kept.bookmark)
    }

    @Test func rowDeleteFailureIsReported() throws {
        defer { cleanUp() }
        let item = try installPack("Pack A")
        try seedHistory("Pack A")
        vm.makeRecordRemover = { _ in FailingRecordRemover() }

        vm.deleteItem(item)

        #expect(vm.deleteFailed)
        #expect(try repo.find(id: "Pack A") != nil)
    }

    @Test func deleteWithoutStoreDeletesNothing() throws {
        defer { cleanUp() }
        let item = try installPack("Pack A")
        try seedHistory("Pack A")
        vm.modelContainer = nil

        vm.deleteItem(item)

        #expect(vm.deleteFailed)
        #expect(FileManager.default.fileExists(atPath: item.unipack.getPathString()))
        #expect(try repo.find(id: "Pack A") != nil)
    }

    @Test func retryAfterFailureSucceeds() throws {
        defer { cleanUp() }
        let item = try installPack("Pack A")
        try seedHistory("Pack A")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: workspace.path)
        vm.deleteItem(item)
        #expect(vm.deleteFailed)

        vm.deleteFailed = false
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.path)
        vm.deleteItem(item)

        #expect(!vm.deleteFailed)
        #expect(!FileManager.default.fileExists(atPath: item.unipack.getPathString()))
        #expect(try repo.find(id: "Pack A") == nil)
    }

    private func seedPlays(_ id: String, count: Int) throws {
        _ = try repo.getOrCreate(id: id)
        for _ in 0..<count {
            try repo.recordOpen(id: id)
        }
    }

    @Test func deleteUpdatesTotalPlayCountWithoutRelaunch() throws {
        defer { cleanUp() }
        let item = try installPack("Pack A")
        _ = try installPack("Pack B")
        try seedPlays("Pack A", count: 3)
        try seedPlays("Pack B", count: 2)
        vm.updateStats()
        #expect(vm.totalOpenCount == 5)

        vm.deleteItem(item)

        #expect(!vm.deleteFailed)
        #expect(vm.totalOpenCount == 2)
        #expect(Int64(vm.totalOpenCount) == (try repo.totalOpenCount()))
    }

    @Test func fileDeleteFailureKeepsTotalPlayCount() throws {
        defer { cleanUp() }
        let item = try installPack("Pack A")
        _ = try installPack("Pack B")
        try seedPlays("Pack A", count: 3)
        try seedPlays("Pack B", count: 2)
        vm.updateStats()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: workspace.path)

        vm.deleteItem(item)

        #expect(vm.deleteFailed)
        #expect(vm.totalOpenCount == 5)
    }

    /// The files are gone but the row stays, so the total still counts the row.
    @Test func rowDeleteFailureShowsStoredTotal() throws {
        defer { cleanUp() }
        let item = try installPack("Pack A")
        _ = try installPack("Pack B")
        try seedPlays("Pack A", count: 3)
        try seedPlays("Pack B", count: 2)
        vm.updateStats()
        vm.makeRecordRemover = { _ in FailingRecordRemover() }

        vm.deleteItem(item)

        #expect(vm.deleteFailed)
        #expect(Int64(vm.totalOpenCount) == (try repo.totalOpenCount()))
        #expect(vm.totalOpenCount == 5)
    }

    @Test func deleteWithoutSavedRowSucceeds() throws {
        defer { cleanUp() }
        let item = try installPack("Pack A")

        vm.deleteItem(item)

        #expect(!vm.deleteFailed)
        #expect(!FileManager.default.fileExists(atPath: item.unipack.getPathString()))
    }
}

private struct FailingRecordRemover: UnipackRecordRemoving {
    struct Failure: Error {}

    func delete(id: String) throws {
        throw Failure()
    }
}
