#if DEBUG || UNIPAD_RELEASE_TESTS
import AVFoundation
import Foundation
import XCTest
@testable import unipad

@MainActor
final class ReleaseTestSupportTests: XCTestCase {
    func testPickerPreparationRemovesOnlyOldGeneratedArchivesAndDoesNotAccumulate() throws {
        let defaults = UserDefaults.standard
        let keys = ["UniPadReleaseTest", "UniPadReleaseEmpty", "UniPadReleaseFile"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        let fm = FileManager.default
        let documents = WorkspaceManager.documentsDirectory
        let oldArchives = (0..<3).map { _ in
            documents.appendingPathComponent("ReleaseFixture-\(UUID().uuidString).zip")
        }
        let userFolder = documents.appendingPathComponent("UniPack/\(UUID().uuidString)")
        let preserved = [
            documents.appendingPathComponent("ReleaseFixture-user-\(UUID().uuidString).zip"),
            userFolder.appendingPathComponent("ReleaseFixture-\(UUID().uuidString).zip"),
        ]
        let directory = documents.appendingPathComponent("ReleaseFixture-\(UUID().uuidString).zip")
        let symbolicLink = documents.appendingPathComponent("ReleaseFixture-\(UUID().uuidString).zip")
        try fm.createDirectory(at: userFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in oldArchives + preserved { try Data("keep".utf8).write(to: url) }
        try fm.createSymbolicLink(at: symbolicLink, withDestinationURL: preserved[0])
        var roots: [URL] = []
        var currentArchives: [URL] = []
        defer {
            for url in oldArchives + preserved + roots + currentArchives + [symbolicLink, userFolder, directory] {
                try? fm.removeItem(at: url)
            }
        }
        defaults.set(true, forKey: "UniPadReleaseEmpty")
        defaults.set(true, forKey: "UniPadReleaseFile")
        for _ in 0..<2 {
            let token = UUID().uuidString
            defaults.set(token, forKey: "UniPadReleaseTest")
            roots.append(try XCTUnwrap(ReleaseTestSupport.root))
            let current = documents.appendingPathComponent("ReleaseFixture-\(token).zip")
            currentArchives.append(current)
            try ReleaseTestSupport.prepare()
            let firstContents = try Data(contentsOf: current)
            try ReleaseTestSupport.prepare() // Relaunching the same test keeps its picker file.
            XCTAssertEqual(try Data(contentsOf: current), firstContents)
            for url in oldArchives + currentArchives.dropLast() {
                XCTAssertFalse(fm.fileExists(atPath: url.path), url.lastPathComponent)
            }
            for url in preserved { XCTAssertEqual(try Data(contentsOf: url), Data("keep".utf8)) }
            XCTAssertTrue(fm.fileExists(atPath: directory.path))
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: symbolicLink.path), preserved[0].path)
        }
    }

