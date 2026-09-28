import Foundation
import Testing
@testable import unipad

/// The downloader writes the body to disk chunk by chunk, reports progress, and leaves nothing
/// behind (and deletes nothing it did not create) when the transfer fails or is cancelled, even
/// while another download of the same name is in flight.
@MainActor
struct UniPackDownloaderTests {
    private let workspace: URL
    private let session: URLSession
    private let host = "stub-\(UUID().uuidString.lowercased()).test"
    private let otherHost = "stub-\(UUID().uuidString.lowercased()).test"

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "UniPackDownloaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    private func cleanUp() {
        StubURLProtocol.remove(host: host)
        StubURLProtocol.remove(host: otherHost)
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: workspace)
    }

    private func workspaceContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: workspace.path).sorted()
    }

    private func download(_ recorder: RecordingDelegate, from host: String? = nil, preKnownFileSize: Int64 = 0) async {
        await UniPackDownloader(session: session).download(
            title: "pack",
            url: "https://\(host ?? self.host)/pack.zip",
            workspace: workspace,
            folderName: "pack",
            preKnownFileSize: preKnownFileSize,
            delegate: recorder
        )
    }

    @Test func writesEveryChunkInOrderAndReportsFullProgress() async throws {
        defer { cleanUp() }
        let chunks = (0..<40).map { i in Data(repeating: UInt8(i), count: 64 * 1024 + i) }
        let body = chunks.reduce(Data(), +)
        StubURLProtocol.register(host: host, .init(status: 200, chunks: chunks, contentLength: body.count))
        let recorder = RecordingDelegate(zipURL: workspace.appending(path: "pack.zip"))

        await download(recorder)

        #expect(recorder.zipAtImportStart == body)
        #expect(recorder.percents.last == 100)
        #expect(recorder.percents == recorder.percents.sorted())
        #expect(recorder.lastDownloadedSize == Int64(body.count))
        // The body is not a ZIP, so extraction fails and both the ZIP and the folder are removed.
        #expect(recorder.error != nil)
        #expect(try workspaceContents().isEmpty)
    }

    @Test func httpErrorIsReportedAndLeavesNothing() async throws {
        defer { cleanUp() }
        StubURLProtocol.register(host: host, .init(status: 404, chunks: [Data("missing".utf8)]))
        let recorder = RecordingDelegate(zipURL: workspace.appending(path: "pack.zip"))

        await download(recorder)

        guard case .httpError(statusCode: 404)? = recorder.error as? UniPackDownloader.DownloadError else {
            Issue.record("expected httpError(404), got \(String(describing: recorder.error))")
            return
        }
        #expect(!recorder.importStarted)
        #expect(try workspaceContents().isEmpty)
    }

    @Test func failureMidTransferLeavesNothingAndKeepsInstalledPack() async throws {
        defer { cleanUp() }
        let installed = workspace.appending(path: "pack", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("title=Installed\n".utf8).write(to: installed.appending(path: "info"))
        StubURLProtocol.register(host: host, .init(
            status: 200,
            chunks: [Data(repeating: 1, count: 100_000)],
            contentLength: 1_000_000,
            failure: URLError(.networkConnectionLost)
        ))
        let recorder = RecordingDelegate(zipURL: workspace.appending(path: "pack.zip"))

        await download(recorder)

        #expect((recorder.error as? URLError)?.code == .networkConnectionLost)
        #expect(!recorder.importStarted)
        #expect(try workspaceContents() == ["pack"])
        #expect(try Data(contentsOf: installed.appending(path: "info")) == Data("title=Installed\n".utf8))
    }

    @Test func cancellationStopsTheTransferAndLeavesNothing() async throws {
        defer { cleanUp() }
        StubURLProtocol.register(host: host, .init(
            status: 200,
            chunks: [Data(repeating: 1, count: 100_000)],
            contentLength: 10_000_000,
            stallsAfterChunks: true
        ))
        let recorder = RecordingDelegate(zipURL: workspace.appending(path: "pack.zip"))

        let task = Task { await download(recorder) }
        let deadline = ContinuousClock.now + .seconds(10)
        while recorder.percents.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!recorder.percents.isEmpty)
        task.cancel()
        await task.value

        #expect(recorder.error?.isUsageCancellation == true)
        #expect(!recorder.importStarted)
        #expect(try workspaceContents().isEmpty)
    }

    // MARK: - Two downloads of the same name

    private static func packZip(title: String) -> Data {
        TestZip.stored([
            ("info", Data("title=\(title)\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\n".utf8)),
            ("keySound", Data("1 1 1 a.wav\n".utf8)),
            ("sounds/a.wav", Data(repeating: 0, count: 8 * 1024)),
        ])
    }

    private func info(in folder: String) throws -> String {
        try String(contentsOf: workspace.appending(path: folder).appending(path: "info"), encoding: .utf8)
    }

    /// URLSession holds back the response until it has enough bytes to sniff the content type.
    private static let stalledHeadSize = 4 * 1024

    /// Starts a download from `otherHost` that writes the first bytes of `body` and then waits for
    /// `StubURLProtocol.release`: the other request overlapping the one under test.
    private func startStalledDownload(
        _ recorder: RecordingDelegate,
        body: Data = Data(repeating: 1, count: 100_000)
    ) async throws -> Task<Void, Never> {
        StubURLProtocol.register(host: otherHost, .init(
            status: 200,
            chunks: [body.prefix(Self.stalledHeadSize)],
            contentLength: body.count,
            stallsAfterChunks: true
        ))
        let task = Task { await download(recorder, from: otherHost) }
        let deadline = ContinuousClock.now + .seconds(10)
        while !StubURLProtocol.isStalled(host: otherHost) || recorder.percents.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!recorder.percents.isEmpty)
        return task
    }

    private func installPack(title: String, _ recorder: RecordingDelegate) async {
        let zip = Self.packZip(title: title)
        StubURLProtocol.register(host: host, .init(status: 200, chunks: [zip], contentLength: zip.count))
        await download(recorder)
    }

    @Test func cancellingOneOfTwoKeepsTheOtherResultAndTheExistingPack() async throws {
        defer { cleanUp() }
        let existing = workspace.appending(path: "pack", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("title=Installed\n".utf8).write(to: existing.appending(path: "info"))
        let cancelled = RecordingDelegate(zipURL: workspace.appending(path: "unused.zip"))
        let succeeded = RecordingDelegate(zipURL: workspace.appending(path: "unused.zip"))

        let other = try await startStalledDownload(cancelled)
        await installPack(title: "Succeeded", succeeded)
        other.cancel()
        await other.value

        #expect(cancelled.error?.isUsageCancellation == true)
        let installed = try #require(succeeded.installedFolder)
        #expect(try workspaceContents() == ["pack", installed.lastPathComponent].sorted())
        #expect(try info(in: installed.lastPathComponent).contains("title=Succeeded"))
        #expect(try info(in: "pack") == "title=Installed\n")
    }

    @Test func failingOneOfTwoKeepsTheOtherResult() async throws {
        defer { cleanUp() }
        let failed = RecordingDelegate(zipURL: workspace.appending(path: "unused.zip"))
        let succeeded = RecordingDelegate(zipURL: workspace.appending(path: "unused.zip"))

        let other = try await startStalledDownload(failed)
        await installPack(title: "Succeeded", succeeded)
        StubURLProtocol.release(host: otherHost, .fail(URLError(.networkConnectionLost)))
        await other.value

        #expect((failed.error as? URLError)?.code == .networkConnectionLost)
        let installed = try #require(succeeded.installedFolder)
        #expect(try workspaceContents() == [installed.lastPathComponent])
        #expect(try info(in: installed.lastPathComponent).contains("title=Succeeded"))
    }

    @Test func twoOverlappingSuccessesInstallSeparately() async throws {
        defer { cleanUp() }
        let second = RecordingDelegate(zipURL: workspace.appending(path: "unused.zip"))
        let first = RecordingDelegate(zipURL: workspace.appending(path: "unused.zip"))

        let secondZip = Self.packZip(title: "Second")
        let other = try await startStalledDownload(second, body: secondZip)
        await installPack(title: "First", first)
        StubURLProtocol.release(host: otherHost, .finish([secondZip.dropFirst(Self.stalledHeadSize)]))
        await other.value

        #expect(first.error == nil)
        #expect(second.error == nil)
        let firstFolder = try #require(first.installedFolder).lastPathComponent
        let secondFolder = try #require(second.installedFolder).lastPathComponent
        #expect(firstFolder != secondFolder)
        #expect(try workspaceContents() == ["pack", "pack (2)"])
        #expect(try info(in: firstFolder).contains("title=First"))
        #expect(try info(in: secondFolder).contains("title=Second"))
    }

    @Test func retryAfterFailureInstallsUnderTheOriginalName() async throws {
        defer { cleanUp() }
        StubURLProtocol.register(host: host, .init(status: 500, chunks: [Data("down".utf8)]))
        let failed = RecordingDelegate(zipURL: workspace.appending(path: "unused.zip"))
        await download(failed)
        #expect(failed.error != nil)
        #expect(try workspaceContents().isEmpty)

        let retried = RecordingDelegate(zipURL: workspace.appending(path: "unused.zip"))
        await installPack(title: "Retried", retried)

        #expect(retried.error == nil)
        #expect(retried.installedFolder?.lastPathComponent == "pack")
        #expect(try workspaceContents() == ["pack"])
        #expect(try info(in: "pack").contains("title=Retried"))
    }
}

