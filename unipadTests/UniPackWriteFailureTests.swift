import CryptoKit
import Darwin
import Foundation
import ObjectiveC
import Testing
@testable import unipad

/// When writing a pack fails partway, as it does when the device runs out of space, the import or
/// download is reported as failed, its staging folder is deleted, and nothing else changes: the
/// source archive, the packs already in the library and the user's own folders stay byte for byte.
/// Once writing works again, the same pack installs under the usual name.
///
/// Each test makes writing fail at one point of the real importer or downloader. Folder writes are
/// refused with an access rule that, like a full disk, still lets files be deleted, so the cleanup
/// that follows the failure runs as it would on a device.
@MainActor
@Suite(.serialized)
struct UniPackWriteFailureTests {
    private let library: WriteFailureLibrary
    private let session: URLSession
    private let host = "stub-\(UUID().uuidString.lowercased()).test"

    init() throws {
        library = try WriteFailureLibrary(in: FileManager.default.temporaryDirectory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    private func cleanUp() {
        StubURLProtocol.remove(host: host)
        session.invalidateAndCancel()
        library.cleanUp()
    }

    private static let zip = TestZip.stored(WriteFailureLibrary.packFiles(title: "Imported"))

    // MARK: - Opened from another app or picked in Files

    @Test func failedWriteOfTheArchiveCopyChangesNothing() async throws {
        defer { cleanUp() }
        let source = try library.source(Self.zip)
        let before = library.workspaceSnapshot()
        // The archive is written into a staging folder created by the same call, so the rule is
        // set on the staging root and applies to the folder created inside it.
        try NewFileBlock.set(on: library.stagingRoot, inFoldersCreatedInside: true)

        let recorder = ImportRecorder()
        let failure = await library.importData(try Data(contentsOf: source), recorder)

        let error = try #require(failure.error)
        #expect((error as? CocoaError)?.code == .fileWriteNoPermission)
        let failedPath = try #require((error as NSError).userInfo[NSFilePathErrorKey] as? String)
        #expect(URL(fileURLWithPath: failedPath).pathExtension == "zip", "failed at \(failedPath), not at the archive copy")
        #expect(recorder.started == 0, "the copy is written before the import itself starts")
        #expect(recorder.error != nil)
        library.expectNothingChanged(since: before, source: source, archive: Self.zip)

        try NewFileBlock.clear(on: library.stagingRoot)
        try await library.expectImportRetryInstalls(Self.zip, since: before)
    }

    @Test func failedSecondCopyOfTheArchiveChangesNothing() async throws {
        defer { cleanUp() }
        let source = try library.source(Self.zip)
        let before = library.workspaceSnapshot()
        let observer = StagingCopyObserver(root: library.stagingRoot) { destination in
            try NewFileBlock.set(on: destination.deletingLastPathComponent())
        }
        var stagingAtFailure: [String: String] = [:]
        let recorder = ImportRecorder { _ in stagingAtFailure = library.stagingSnapshot() }

        let data = try Data(contentsOf: source)
        let failure = await observer.whileObserving { await library.importData(data, recorder) }

        let error = try #require(failure.error)
        #expect((error as? CocoaError)?.code == .fileWriteNoPermission)
        let copy = try #require(observer.copies.first)
        #expect(observer.copies.count == 1)
        #expect(observer.errors.isEmpty)
        #expect(stagingAtFailure[library.relativeToStaging(copy)] == nil, "the second copy was written")
        // The first copy was complete, so the failure was on the second one.
        #expect(stagingAtFailure.values.contains(WriteFailureLibrary.sha256(Self.zip)))
        #expect(recorder.started == 1)
        #expect(recorder.error != nil)
        library.expectNothingChanged(since: before, source: source, archive: Self.zip)

        try await library.expectImportRetryInstalls(Self.zip, since: before)
    }

    @Test func failedWriteWhileUnpackingChangesNothing() async throws {
        defer { cleanUp() }
        let source = try library.source(Self.zip)
        let before = library.workspaceSnapshot()

        try await expectUnpackingFails(source: source, since: before)

        try await library.expectImportRetryInstalls(Self.zip, since: before)
    }

    @Test func failedSecondImportKeepsTheFirstOne() async throws {
        defer { cleanUp() }
        let first = try #require(await library.importData(TestZip.stored(WriteFailureLibrary.packFiles(title: "First")), ImportRecorder()).folder)
        let source = try library.source(Self.zip)
        let before = library.workspaceSnapshot()
        #expect(before.keys.contains(first.lastPathComponent))

        try await expectUnpackingFails(source: source, since: before)

        let retried = try await library.expectImportRetryInstalls(Self.zip, since: before)
        #expect(retried != first)
        #expect(library.snapshot(of: first) == WriteFailureLibrary.expectedSnapshot(title: "First"))
    }

    /// Imports `source` with new files refused in the last folder of the archive (`keyLED`), which
    /// is created in the staging folder before unpacking starts, so the files before it are written
    /// and the first file in it fails.
    private func expectUnpackingFails(source: URL, since before: [String: String]) async throws {
        let observer = StagingCopyObserver(root: library.stagingRoot) { archive in
            let lastFolder = archive.deletingLastPathComponent().appending(path: "pack/keyLED", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: lastFolder, withIntermediateDirectories: false)
            try NewFileBlock.set(on: lastFolder)
        }
        var unpackedAtFailure: [String: String] = [:]
        let recorder = ImportRecorder { _ in
            unpackedAtFailure = observer.copies.first.map { library.snapshot(of: $0.deletingLastPathComponent().appending(path: "pack")) } ?? [:]
        }

        let data = try Data(contentsOf: source)
        let failure = await observer.whileObserving { await library.importData(data, recorder) }

        let error = try #require(failure.error)
        #expect((error as? CocoaError)?.code == .fileWriteNoPermission)
        #expect(((error as NSError).userInfo[NSFilePathErrorKey] as? String)?.hasSuffix("keyLED/1 1 1 1") == true)
        #expect(observer.errors.isEmpty)
        var written = WriteFailureLibrary.expectedSnapshot(title: "Imported")
        written["keyLED/1 1 1 1"] = nil
        #expect(unpackedAtFailure == written, "unpacking did not write every file before the failing one")
        #expect(recorder.error != nil)
        library.expectNothingChanged(since: before, source: source, archive: Self.zip)
    }

    // MARK: - Store download

    @Test func failedWriteWhileDownloadingChangesNothing() async throws {
        defer { cleanUp() }
        let body = TestZip.stored(WriteFailureLibrary.packFiles(title: "Downloaded"))
        let received = 64 * 1024
        StubURLProtocol.register(host: host, .init(
            status: 200, chunks: [body.prefix(received)], contentLength: body.count, stallsAfterChunks: true
        ))
        let before = library.workspaceSnapshot()
        var archiveSizeAtFailure: Int?
        let recorder = DownloadRecorder { _ in
            let archive = library.stagingFolders().first?.appending(path: "download.zip")
            archiveSizeAtFailure = archive.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
        }

        let download = Task { await library.download(from: host, session: session, recorder) }
        let deadline = ContinuousClock.now + .seconds(10)
        while !StubURLProtocol.isStalled(host: host) || recorder.percents.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let staging = try #require(library.stagingFolders().first, "the download never started")
        #expect(try failWrites(to: staging.appending(path: "download.zip")) == 1)
        StubURLProtocol.release(host: host, .finish([body.dropFirst(received)]))
        await download.value

        let error = try #require(recorder.error)
        #expect(!(error is URLError) && !error.isUsageCancellation, "the transfer failed, not the write: \(error)")
        #expect(archiveSizeAtFailure == received, "the write failed after \(String(describing: archiveSizeAtFailure)) bytes")
        #expect(recorder.percents.last.map { $0 > 0 && $0 < 100 } == true)
        #expect(!recorder.importStarted)
        library.expectNothingChanged(since: before)

        StubURLProtocol.register(host: host, .init(status: 200, chunks: [body], contentLength: body.count))
        let retried = DownloadRecorder()
        await library.download(from: host, session: session, retried)
        #expect(retried.error == nil)
        #expect(retried.installedFolder?.lastPathComponent == "pack (2)")
        #expect(library.snapshot(of: library.workspace.appending(path: "pack (2)")) == WriteFailureLibrary.expectedSnapshot(title: "Downloaded"))
        #expect(library.workspaceSnapshot().filter { !$0.key.hasPrefix("pack (2)") } == before)
        #expect(library.stagingFolders().isEmpty)
    }

    /// Makes the next write through every descriptor this process holds open for writing `file`
    /// fail, by putting a read-only descriptor of the same file in its place. The downloader keeps
    /// the archive open while the body arrives, so the next chunk it receives fails to be written.
    private func failWrites(to file: URL) throws -> Int {
        var target = stat()
        guard stat(file.path, &target) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let readOnly = open(file.path, O_RDONLY)
        guard readOnly >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(readOnly) }
        var replaced = 0
        for descriptor in 0..<getdtablesize() where descriptor != readOnly {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_dev == target.st_dev, info.st_ino == target.st_ino,
                  fcntl(descriptor, F_GETFL) & O_ACCMODE != O_RDONLY else { continue }
            guard dup2(readOnly, descriptor) == descriptor else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            replaced += 1
        }
        return replaced
    }
}

// MARK: - Library under test

/// A workspace holding a pack named `pack` and two folders of the user's (a hidden one with a file
/// and an empty one), a staging root, and a folder of source archives, all under one folder in `base`.
@MainActor
struct WriteFailureLibrary {
    let root: URL
    let workspace: URL
    let stagingRoot: URL
    let sources: URL