    func testPreparationWithoutPickerArgumentsDoesNotDeleteFiles() throws {
        let defaults = UserDefaults.standard
        let keys = ["UniPadReleaseTest", "UniPadReleaseEmpty", "UniPadReleaseFile"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        let fm = FileManager.default
        let archive = WorkspaceManager.documentsDirectory
            .appendingPathComponent("ReleaseFixture-\(UUID().uuidString).zip")
        try Data("keep".utf8).write(to: archive)
        defer { try? fm.removeItem(at: archive) }
        defaults.set(true, forKey: "UniPadReleaseEmpty")
        for token in [nil, "", "not-a-uuid", UUID().uuidString] as [String?] {
            defaults.set(token, forKey: "UniPadReleaseTest")
            let root = ReleaseTestSupport.root
            defer { if let root { try? fm.removeItem(at: root) } }
            for fileEnabled in [false, true] {
                if root != nil && fileEnabled { continue }
                defaults.set(fileEnabled, forKey: "UniPadReleaseFile")
                try ReleaseTestSupport.prepare()
                XCTAssertEqual(try Data(contentsOf: archive), Data("keep".utf8))
            }
        }
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

    func testThemeLoadingFixtureIsOptInAndOnlyEnlargesFaded() throws {
        let defaults = UserDefaults.standard
        let keys = ["UniPadReleaseTest", "UniPadReleaseEmpty", "UniPadReleaseThemeLoading"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        defaults.set(false, forKey: "UniPadReleaseEmpty")
        for enabled in [false, true] {
            defaults.set(UUID().uuidString, forKey: "UniPadReleaseTest")
            defaults.set(enabled, forKey: "UniPadReleaseThemeLoading")
            let root = try XCTUnwrap(ReleaseTestSupport.root)
            defer { try? FileManager.default.removeItem(at: root) }
            try ReleaseTestSupport.prepare()
            for folder in ["Release", "Faded"] {
                let path = root.appendingPathComponent("UniPack/\(folder)")
                let pack = UniPackFolder(rootFolder: path)
                pack.load()
                pack.loadDetail()
                XCTAssertFalse(pack.criticalError)
                XCTAssertNil(pack.errorDetail)
                let events = try XCTUnwrap(pack.ledAnimationTable?[0][0][0]?.first).ledEvents
                XCTAssertEqual(events.count, enabled && folder == "Faded" ? 1_000_003 : 3)
                XCTAssertEqual(pack.soundCount, 3)
            }
            let playbackStop = UniPackFolder(rootFolder: root.appendingPathComponent("UniPack/PlaybackStop"))
            playbackStop.load()
            playbackStop.loadDetail()
            XCTAssertFalse(playbackStop.criticalError)
            XCTAssertNil(playbackStop.errorDetail)
        }
    }

    /// The chain layout checks open these packs by title and expect each grid size and chain count.
    func testChainLayoutPacksAreOptInWithUniqueTitlesAndExpectedShapes() throws {
        let defaults = UserDefaults.standard
        let keys = ["UniPadReleaseTest", "UniPadReleaseEmpty", "UniPadReleaseChainLayout"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        defaults.set(false, forKey: "UniPadReleaseEmpty")
        let shapes: [(folder: String, title: String, rows: Int, columns: Int, chains: Int, lights: Bool)] = [
            ("ChainLayout8x8", "Chain Layout 8x8", 8, 8, 6, true),
            ("ChainLayout4x3", "Chain Layout 4x3", 4, 3, 24, false),
        ]
        for enabled in [false, true] {
            defaults.set(UUID().uuidString, forKey: "UniPadReleaseTest")
            defaults.set(enabled, forKey: "UniPadReleaseChainLayout")
            let root = try XCTUnwrap(ReleaseTestSupport.root)
            defer { try? FileManager.default.removeItem(at: root) }
            try ReleaseTestSupport.prepare()
            let workspace = try XCTUnwrap(WorkspaceManager.currentWorkspaces().first)
            let folders = WorkspaceManager.unipackFolders(in: workspace)
            XCTAssertEqual(Set(folders.map(\.lastPathComponent)),
                           Set(["Release", "PlaybackStop", "Faded"] + (enabled ? shapes.map(\.folder) : [])))
            let titles = folders.map { folder -> String in
                let pack = UniPackFolder(rootFolder: folder)
                pack.load()
                return pack.title
            }
            XCTAssertEqual(Set(titles).count, titles.count, "\(titles)")
            guard enabled else { continue }
            for shape in shapes {
                let pack = UniPackFolder(rootFolder: workspace.url.appendingPathComponent(shape.folder))
                pack.load()
                pack.loadDetail()
                XCTAssertFalse(pack.criticalError, pack.errorDetail ?? "")
                XCTAssertNil(pack.errorDetail)
                XCTAssertEqual(pack.title, shape.title)
                XCTAssertEqual(pack.buttonX, shape.rows)
                XCTAssertEqual(pack.buttonY, shape.columns)
                XCTAssertEqual(pack.chain, shape.chains)
                XCTAssertTrue(pack.squareButton)
                XCTAssertEqual(pack.keyLedExist, shape.lights)
                XCTAssertEqual(pack.autoPlayExist, shape.lights)
            }
        }
    }

    /// Checks reach "Playback Stop Fixture" from the release suite's library or, outside it, from
    /// the shared library holding the repository fixture; both must be the same pack.
    func testReleasePlaybackStopPackMatchesRepositoryFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../unipadUITests/Fixtures/PlaybackStop").standardizedFileURL
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ReleaseTestSupport.makePlaybackStopPack(at: folder)
        func files(in root: URL) throws -> [String] {
            try FileManager.default.subpathsOfDirectory(atPath: root.path)
                .filter { !$0.hasPrefix(".") && !$0.contains("/.") }.sorted()
        }
        XCTAssertEqual(try files(in: folder), try files(in: fixture))
        for name in ReleaseTestSupport.playbackStopFiles.keys.sorted() {
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
                           try String(contentsOf: fixture.appendingPathComponent(name), encoding: .utf8), name)
        }
        let pack = UniPackFolder(rootFolder: folder)
        pack.load()
        pack.loadDetail()
        XCTAssertFalse(pack.criticalError, pack.errorDetail ?? "")
        XCTAssertNil(pack.errorDetail)
        XCTAssertEqual(pack.title, "Playback Stop Fixture")
        XCTAssertEqual(pack.chain, 1)

        // The generated sound is written as float samples and the fixture's as 16-bit integers,
        // so the files differ byte for byte; what playback depends on must still match.
        let generated = try AVAudioFile(forReading: folder.appendingPathComponent("sounds/a.wav"))
        let stored = try AVAudioFile(forReading: fixture.appendingPathComponent("sounds/a.wav"))
        XCTAssertEqual(generated.length, stored.length)
        XCTAssertEqual(generated.fileFormat.sampleRate, stored.fileFormat.sampleRate)
        XCTAssertEqual(generated.fileFormat.channelCount, stored.fileFormat.channelCount)
        // The exit checks tap the first pad and leave a few seconds later; they only cover leaving
        // during playback while that pad is still sounding.
        let firstPad = try XCTUnwrap(pack.soundTable?[0][0][0]?.first)
        let seconds = Double(firstPad.loop + 1) * Double(stored.length) / stored.fileFormat.sampleRate
        XCTAssertGreaterThan(seconds, 60)
    }

    func testPreparationAndDownloadKeepUserLibraryUntouched() async throws {
        let defaults = UserDefaults.standard
        let keys = ["UniPadReleaseTest", "UniPadReleaseEmpty", "UniPadReleaseFile", "UniPadReleaseRepeat", "UniPadReleaseThemeLoading"]
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
