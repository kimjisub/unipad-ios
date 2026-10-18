import Foundation
import Testing
@testable import unipad

/// A ZIP opens as the one folder in it that holds an `info` file: wrapper folders are taken off, and
/// Finder's `__MACOSX`, dot files and other files or folders left beside the pack are ignored.
@MainActor
struct UniPackArchiveLayoutTests {
    private let root: URL
    private let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "UniPackArchiveLayoutTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        workspace = root.appending(path: "packs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func pack(in folder: String, title: String = "Archived") -> [(name: String, data: Data)] {
        [
            ("\(folder)info", Data("title=\(title)\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\n".utf8)),
            ("\(folder)keySound", Data("1 1 1 a.wav\n".utf8)),
            ("\(folder)sounds/a.wav", Data("sound".utf8)),
        ]
    }

    private static let readme = (name: "readme.txt", data: Data("Thanks for downloading".utf8))

    /// Imports `files` as one ZIP and returns the installed folder, or the import error.
    private func importArchive(_ files: [(name: String, data: Data)]) async throws -> Result<URL, Error> {
        let source = root.appending(path: "pack.zip")
        try TestZip.stored(files).write(to: source)
        let delegate = RecordingImportDelegate()
        _ = try? await UniPackImporter().importPack(from: source, to: workspace, delegate: delegate)
        if let error = delegate.error { return .failure(error) }
        return .success(try #require(delegate.completedFolder))
    }

    private func expectInstalledPack(_ result: Result<URL, Error>, title: String = "Archived") throws {
        let folder = try result.get()
        #expect(try String(contentsOf: folder.appending(path: "info"), encoding: .utf8).hasPrefix("title=\(title)\n"))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "keySound").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "sounds/a.wav").path))
    }

    @Test func aFileBesideThePackFolderIsIgnored() async throws {
        defer { cleanUp() }
        try expectInstalledPack(try await importArchive(Self.pack(in: "Pack/") + [Self.readme]))
    }

    @Test func filesBesideEveryWrapperAreIgnored() async throws {
        defer { cleanUp() }
        let files = Self.pack(in: "Wrap/Pack/") + [Self.readme, ("Wrap/notes.txt", Data("notes".utf8))]
        try expectInstalledPack(try await importArchive(files))
    }

    @Test func aFolderWithoutInfoBesideThePackIsIgnored() async throws {
        defer { cleanUp() }
        let files = Self.pack(in: "Pack/") + [Self.readme, ("Extras/manual.txt", Data("manual".utf8))]
        try expectInstalledPack(try await importArchive(files))
    }

    @Test func finderMetadataBesideThePackIsIgnored() async throws {
        defer { cleanUp() }
        let files = Self.pack(in: "Pack/") + [("__MACOSX/Pack/._info", Data("meta".utf8)), (".DS_Store", Data("ds".utf8))]
        try expectInstalledPack(try await importArchive(files))
    }

    @Test func aPackAtTheTopKeepsItsOwnFolders() async throws {
        defer { cleanUp() }
        try expectInstalledPack(try await importArchive(Self.pack(in: "") + [Self.readme]))
    }

    /// Two packs in one archive: nothing says which one the author meant, so the import still fails.
    @Test func twoPacksInOneArchiveAreNotGuessed() async throws {
        defer { cleanUp() }
        let result = try await importArchive(Self.pack(in: "First/", title: "First") + Self.pack(in: "Second/", title: "Second"))
        guard case .failure = result else {
            Issue.record("an archive with two packs was installed as one")
            return
        }
    }
}