    init(in base: URL) throws {
        let fm = FileManager.default
        root = base.appending(path: "UniPackWriteFailure-\(UUID().uuidString)", directoryHint: .isDirectory)
        workspace = root.appending(path: "packs", directoryHint: .isDirectory)
        stagingRoot = root.appending(path: "staging", directoryHint: .isDirectory)
        sources = root.appending(path: "sources", directoryHint: .isDirectory)
        for folder in [workspace, stagingRoot, sources, workspace.appending(path: "Empty Folder", directoryHint: .isDirectory)] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let hidden = workspace.appending(path: ".hidden", directoryHint: .isDirectory)
        try fm.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: hidden.appending(path: "notes.txt"))
        for file in Self.packFiles(title: "Existing") {
            let url = workspace.appending(path: "pack/\(file.name)")
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
    }

    func cleanUp() {
        try? NewFileBlock.clear(on: stagingRoot)
        try? FileManager.default.removeItem(at: root)
    }

    /// Sounds first and `keyLED` last, so a failure in `keyLED` comes after several written files.
    static func packFiles(title: String, soundCount: Int = 6, soundSize: Int = 32 * 1024) -> [(name: String, data: Data)] {
        let keySound = (0..<soundCount).map { "1 \($0 / 8 + 1) \($0 % 8 + 1) \($0).wav" }.joined(separator: "\n")
        return [
            ("info", Data("title=\(title)\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\n".utf8)),
            ("keySound", Data(keySound.utf8)),
        ] + (0..<soundCount).map { ("sounds/\($0).wav", Data(repeating: 0, count: soundSize)) }
            + [("keyLED/1 1 1 1", Data("o 1 1 a 3\nd 100\nf 1 1\n".utf8))]
    }

