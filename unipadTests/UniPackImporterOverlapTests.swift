import CryptoKit
import Foundation
import Testing
@testable import unipad

/// A file import that overlaps another install of the same name (a store or code download, or a
/// second import) keeps its own folder, and a failed import deletes only the folder it created.
@MainActor
struct UniPackImporterOverlapTests {
    private let root: URL
    private let workspace: URL
    private let sources: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "UniPackImporterOverlapTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        workspace = root.appending(path: "packs", directoryHint: .isDirectory)
        sources = root.appending(path: "sources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func packFiles(title: String) -> [(name: String, data: Data)] {
        [
            ("info", Data("title=\(title)\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\n".utf8)),
            ("keySound", Data("1 1 1 a.wav\n".utf8)),
            ("sounds/a.wav", Data(String(repeating: title, count: 512).utf8)),
        ]
    }

    private static func expectedHashes(title: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: packFiles(title: title).map { ($0.name, sha256($0.data)) })
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Relative path to SHA-256 of every file in `folder`.
    private func contentHashes(_ folder: String) throws -> [String: String] {
        let base = workspace.appending(path: folder, directoryHint: .isDirectory)
        guard let paths = FileManager.default.subpaths(atPath: base.path) else { return [:] }
        var hashes: [String: String] = [:]
        for path in paths {
            let url = base.appending(path: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            hashes[path] = Self.sha256(try Data(contentsOf: url))
        }
        return hashes
    }

    private func workspaceContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: workspace.path).sorted()
    }

    private func writePack(_ folder: URL, title: String) throws {
        for file in Self.packFiles(title: title) {
            let url = folder.appending(path: file.name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
    }

    /// Does what a download of the same name does once its transfer ends: claims the next free
    /// folder and extracts into it.
    private func installOther(title: String) throws -> URL {
        let folder = try FileManagerExtensions.claimNextPath(dir: workspace, name: "pack", extension: "", isDirectory: true)
        try writePack(folder, title: title)
        return folder
    }

    private func source(_ zip: Data) throws -> URL {
        let directory = sources.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "pack.zip")
        try zip.write(to: url)
        return url
    }

    private func importPack(_ zip: Data, _ delegate: RecordingImportDelegate) async throws {
        _ = try? await UniPackImporter().importPack(from: try source(zip), to: workspace, delegate: delegate)
    }

    private static let validZip = TestZip.stored(packFiles(title: "Imported"))
    private static let brokenZip = TestZip.stored(packFiles(title: "Imported"), corruptingSizeOf: "sounds/a.wav")

    @Test func importOverlappingAnotherInstallKeepsBothPacks() async throws {
        defer { cleanUp() }
        var other: URL?
        let delegate = RecordingImportDelegate { other = try? installOther(title: "Downloaded") }

        try await importPack(Self.validZip, delegate)

        #expect(delegate.error == nil)
        let otherFolder = try #require(other).lastPathComponent
        let importedFolder = try #require(delegate.completedFolder).lastPathComponent
        #expect(otherFolder != importedFolder)
        #expect(try workspaceContents() == ["pack", "pack (2)"])
        #expect(try contentHashes(otherFolder) == Self.expectedHashes(title: "Downloaded"))
        #expect(try contentHashes(importedFolder) == Self.expectedHashes(title: "Imported"))
    }

    @Test func failingImportKeepsTheOverlappingPack() async throws {
        defer { cleanUp() }
        var other: URL?
        let delegate = RecordingImportDelegate { other = try? installOther(title: "Downloaded") }

        try await importPack(Self.brokenZip, delegate)

        #expect(delegate.error != nil)
        let otherFolder = try #require(other).lastPathComponent
        #expect(try workspaceContents() == [otherFolder])
        #expect(try contentHashes(otherFolder) == Self.expectedHashes(title: "Downloaded"))
    }

    @Test func failingImportKeepsTheExistingPackAndRetryInstallsNextToIt() async throws {
        defer { cleanUp() }
        try writePack(workspace.appending(path: "pack", directoryHint: .isDirectory), title: "Existing")

        let failed = RecordingImportDelegate()
        try await importPack(Self.brokenZip, failed)
        #expect(failed.error != nil)
        #expect(try workspaceContents() == ["pack"])

        let retried = RecordingImportDelegate()
        try await importPack(Self.validZip, retried)

        #expect(retried.error == nil)
        #expect(retried.completedFolder?.lastPathComponent == "pack (2)")
        #expect(try contentHashes("pack") == Self.expectedHashes(title: "Existing"))
        #expect(try contentHashes("pack (2)") == Self.expectedHashes(title: "Imported"))
    }

    @Test func retryAfterFailedImportInstallsUnderTheOriginalName() async throws {
        defer { cleanUp() }
        let failed = RecordingImportDelegate()
        try await importPack(Self.brokenZip, failed)
        #expect(failed.error != nil)
        #expect(try workspaceContents().isEmpty)

        let retried = RecordingImportDelegate()
        try await importPack(Self.validZip, retried)

        #expect(retried.completedFolder?.lastPathComponent == "pack")
        #expect(try contentHashes("pack") == Self.expectedHashes(title: "Imported"))
    }
}

@MainActor
private final class RecordingImportDelegate: UniPackImporter.Delegate, @unchecked Sendable {
    private let onStart: () -> Void
    var completedFolder: URL?
    var error: Error?

    /// `onStart` runs when the importer reports its start, before it writes anything.
    init(onStart: @escaping () -> Void = {}) {
        self.onStart = onStart
    }

    func onImportStart() { onStart() }
    func onImportComplete(folder: URL) { completedFolder = folder }
    func onImportError(_ error: Error) { self.error = error }
}
