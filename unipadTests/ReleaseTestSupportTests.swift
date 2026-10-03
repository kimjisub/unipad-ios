#if DEBUG || UNIPAD_RELEASE_TESTS
import Foundation
import XCTest
@testable import unipad

@MainActor
final class ReleaseTestSupportTests: XCTestCase {
    func testPlayUsageLibraryPreparesTheScreenScenariosPack() throws {
        let defaults = UserDefaults.standard
        let keys = ["UniPadReleaseTest", "UniPadReleaseEmpty", "UniPadUITestLibrary"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        defaults.set(UUID().uuidString, forKey: keys[0])
        defaults.set(false, forKey: keys[1])
        defaults.set("play-usage", forKey: keys[2])
        let root = try XCTUnwrap(ReleaseTestSupport.root)
        defer { try? FileManager.default.removeItem(at: root) }
        try ReleaseTestSupport.prepare()
        let workspace = try XCTUnwrap(WorkspaceManager.currentWorkspaces().first)
        let folders = WorkspaceManager.unipackFolders(in: workspace)
        XCTAssertEqual(folders.count, 1)
        let folder = try XCTUnwrap(folders.first)
        let pack = UniPackFolder(rootFolder: folder)
        pack.load()
        pack.loadDetail()
        XCTAssertFalse(pack.criticalError, pack.errorDetail ?? "")
        XCTAssertEqual(pack.title, "JIS20 First Input Fixture")
        XCTAssertEqual(pack.buttonX, 8)
        XCTAssertEqual(pack.buttonY, 8)
        XCTAssertEqual(pack.chain, 1)
        XCTAssertTrue(pack.squareButton)
        XCTAssertEqual(pack.soundCount, 3)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("autoPlay"), encoding: .utf8),
                       "on 1 1\ndelay 400\non 1 2\ndelay 400\non 1 3\n")
    }

    func testSearchLibraryHasTitlesAndProducersUsedByScreenChecks() throws {
        let defaults = UserDefaults.standard
        let keys = ["UniPadReleaseTest", "UniPadReleaseEmpty", "UniPadUITestLibrary"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        defaults.set(UUID().uuidString, forKey: keys[0])
        defaults.set(false, forKey: keys[1])
        defaults.set("search", forKey: keys[2])
        let root = try XCTUnwrap(ReleaseTestSupport.root)
        defer { try? FileManager.default.removeItem(at: root) }
        try ReleaseTestSupport.prepare()
        let workspace = try XCTUnwrap(WorkspaceManager.currentWorkspaces().first)
        let packs = WorkspaceManager.unipackFolders(in: workspace).map { folder in
            let pack = UniPackFolder(rootFolder: folder)
            pack.load()
            return pack
        }
        XCTAssertEqual(Set(packs.map(\.title)), Set(["Alan Walker - Faded", "Sunflower", "봄날"]))
        XCTAssertEqual(packs.first { $0.title == "Sunflower" }?.producerName, "Post Malone")
        XCTAssertTrue(packs.first { $0.title == "Alan Walker - Faded" }?.producerName.contains("김지섭") == true)
    }

    func testDeletionFixtureIsProtectedUntilNextLaunchUnlocksIt() throws {
        let defaults = UserDefaults.standard
        let keys = ["UniPadReleaseTest", "UniPadReleaseEmpty", "UniPadUITestLibrary", "UniPadUITestDeleteFailure"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        defaults.set(UUID().uuidString, forKey: keys[0])
        defaults.set(false, forKey: keys[1])
        defaults.set("deletion", forKey: keys[2])
        defaults.set(true, forKey: keys[3])
        let root = try XCTUnwrap(ReleaseTestSupport.root)
        let file = root.appendingPathComponent("UniPack/Deletion/info")
        defer {
            defaults.set(false, forKey: keys[3])
            try? ReleaseTestSupport.prepare()
            try? FileManager.default.removeItem(at: root)
        }
        try ReleaseTestSupport.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.immutable] as? Bool, true)
        XCTAssertThrowsError(try FileManager.default.removeItem(at: file))
        let packRoot = file.deletingLastPathComponent()
        XCTAssertThrowsError(try UniPackFolder(rootFolder: packRoot).delete())
        let pack = UniPackFolder(rootFolder: packRoot)
        pack.load()
        XCTAssertFalse(pack.criticalError, "a rejected deletion must keep the full fixture readable")
        XCTAssertEqual(pack.title, "UI Test Pack")
        defaults.set(false, forKey: keys[3])
        try ReleaseTestSupport.prepare()
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPlayLoadingPauseRequiresBothIsolatedLibraryAndExplicitRequest() {
        let defaults = UserDefaults.standard
        let keys = ["UniPadReleaseTest", "UniPadUITestHoldPlayLoading"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        defaults.set(true, forKey: keys[1])
        for token in [nil, "not-a-uuid"] as [String?] {
            defaults.set(token, forKey: keys[0])
            XCTAssertFalse(ReleaseTestSupport.holdPlayLoading)
        }
        defaults.set(UUID().uuidString, forKey: keys[0])
        defaults.set(false, forKey: keys[1])
        XCTAssertFalse(ReleaseTestSupport.holdPlayLoading)
        defaults.set(true, forKey: keys[1])
        XCTAssertTrue(ReleaseTestSupport.holdPlayLoading)
    }

    func testWorkspaceSelectsSeparateLibraryForValidToken() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "UniPadReleaseTest")
        let token = UUID().uuidString
        defaults.set(token, forKey: "UniPadReleaseTest")
        defer { defaults.set(previous, forKey: "UniPadReleaseTest") }
        let expected = WorkspaceManager.documentsDirectory
            .appendingPathComponent("ReleaseTests/\(token)/UniPack")
        defer { try? FileManager.default.removeItem(at: expected.deletingLastPathComponent()) }
        XCTAssertEqual(WorkspaceManager.currentWorkspaces().map { $0.url.path }, [expected.path])
    }

    func testMissingOrInvalidTokenLeavesSupportDisabled() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "UniPadReleaseTest")
        defer { defaults.set(previous, forKey: "UniPadReleaseTest") }
        for token in [nil, "", "not-a-uuid", "../UniPack"] as [String?] {
            defaults.set(token, forKey: "UniPadReleaseTest")
            XCTAssertNil(ReleaseTestSupport.root)
            XCTAssertNil(ReleaseTestSupport.storeURL)
            let configuration = URLSessionConfiguration.ephemeral
            let previousProtocols = configuration.protocolClasses?.map { String(describing: $0) }
            ReleaseTestSupport.configure(configuration)
            XCTAssertEqual(configuration.protocolClasses?.map { String(describing: $0) }, previousProtocols)
        }
    }

    func testGeneratedPackLoadsWithExpectedGridAndChains() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ReleaseTestSupport.makePack(at: folder, title: "Fixture Parser Check")
        let pack = UniPackFolder(rootFolder: folder)
        pack.load()
        pack.loadDetail()
        XCTAssertFalse(pack.criticalError, pack.errorDetail ?? "")
        XCTAssertNil(pack.errorDetail)
        XCTAssertEqual(pack.title, "Fixture Parser Check")
        XCTAssertEqual(pack.buttonX, 8)
        XCTAssertEqual(pack.buttonY, 8)
        XCTAssertEqual(pack.chain, 2)
        XCTAssertTrue(pack.detailLoaded)
        XCTAssertEqual(pack.soundCount, 3)
    }

    func testPreparationAndDownloadKeepUserLibraryUntouched() async throws {
        let defaults = UserDefaults.standard
        let keys = ["UniPadReleaseTest", "UniPadReleaseEmpty", "UniPadReleaseFile", "UniPadReleaseRepeat"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        defaults.set(UUID().uuidString, forKey: keys[0])
        keys.dropFirst().forEach { defaults.set(false, forKey: $0) }
        let root = try XCTUnwrap(ReleaseTestSupport.root)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = WorkspaceManager.documentsDirectory.appendingPathComponent("UniPack")
        func contents() throws -> [String]? {
            guard FileManager.default.fileExists(atPath: library.path) else { return nil }
            return try FileManager.default.subpathsOfDirectory(atPath: library.path).sorted()
        }
        let before = try contents()
        try ReleaseTestSupport.prepare()
        let workspace = try XCTUnwrap(WorkspaceManager.currentWorkspaces().first)
        XCTAssertEqual(workspace.url, root.appendingPathComponent("UniPack"))
        XCTAssertEqual(Set(WorkspaceManager.unipackFolders(in: workspace).map(\.lastPathComponent)),
                       Set(["Release", "PlaybackStop", "Faded"]))
        let store = ReleaseStore()
        let count = try await store.fetchStoreItemCount()
        XCTAssertEqual(count, 40)
        let items = try await store.fetchStoreItems()
        XCTAssertEqual(items.count, 40)
        let configuration = URLSessionConfiguration.ephemeral
        ReleaseTestSupport.configure(configuration)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let recorder = FixtureDownloadRecorder()
        await UniPackDownloader(session: session).download(
            title: "Downloaded Fixture", url: items[0].downloadURL,
            workspace: workspace.url, folderName: "Downloaded", delegate: recorder)
        XCTAssertNil(recorder.error)
        let installed = try XCTUnwrap(recorder.folder)
        XCTAssertTrue(installed.path.hasPrefix(workspace.url.path + "/"))
        let pack = UniPackFolder(rootFolder: installed)
        pack.load()
        XCTAssertEqual(pack.title, "Downloaded Fixture")
        XCTAssertFalse(pack.criticalError)
        do {
            _ = try await session.data(from: URL(string: "https://unexpected.invalid/must-not-leave-test")!)
            XCTFail("unexpected request escaped the fixture protocol")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .unsupportedURL)
        }
        XCTAssertEqual(try contents(), before)
    }
}

@MainActor
private final class FixtureDownloadRecorder: UniPackDownloader.Delegate, @unchecked Sendable {
    var folder: URL?
    var error: Error?
    func onInstallStart() {}
    func onGetFileSize(fileSize: Int64, contentLength: Int64, preKnownFileSize: Int64) {}
    func onDownloadProgress(percent: Int, downloadedSize: Int64, fileSize: Int64) {}
    func onImportStart() {}
    func onInstallComplete(folder: URL) { self.folder = folder }
    func onError(_ error: Error) { self.error = error }
}
#endif