    static func expectedSnapshot(title: String) -> [String: String] {
        var snapshot: [String: String] = [:]
        for file in packFiles(title: title) {
            snapshot[file.name] = sha256(file.data)
            let folder = (file.name as NSString).deletingLastPathComponent
            if !folder.isEmpty { snapshot[folder] = folderMark }
        }
        return snapshot
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let folderMark = "folder"

    /// Relative path of every item in `folder`, hidden ones and empty folders included, with the
    /// SHA-256 of each file.
    func snapshot(of folder: URL) -> [String: String] {
        let fm = FileManager.default
        var snapshot: [String: String] = [:]
        for path in fm.subpaths(atPath: folder.path) ?? [] {
            let url = folder.appending(path: path)
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            snapshot[path] = isFolder.boolValue
                ? Self.folderMark
                : (try? Data(contentsOf: url)).map(Self.sha256) ?? "unreadable"
        }
        return snapshot
    }

    func workspaceSnapshot() -> [String: String] { snapshot(of: workspace) }
    func stagingSnapshot() -> [String: String] { snapshot(of: stagingRoot) }

    func stagingFolders() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)) ?? []
    }

    func relativeToStaging(_ url: URL) -> String {
        String(url.path.dropFirst(stagingRoot.path.count + 1))
    }

    func source(_ zip: Data) throws -> URL {
        let url = sources.appending(path: "\(UUID().uuidString).zip")
        try zip.write(to: url)
        return url
    }

    func importData(_ data: Data, _ recorder: ImportRecorder) async -> ImportOutcome {
        do {
            return .init(folder: try await UniPackImporter(stagingRoot: stagingRoot)
                .importPack(data: data, fileName: "pack.zip", to: workspace, delegate: recorder))
        } catch {
            return .init(error: error)
        }
    }

    func download(from host: String, session: URLSession, _ recorder: DownloadRecorder) async {
        await UniPackDownloader(session: session, stagingRoot: stagingRoot).download(
            title: "pack", url: "https://\(host)/pack.zip", workspace: workspace, folderName: "pack", delegate: recorder
        )
    }

    /// The library is as it was, the staging root is empty, and the source archive is untouched.
    func expectNothingChanged(since before: [String: String], source: URL? = nil, archive: Data? = nil) {
        #expect(workspaceSnapshot() == before)
        #expect(stagingFolders().isEmpty)
        if let source, let archive {
            #expect((try? Data(contentsOf: source)).map(Self.sha256) == Self.sha256(archive))
        }
    }

    /// Imports `zip` again with nothing in the way and expects it to be added as one new folder
    /// beside everything that was there.
    @discardableResult
    func expectImportRetryInstalls(_ zip: Data, since before: [String: String]) async throws -> URL {
        let recorder = ImportRecorder()
        let folder = try #require(await importData(zip, recorder).folder)
        #expect(recorder.error == nil)
        let name = folder.lastPathComponent
        #expect(before[name] == nil, "the retry replaced \(name)")
        #expect(snapshot(of: folder) == Self.expectedSnapshot(title: "Imported"))
        #expect(workspaceSnapshot().filter { $0.key != name && !$0.key.hasPrefix(name + "/") } == before)
        #expect(stagingFolders().isEmpty)
        return folder
    }
}