@MainActor
private final class RecordingDelegate: UniPackDownloader.Delegate, @unchecked Sendable {
    private let zipURL: URL
    var percents: [Int] = []
    var lastDownloadedSize: Int64 = 0
    var importStarted = false
    var zipAtImportStart: Data?
    var installedFolder: URL?
    var error: Error?

    init(zipURL: URL) {
        self.zipURL = zipURL
    }

    func onInstallStart() {}
    func onGetFileSize(fileSize: Int64, contentLength: Int64, preKnownFileSize: Int64) {}

    func onDownloadProgress(percent: Int, downloadedSize: Int64, fileSize: Int64) {
        percents.append(percent)
        lastDownloadedSize = downloadedSize
    }

    func onImportStart() {
        importStarted = true
        zipAtImportStart = try? Data(contentsOf: zipURL)
    }

    func onInstallComplete(folder: URL) { installedFolder = folder }
    func onError(_ error: Error) { self.error = error }
}

/// Serves a scripted response per host: a status, body chunks delivered one by one, then either
/// success, an error, or silence until the task is cancelled or `release` ends it.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Script: Sendable {
        var status: Int
        var chunks: [Data]
        var contentLength: Int?
        var failure: URLError?
        var stallsAfterChunks = false
    }

    enum Ending {
        case finish([Data])
        case fail(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    nonisolated(unsafe) private static var stalled: [String: StubURLProtocol] = [:]

    static func isStalled(host: String) -> Bool {
        lock.withLock { stalled[host] != nil }
    }

    static func release(host: String, _ ending: Ending) {
        guard let loader = lock.withLock({ stalled.removeValue(forKey: host) }) else { return }
        switch ending {
        case .finish(let chunks):
            chunks.forEach { loader.client?.urlProtocol(loader, didLoad: $0) }
            loader.client?.urlProtocolDidFinishLoading(loader)
        case .fail(let error):
            loader.client?.urlProtocol(loader, didFailWithError: error)
        }
    }

    static func register(host: String, _ script: Script) {
        lock.withLock { scripts[host] = script }
    }

    static func remove(host: String) {
        lock.withLock {
            scripts.removeValue(forKey: host)
            stalled.removeValue(forKey: host)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { scripts[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let script = Self.lock.withLock({ Self.scripts[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var headers: [String: String] = [:]
        if let length = script.contentLength { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in script.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if script.stallsAfterChunks {
            Self.lock.withLock { Self.stalled[host] = self }
            return
        }
        if let failure = script.failure {
            client?.urlProtocol(self, didFailWithError: failure)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
