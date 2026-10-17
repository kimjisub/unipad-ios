import Foundation
import Testing
@testable import unipad

private let smallVolume = ProcessInfo.processInfo.environment["UNIPAD_SMALL_VOLUME"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }

/// Runs a pack import and a store download out of space for real, on a small volume holding both
/// the library and the staging folders, and checks what `UniPackWriteFailureTests` checks with a
/// simulated failure. Each test writes one line with the error it got and how usage reports
/// classify it. Skipped unless `UNIPAD_SMALL_VOLUME` names a folder on such a volume, for example a
/// 64 MB RAM disk on the Mac running the simulator:
///
///     hdiutil attach -nomount ram://131072        # prints /dev/diskN
///     diskutil eraseDisk APFS UniPadFull /dev/diskN
///     TEST_RUNNER_UNIPAD_SMALL_VOLUME=/Volumes/UniPadFull \
///     TEST_RUNNER_UNIPAD_SMALL_VOLUME_OUT=<existing file> \
///         xcodebuild test ... -only-testing:unipadTests/UniPackOutOfSpaceTests
///     hdiutil detach /dev/diskN
@MainActor
@Suite(.serialized, .enabled(if: smallVolume != nil))
struct UniPackOutOfSpaceTests {
    private let library: WriteFailureLibrary
    private let session: URLSession
    private let host = "stub-\(UUID().uuidString.lowercased()).test"

    init() throws {
        guard let volume = smallVolume else { throw CocoaError(.fileNoSuchFile) }
        library = try WriteFailureLibrary(in: volume)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    private func cleanUp() {
        StubURLProtocol.remove(host: host)
        session.invalidateAndCancel()
        library.cleanUp()
    }

    private func availableCapacity() throws -> Int {
        try #require(try library.root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity)
    }

    /// Bytes of every file under the staging root, archives excluded.
    private func unpackedBytes() -> Int {
        let fm = FileManager.default
        return (fm.subpaths(atPath: library.stagingRoot.path) ?? [])
            .filter { !$0.hasSuffix(".zip") }
            .compactMap { try? fm.attributesOfItem(atPath: library.stagingRoot.appending(path: $0).path) }
            .filter { $0[.type] as? FileAttributeType == .typeRegular }
            .reduce(0) { $0 + (($1[.size] as? Int) ?? 0) }
    }

    private func record(_ name: String, _ error: Error, _ details: [(String, Any)]) {
        let nsError = error as NSError
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain)/\($0.code)" } ?? "-"
        let fields = [
            ("case", name), ("type", "\(type(of: error))"), ("domain", nsError.domain), ("code", "\(nsError.code)"),
            ("underlying", underlying), ("classified", UsageErrorType.classify(error).rawValue),
        ] + details.map { ($0.0, "\($0.1)") }
        let line = "UNIPAD_OUT_OF_SPACE " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        print(line)
        if let out = ProcessInfo.processInfo.environment["UNIPAD_SMALL_VOLUME_OUT"],
           let handle = FileHandle(forWritingAtPath: out) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            handle.closeFile()
        }
    }

    /// Silence compresses to almost nothing, so both copies of the archive fit and unpacking is
    /// what runs out of space.
    @Test func unpackingAPackLargerThanTheVolume() async throws {
        defer { cleanUp() }
        let free = try availableCapacity()
        let soundSize = 8 * 1024 * 1024
        let files = WriteFailureLibrary.packFiles(title: "Imported", soundCount: free / soundSize + 2, soundSize: soundSize)
        let zip = TestZip.deflated(files)
        let source = try library.source(zip)
        let before = library.workspaceSnapshot()
        var unpackedAtFailure = 0
        let recorder = ImportRecorder { _ in unpackedAtFailure = unpackedBytes() }

        let failure = await library.importData(try Data(contentsOf: source), recorder)

        let error = try #require(failure.error)
        let freeAfter = try availableCapacity()
        record("unpack", error, [
            ("packBytes", files.reduce(0) { $0 + $1.data.count }), ("archiveBytes", zip.count),
            ("freeBefore", free), ("unpackedBeforeFailure", unpackedAtFailure), ("freeAfter", freeAfter),
        ])
        #expect(unpackedAtFailure > 0, "space ran out before unpacking started")
        #expect(recorder.error != nil)
        library.expectNothingChanged(since: before, source: source, archive: zip)

        try await library.expectImportRetryInstalls(TestZip.stored(WriteFailureLibrary.packFiles(title: "Imported")), as: "pack (2)", since: before)
    }

    /// The first part of the body fits and is written before the rest arrives, so the volume fills
    /// up partway through the transfer.
    @Test func downloadingAPackLargerThanTheVolume() async throws {
        defer { cleanUp() }
        let free = try availableCapacity()
        let chunk = Data(repeating: 0, count: 1024 * 1024)
        let fitting = 16
        let chunkCount = free / chunk.count + 8
        StubURLProtocol.register(host: host, .init(
            status: 200, chunks: Array(repeating: chunk, count: fitting), contentLength: chunk.count * chunkCount,
            stallsAfterChunks: true
        ))
        let before = library.workspaceSnapshot()
        var archiveAtFailure: Int?
        let recorder = DownloadRecorder { _ in
            let archive = library.stagingFolders().first?.appending(path: "download.zip")
            archiveAtFailure = archive.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
        }

        let download = Task { await library.download(from: host, session: session, recorder) }
        let deadline = ContinuousClock.now + .seconds(30)
        while !StubURLProtocol.isStalled(host: host) || recorder.downloadedSize < Int64(chunk.count * fitting),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.downloadedSize == Int64(chunk.count * fitting))
        StubURLProtocol.release(host: host, .finish(Array(repeating: chunk, count: chunkCount - fitting)))
        await download.value

        let error = try #require(recorder.error)
        let freeAfter = try availableCapacity()
        record("download", error, [
            ("bodyBytes", chunk.count * chunkCount), ("freeBefore", free),
            ("archiveBeforeFailure", archiveAtFailure ?? -1), ("freeAfter", freeAfter),
        ])
        #expect(!(error is URLError) && !error.isUsageCancellation, "the transfer failed, not the write: \(error)")
        #expect((archiveAtFailure ?? 0) >= chunk.count * fitting, "the first part was not written")
        #expect(!recorder.importStarted)
        library.expectNothingChanged(since: before)

        let zip = TestZip.stored(WriteFailureLibrary.packFiles(title: "Downloaded"))
        StubURLProtocol.register(host: host, .init(status: 200, chunks: [zip], contentLength: zip.count))
        let retried = DownloadRecorder()
        await library.download(from: host, session: session, retried)
        #expect(retried.error == nil)
        #expect(retried.installedFolder?.lastPathComponent == "pack (2)")
        #expect(library.snapshot(of: library.workspace.appending(path: "pack (2)")) == WriteFailureLibrary.expectedSnapshot(title: "Downloaded"))
    }
}