struct ImportOutcome {
    var folder: URL?
    var error: Error?
}

// MARK: - Making writes fail

/// Refuses new files in a folder with an access-control entry for everyone. Deleting stays allowed,
/// as on a full disk, so a failed install can still remove what it wrote.
enum NewFileBlock {
    /// With `inFoldersCreatedInside`, the rule is not applied to `folder` itself but to each folder
    /// created directly inside it from now on.
    static func set(on folder: URL, inFoldersCreatedInside: Bool = false) throws {
        var acl: acl_t? = acl_init(1)
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var permissions: acl_permset_t?
        try check(acl_create_entry(&acl, &entry))
        try check(acl_set_tag_type(entry, ACL_EXTENDED_DENY))
        var everyone = everyoneGroup
        try check(acl_set_qualifier(entry, &everyone))
        try check(acl_get_permset(entry, &permissions))
        try check(acl_add_perm(permissions, ACL_ADD_FILE))
        try check(acl_set_permset(entry, permissions))
        if inFoldersCreatedInside {
            var flags: acl_flagset_t?
            try check(acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags))
            for flag in [ACL_ENTRY_DIRECTORY_INHERIT, ACL_ENTRY_LIMIT_INHERIT, ACL_ENTRY_ONLY_INHERIT] {
                try check(acl_add_flag_np(flags, flag))
            }
            try check(acl_set_flagset_np(UnsafeMutableRawPointer(entry), flags))
        }
        try check(acl_set_file(folder.path, ACL_TYPE_EXTENDED, acl))
    }

    static func clear(on folder: URL) throws {
        let empty = acl_init(0)
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        try check(acl_set_file(folder.path, ACL_TYPE_EXTENDED, empty))
    }

    /// The fixed identifier of the system group every user belongs to.
    private static let everyoneGroup = UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C")!.uuid

    private static func check(_ result: Int32) throws {
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}

