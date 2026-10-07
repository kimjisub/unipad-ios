import Foundation
import Testing
@testable import unipad

/// The app can be killed at any moment of an import. Whatever the library lists at that moment is
/// what the user finds on the next launch, so it must only ever list finished packs.
@MainActor
struct UniPackInterruptedInstallTests {
    private let root: URL
    private let workspace: URL
    private let stagingRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "UniPackInterruptedInstallTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        workspace = root.appending(path: "packs", directoryHint: .isDirectory)
        stagingRoot = root.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    private func stagingContents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Enough sounds that unpacking takes far longer than noticing a new folder in the library.
    private static let packFiles: [(name: String, data: Data)] = {
        let sounds = (0..<300).map { ("sounds/\($0).wav", Data(repeating: UInt8($0 % 251), count: 32 * 1024)) }
        let keySound = (0..<300).map { "1 \($0 / 64 + 1) \($0 % 64 / 8 + 1) \($0).wav" }.joined(separator: "\n")
        return [
            ("info", Data("title=Big\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=5\n".utf8)),
            ("keySound", Data(keySound.utf8)),
        ] + sounds
    }()

    private func source(_ zip: Data) throws -> URL {
        let url = root.appending(path: "pack.zip")
        try zip.write(to: url)
        return url
    }

    @Test func libraryNeverListsAPackThatIsStillBeingImported() async throws {
        defer { cleanUp() }
        let expected = Set(Self.packFiles.map(\.name))
        let watcher = try LibraryWatcher(workspace: workspace) { folder in
            Set(FileManager.default.subpaths(atPath: folder.path) ?? []).isSuperset(of: expected)
        }

        let imported = try await UniPackImporter(stagingRoot: stagingRoot)
            .importPack(from: try source(TestZip.stored(Self.packFiles)), to: workspace, delegate: nil)
        let sawPublishedPack = await watcher.waitUntilFinishedSeen(imported.lastPathComponent)
        watcher.stop()

        #expect(sawPublishedPack, "the watcher never looked at the library after the pack was added, so it proves nothing")
        #expect(watcher.unfinishedSeen.isEmpty, "a kill at that moment leaves \(watcher.unfinishedSeen) in the library")
        #expect(WorkspaceManager.unipackFolders(in: .init(name: "test", url: workspace)).map(\.lastPathComponent) == [imported.lastPathComponent])
        #expect(stagingContents().isEmpty)
    }

    @Test func failedImportLeavesNothingInTheLibraryOrStaging() async throws {
        defer { cleanUp() }
        let broken = TestZip.stored(Self.packFiles, corruptingSizeOf: "sounds/299.wav")

        await #expect(throws: (any Error).self) {
            try await UniPackImporter(stagingRoot: stagingRoot).importPack(from: try source(broken), to: workspace, delegate: nil)
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.path).isEmpty)
        #expect(stagingContents().isEmpty)
    }

    @Test func leftoversOfAKilledInstallAreRemovedAtLaunchAndNothingElse() async throws {
        defer { cleanUp() }
        let fm = FileManager.default
        // What a kill mid-unpack leaves: a staging folder that is never published or discarded.
        let killed = try UniPackStaging(root: stagingRoot)
        try Data("title=Half\n".utf8).write(to: killed.packFolder.appending(path: "info"))
        try Data(repeating: 1, count: 1024).write(to: killed.file(named: "download.zip"))
        let installed = workspace.appending(path: "pack", directoryHint: .isDirectory)
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("title=Installed\n".utf8).write(to: installed.appending(path: "info"))

        let cleanup = UniPackStaging.removeLeftovers(in: stagingRoot)
        let startedAfterLaunch = try UniPackStaging(root: stagingRoot)
        await cleanup.value

        #expect(stagingContents() == [startedAfterLaunch.directory.lastPathComponent])
        #expect(try fm.contentsOfDirectory(atPath: workspace.path) == ["pack"])
        #expect(try Data(contentsOf: installed.appending(path: "info")) == Data("title=Installed\n".utf8))
    }

    @Test func unwrappingANestedFolderReportsAFailedMove() throws {
        defer { cleanUp() }
        let fm = FileManager.default
        let pack = workspace.appending(path: "pack", directoryHint: .isDirectory)
        let inner = pack.appending(path: "Wrapped", directoryHint: .isDirectory)
        let sounds = inner.appending(path: "sounds", directoryHint: .isDirectory)
        try fm.createDirectory(at: sounds, withIntermediateDirectories: true)
        try Data("title=Wrapped\n".utf8).write(to: inner.appending(path: "info"))
        try Data("1 1 1 a.wav\n".utf8).write(to: inner.appending(path: "keySound"))
        try Data("sound".utf8).write(to: sounds.appending(path: "a.wav"))
        // A directory without write permission cannot be moved to another parent.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sounds.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sounds.path) }

        #expect(throws: (any Error).self, "the pack is left without its sounds and the import still succeeds") {
            try FileManagerExtensions.removeDoubleFolder(at: pack)
        }
    }
}

/// Every time an entry is added to or removed from the workspace, checks each folder the library
/// would list and records which of them are finished packs and which are not.
private final class LibraryWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let lock = NSLock()
    private var unfinished: [String] = []
    private var finished: Set<String> = []

    var unfinishedSeen: [String] { lock.withLock { unfinished } }

    /// Change notifications arrive after the change, so the import can return before the watcher
    /// has looked at the pack it added.
    func waitUntilFinishedSeen(_ name: String, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if lock.withLock({ finished.contains(name) }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    init(workspace: URL, isFinished: @escaping @Sendable (URL) -> Bool) throws {
        let descriptor = open(workspace.path, O_EVTONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: DispatchQueue(label: "LibraryWatcher")
        )
        source.setEventHandler { [lock, weak self] in
            let checked = WorkspaceManager.unipackFolders(in: .init(name: "test", url: workspace))
                .map { ($0.lastPathComponent, isFinished($0)) }
            lock.withLock {
                self?.finished.formUnion(checked.filter(\.1).map(\.0))
                self?.unfinished.append(contentsOf: checked.filter { !$0.1 }.map(\.0))
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    func stop() {
        source.cancel()
    }
}
