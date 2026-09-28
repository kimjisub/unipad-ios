import Foundation
import Testing
@testable import unipad

/// The downloader writes the body to disk chunk by chunk, reports progress, and leaves nothing
/// behind (and deletes nothing it did not create) when the transfer fails or is cancelled.
@MainActor
struct UniPackDownloaderTests {
    private let workspace: URL
    private let session: URLSession
    private let host = "stub-\(UUID().uuidString.lowercased()).test"

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "UniPackDownloaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    private var url: String { "https://\(host)/pack.zip" }

    private func cleanUp() {
        StubURLProtocol.remove(host: host)
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: workspace)
    }

    private func workspaceContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: workspace.path).sorted()
    }

    private func download(_ recorder: RecordingDelegate, preKnownFileSize: Int64 = 0) async {
        await UniPackDownloader(session: session).download(
            title: "pack",
            url: url,
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
}

@MainActor
private final class RecordingDelegate: UniPackDownloader.Delegate, @unchecked Sendable {
    private let zipURL: URL
    var percents: [Int] = []
    var lastDownloadedSize: Int64 = 0
    var importStarted = false
    var zipAtImportStart: Data?
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

    func onInstallComplete(folder: URL) {}
    func onError(_ error: Error) { self.error = error }
}

/// Serves a scripted response per host: a status, body chunks delivered one by one, then either
/// success, an error, or silence until the task is cancelled.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Script: Sendable {
        var status: Int
        var chunks: [Data]
        var contentLength: Int?
        var failure: URLError?
        var stallsAfterChunks = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]

    static func register(host: String, _ script: Script) {
        lock.withLock { scripts[host] = script }
    }

    static func remove(host: String) {
        _ = lock.withLock { scripts.removeValue(forKey: host) }
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
        if script.stallsAfterChunks { return }
        if let failure = script.failure {
            client?.urlProtocol(self, didFailWithError: failure)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