/// Calls `beforeCopy` with the destination of every `FileManager` copy into `root`, before the copy
/// is written. The importer copies the archive into a new staging folder right before unpacking it,
/// which makes this the point where that folder is known and still empty.
///
/// The default file manager takes no delegate, so while observing, its copy method is wrapped in
/// one that reports the destination and then calls the original unchanged.
final class StagingCopyObserver: @unchecked Sendable {
    private typealias CopyFunction = @convention(c) (FileManager, Selector, NSURL, NSURL, NSErrorPointer) -> ObjCBool
    private typealias CopyBlock = @convention(block) (FileManager, NSURL, NSURL, NSErrorPointer) -> ObjCBool

    private let root: String
    private let beforeCopy: @Sendable (URL) throws -> Void
    private let lock = NSLock()
    private var observedCopies: [URL] = []
    private var observedErrors: [Error] = []

    var copies: [URL] { lock.withLock { observedCopies } }
    /// Errors `beforeCopy` threw; the copy goes ahead regardless.
    var errors: [Error] { lock.withLock { observedErrors } }

    init(root: URL, beforeCopy: @escaping @Sendable (URL) throws -> Void) {
        self.root = root.path + "/"
        self.beforeCopy = beforeCopy
    }

    /// Copies outside `root`, made by anything else running meanwhile, go through untouched.
    func whileObserving<T>(_ body: () async throws -> T) async rethrows -> T {
        let selector = #selector(FileManager.copyItem(at:to:))
        let method = class_getInstanceMethod(object_getClass(FileManager.default), selector)!
        let original = method_getImplementation(method)
        let callOriginal = unsafeBitCast(original, to: CopyFunction.self)
        let wrapper: CopyBlock = { [self] manager, source, destination, error in
            observe(destination as URL)
            return callOriginal(manager, selector, source, destination, error)
        }
        method_setImplementation(method, imp_implementationWithBlock(wrapper))
        defer { method_setImplementation(method, original) }
        return try await body()
    }

    private func observe(_ destination: URL) {
        guard destination.path.hasPrefix(root) else { return }
        lock.withLock { observedCopies.append(destination) }
        do {
            try beforeCopy(destination)
        } catch {
            lock.withLock { observedErrors.append(error) }
        }
    }
}

// MARK: - Delegates

@MainActor
final class ImportRecorder: UniPackImporter.Delegate, @unchecked Sendable {
    private let onFailure: (Error) -> Void
    var started = 0
    var completedFolder: URL?
    var error: Error?

    /// `onFailure` runs when the failure is reported, before the staging folder is deleted.
    init(onFailure: @escaping (Error) -> Void = { _ in }) {
        self.onFailure = onFailure
    }

    func onImportStart() { started += 1 }
    func onImportComplete(folder: URL) { completedFolder = folder }
    func onImportError(_ error: Error) {
        self.error = error
        onFailure(error)
    }
}

@MainActor
final class DownloadRecorder: UniPackDownloader.Delegate, @unchecked Sendable {
    private let onFailure: (Error) -> Void
    var percents: [Int] = []
    var downloadedSize: Int64 = 0
    var importStarted = false
    var installedFolder: URL?
    var error: Error?

    /// `onFailure` runs when the failure is reported, before the staging folder is deleted.
    init(onFailure: @escaping (Error) -> Void = { _ in }) {
        self.onFailure = onFailure
    }

    func onInstallStart() {}
    func onGetFileSize(fileSize: Int64, contentLength: Int64, preKnownFileSize: Int64) {}
    func onDownloadProgress(percent: Int, downloadedSize: Int64, fileSize: Int64) {
        percents.append(percent)
        self.downloadedSize = downloadedSize
    }
    func onImportStart() { importStarted = true }
    func onInstallComplete(folder: URL) { installedFolder = folder }
    func onError(_ error: Error) {
        self.error = error
        onFailure(error)
    }
}
