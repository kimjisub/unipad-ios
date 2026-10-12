import Foundation
import Testing
@testable import unipad

/// A pack opened from another app or picked in Files is saved in a folder named after its file.
/// The library is shown in the Files app, where a folder under a random name could not be told
/// apart from the others. Both entry points pass the file's name, `url.lastPathComponent`.
@MainActor
@Suite(.serialized)
struct UniPackImportFolderNameTests {
    private let root: URL
    private let workspace: URL
    private let stagingRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "UniPackImportFolderName-\(UUID().uuidString)", directoryHint: .isDirectory)
        workspace = root.appending(path: "packs", directoryHint: .isDirectory)
        stagingRoot = root.appending(path: "staging", directoryHint: .isDirectory)
        for folder in [workspace, stagingRoot] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func importPack(fileName: String, title: String = "Imported") async throws -> URL {
        let zip = TestZip.stored(WriteFailureLibrary.packFiles(title: title, soundCount: 2, soundSize: 1024))
        return try await UniPackImporter(stagingRoot: stagingRoot)
            .importPack(data: zip, fileName: fileName, to: workspace, delegate: nil)
    }

    private func title(of folder: URL) -> String {
        UniPackFolder(rootFolder: folder).load().title
    }

    /// Every item under `root`, so a write outside the library shows up too.
    private func everything() -> Set<String> {
        Set(FileManager.default.subpaths(atPath: root.path) ?? [])
    }

    @Test(arguments: [
        ("My Pack.zip", "My Pack"),
        ("My Pack.ZIP", "My Pack"),
        ("Ünïcode 팩 v1.2.zip", "Ünïcode 팩 v1.2"),
    ])
    func importedPackIsNamedAfterItsFile(fileName: String, expected: String) async throws {
        defer { cleanUp() }

        let folder = try await importPack(fileName: fileName)

        #expect(folder.lastPathComponent == expected)
        #expect(folder.deletingLastPathComponent().path == workspace.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.path) == [expected])
        #expect(title(of: folder) == "Imported")
    }

    @Test func aTakenNameGetsTheNextNumberAndKeepsTheFirstPack() async throws {
        defer { cleanUp() }

        let first = try await importPack(fileName: "My Pack.zip", title: "First")
        let second = try await importPack(fileName: "My Pack.zip", title: "Second")

        #expect(first.lastPathComponent == "My Pack")
        #expect(second.lastPathComponent == "My Pack (2)")
        #expect(title(of: first) == "First")
        #expect(title(of: second) == "Second")
    }

    @Test(arguments: [
        ("", UniPackImporter.fallbackFolderName),
        (".zip", UniPackImporter.fallbackFolderName),
        ("...zip", UniPackImporter.fallbackFolderName),
        ("..", UniPackImporter.fallbackFolderName),
        ("   .zip", UniPackImporter.fallbackFolderName),
        ("../../Outside.zip", "Outside"),
        ("a/b:c?.zip", "abc"),
        (".hidden.zip", "hidden"),
    ])
    func aNameThatCannotBeAFolderStillInstallsInsideTheLibrary(fileName: String, expected: String) async throws {
        defer { cleanUp() }
        let before = everything()

        let folder = try await importPack(fileName: fileName)

        #expect(folder.lastPathComponent == expected)
        #expect(folder.deletingLastPathComponent().path == workspace.path)
        let added = everything().subtracting(before)
        #expect(added.allSatisfy { $0 == "packs/\(expected)" || $0.hasPrefix("packs/\(expected)/") }, "wrote \(added)")
    }

    @Test func aLongNameLeavesRoomForTheNumber() async throws {
        defer { cleanUp() }
        let fileName = String(repeating: "가", count: 83) + ".zip"

        let first = try await importPack(fileName: fileName)
        let second = try await importPack(fileName: fileName)

        #expect(first.lastPathComponent == String(repeating: "가", count: 66))
        #expect(second.lastPathComponent == String(repeating: "가", count: 66) + " (2)")
    }
}
