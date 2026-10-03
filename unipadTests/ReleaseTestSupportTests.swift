import Foundation
import XCTest
@testable import unipad

@MainActor
final class ReleaseTestSupportTests: XCTestCase {
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
