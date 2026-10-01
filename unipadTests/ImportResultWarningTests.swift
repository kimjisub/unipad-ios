import Foundation
import Testing
@testable import unipad

@MainActor
struct ImportResultWarningTests {
    private let workspace: URL
    private let vm = MainViewModel()

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "ImportResultWarningTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: workspace)
    }

    private static let info = "title=Test\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\n"
    private static let keySound = "1 1 1 a.wav\n1 1 2 b.wav\n"

    private func packFiles(soundFiles: [String]) -> [(name: String, data: Data)] {
        [("info", Data(Self.info.utf8)), ("keySound", Data(Self.keySound.utf8))]
            + soundFiles.map { ("sounds/\($0)", Data()) }
    }

    private func makePack(_ name: String, soundFiles: [String]) throws -> URL {
        let folder = workspace.appending(path: name, directoryHint: .isDirectory)
        for file in packFiles(soundFiles: soundFiles) {
            let url = folder.appending(path: file.name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
        return folder
    }

    private func makeZip(_ name: String, files: [(name: String, data: Data)], corruptingSizeOf corrupted: String? = nil) throws -> URL {
        let url = workspace.appending(path: name)
        try TestZip.stored(files, corruptingSizeOf: corrupted).write(to: url)
        return url
    }

    private func makePacksFolder() throws -> URL {
        let packs = workspace.appending(path: "packs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        return packs
    }

    /// Runs the same path as picking a ZIP on the main screen: importer, completion callback, view model.
    private func importThroughViewModel(_ zip: URL, into packs: URL) async -> URL? {
        vm.packFolderSource = {
            (try? FileManager.default.contentsOfDirectory(at: packs, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        let folder = try? await UniPackImporter().importPack(from: zip, to: packs, delegate: MainViewImportDelegate(viewModel: vm))
        await vm.completeImport(importedFolder: folder)
        return folder
    }

    @Test func completePackShowsSuccess() async throws {
        defer { cleanUp() }
        let folder = try makePack("Complete", soundFiles: ["a.wav", "b.wav"])

        await vm.showImportResult(forImportedFolder: folder)

        guard case .success(let pack) = vm.importResult else {
            Issue.record("expected success, got \(String(describing: vm.importResult))")
            return
        }
        #expect(pack.soundCount == 2)
    }

    @Test func missingSoundFileShowsWarning() async throws {
        defer { cleanUp() }
        let folder = try makePack("MissingSound", soundFiles: ["a.wav"])

        await vm.showImportResult(forImportedFolder: folder)

        guard case .warning(let message) = vm.importResult else {
            Issue.record("expected warning, got \(String(describing: vm.importResult))")
            return
        }
        #expect(message.contains("[1 1 2 b.wav] sound was not found"))
        #expect(FileManager.default.fileExists(atPath: folder.path), "a pack with soft errors is kept")
    }

    @Test func brokenZipFailsAndKeepsTheSourceFile() async throws {
        defer { cleanUp() }
        let source = workspace.appending(path: "Broken.zip")
        try Data("not a zip".utf8).write(to: source)
        let packs = try makePacksFolder()
        let delegate = RecordingDelegate()

        await #expect(throws: UniPackImporter.ImportError.self) {
            try await UniPackImporter().importPack(from: source, to: packs, delegate: delegate)
        }

        #expect(delegate.completed == nil)
        #expect(delegate.error != nil)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: packs.path).isEmpty)
    }

    @Test func importedCompleteZipShowsSuccess() async throws {
        defer { cleanUp() }
        let zip = try makeZip("Complete.zip", files: packFiles(soundFiles: ["a.wav", "b.wav"]))
        let original = try Data(contentsOf: zip)
        let packs = try makePacksFolder()

        let folder = await importThroughViewModel(zip, into: packs)

        guard case .success(let pack) = vm.importResult else {
            Issue.record("expected success, got \(String(describing: vm.importResult))")
            return
        }
        #expect(pack.soundCount == 2)
        #expect(folder.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(try Data(contentsOf: zip) == original)
    }

    @Test func importedZipMissingASoundShowsWarningAndKeepsThePack() async throws {
        defer { cleanUp() }
        let zip = try makeZip("MissingSound.zip", files: packFiles(soundFiles: ["a.wav"]))
        let original = try Data(contentsOf: zip)
        let packs = try makePacksFolder()

        let folder = await importThroughViewModel(zip, into: packs)

        guard case .warning(let message) = vm.importResult else {
            Issue.record("expected warning, got \(String(describing: vm.importResult))")
            return
        }
        #expect(message.contains("[1 1 2 b.wav] sound was not found"))
        #expect(folder.map { FileManager.default.fileExists(atPath: $0.appending(path: "info").path) } == true)
        #expect(try Data(contentsOf: zip) == original)
    }

    @Test func zipFailingMidExtractionShowsErrorAndRemovesThePartialFolder() async throws {
        defer { cleanUp() }
        let zip = try makeZip(
            "Truncated.zip",
            files: packFiles(soundFiles: ["a.wav", "b.wav"]),
            corruptingSizeOf: "sounds/b.wav"
        )
        let original = try Data(contentsOf: zip)
        let packs = try makePacksFolder()

        let folder = await importThroughViewModel(zip, into: packs)

        #expect(folder == nil)
        guard case .error(let message) = vm.importResult else {
            Issue.record("expected error, got \(String(describing: vm.importResult))")
            return
        }
        #expect(message.contains("sounds/b.wav"), "extraction got past the earlier entries before failing")
        #expect(try FileManager.default.contentsOfDirectory(atPath: packs.path).isEmpty)
        #expect(try Data(contentsOf: zip) == original)
    }
}

@MainActor
private final class RecordingDelegate: UniPackImporter.Delegate {
    var completed: URL?
    var error: Error?

    func onImportStart() {}
    func onImportComplete(folder: URL) { completed = folder }
    func onImportError(_ error: Error) { self.error = error }
}
