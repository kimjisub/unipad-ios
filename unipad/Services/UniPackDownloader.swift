import Foundation
import os.log
#if os(iOS)
import UIKit
#endif

actor UniPackDownloader {
    private let logger = Logger(subsystem: "com.kimjisub.unipad", category: "Downloader")

    enum DownloadError: LocalizedError {
        case emptyResponse
        case criticalError(String)
        case cancelled
        case httpError(statusCode: Int)
        case writeFailed
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "Empty response body"
            case .httpError(let statusCode): return "Server returned HTTP \(statusCode)"
            case .writeFailed: return "Could not write the downloaded file"
            case .invalidResponse: return "Server returned an invalid partial response"
            case .criticalError(let msg): return "Critical error: \(msg)"
            case .cancelled: return "Download cancelled"
            }
        }
    }

    protocol Delegate: AnyObject, Sendable {
        @MainActor func onInstallStart()
        @MainActor func onGetFileSize(fileSize: Int64, contentLength: Int64, preKnownFileSize: Int64)
        @MainActor func onDownloadProgress(percent: Int, downloadedSize: Int64, fileSize: Int64)
        @MainActor func onImportStart()
        @MainActor func onInstallComplete(folder: URL)
        @MainActor func onError(_ error: Error)
    }

    private let importer = UniPackImporter()
    private let session: URLSession
    private let stagingRoot: URL
    private let waitBeforeRetry: @Sendable (Duration) async throws -> Void

    /// Chunks are written to disk on the session's delegate queue, so downloads get their own
    /// session instead of occupying the queue that `URLSession.shared` callbacks share.
    private static let downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
#if DEBUG || UNIPAD_RELEASE_TESTS
        ReleaseTestSupport.configure(configuration)
#endif
        return URLSession(configuration: configuration)
    }()

    init(
        session: URLSession = downloadSession,
        stagingRoot: URL = UniPackStaging.defaultRoot,
        waitBeforeRetry: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.session = session
        self.stagingRoot = stagingRoot
        self.waitBeforeRetry = waitBeforeRetry
    }

    func download(
        title: String,
        url: String,
        workspace: URL,
        folderName: String,
        preKnownFileSize: Int64 = 0,
        delegate: Delegate?
    ) async {
        await delegate?.onInstallStart()
        let background = await DownloadBackgroundExecution()

        // The archive and the unpacked pack stay in a staging folder until the pack is complete, so
        // neither a failure nor the app being killed leaves a partial pack in the library.
        var staging: UniPackStaging?

        do {
            guard let requestURL = URL(string: url) else {
                throw DownloadError.emptyResponse
            }

            let staged = try UniPackStaging(root: stagingRoot)
            staging = staged
            let archive = staged.file(named: "download.zip")

            // Download with progress reporting
            let contentLength = try await downloadWithProgress(
                from: requestURL,
                to: archive,
                preKnownFileSize: preKnownFileSize,
                delegate: delegate,
                background: background
            )

            let fileSize = max(contentLength, preKnownFileSize)
            await delegate?.onGetFileSize(fileSize: fileSize, contentLength: contentLength, preKnownFileSize: preKnownFileSize)

            try Task.checkCancellation()
            await delegate?.onImportStart()

            try await importer.extractOnly(at: archive, to: staged.packFolder)
            try FileManagerExtensions.unwrapUniPackFolder(at: staged.packFolder)

            // Validate extracted pack. load() runs the case-insensitive checkFile; the exact-case
            // `info` pre-check that used to sit here rejected a pack named `Info` that imports fine.
            let unipack = UniPackFolder(rootFolder: staged.packFolder)
            unipack.load()
            unipack.loadDetail()
            if unipack.criticalError {
                throw DownloadError.criticalError(unipack.errorDetail ?? "Invalid unipack structure")
            }

            // Another download of the same name may finish meanwhile; publishing takes the next
            // free name instead of replacing it.
            try Task.checkCancellation()
            let folder = try staged.publish(to: workspace, name: folderName)

            await delegate?.onInstallComplete(folder: folder)
            logger.info("Download + install complete: \(folder.lastPathComponent)")

        } catch {
            logger.error("Download failed: \(error.localizedDescription)")
            await delegate?.onError(error)
        }

        await background.end()
        staging?.discard()
    }

    // MARK: - Download with Progress

    private func downloadWithProgress(
        from url: URL,
        to destination: URL,
        preKnownFileSize: Int64,
        delegate: Delegate?,
        background: DownloadBackgroundExecution
    ) async throws -> Int64 {
        var resume: DownloadFileWriter.Resume?
        var retries = 0
        while true {
            try Task.checkCancellation()
            try await background.prepareForAttempt()
            var request = URLRequest(url: url)
            // Range offsets refer to the stored representation, never a transparently decoded body.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let resume {
                request.setValue("bytes=\(resume.received)-", forHTTPHeaderField: "Range")
                request.setValue(resume.validator, forHTTPHeaderField: "If-Range")
            }
            let writer = DownloadFileWriter(destination: destination, resume: resume)
            let task = session.dataTask(with: request)
            task.delegate = writer
            writer.cancelOnTermination(task)
            await background.track(task)
            task.resume()

            do {
                var prevPercent = -1
                for try await progress in writer.progress {
                    let fileSize = max(progress.expected, preKnownFileSize)
                    guard fileSize > 0 else { continue }
                    let percent = min(100, Int(Double(progress.received) / Double(fileSize) * 100))
                    if percent != prevPercent {
                        prevPercent = percent
                        await delegate?.onDownloadProgress(percent: percent, downloadedSize: progress.received, fileSize: fileSize)
                    }
                }
                try Task.checkCancellation()
                await writer.waitUntilComplete()
                await background.track(nil)
                guard writer.response != nil else { throw DownloadError.emptyResponse }
                return writer.expected
            } catch {
                // Close the file before either reusing its bytes or allowing staging cleanup.
                task.cancel()
                await writer.waitUntilComplete()
                await background.track(nil)
                try Task.checkCancellation()
                let expired = await background.expired
                let failure = expired && (error as? URLError)?.code == .cancelled
                    ? URLError(.networkConnectionLost) : error
                guard retries < 3, Self.isRetryable(failure) else { throw failure }
                resume = writer.resumeState
                let delay = 1 << retries
                retries += 1
                try await waitBeforeRetry(.seconds(delay))
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}

/// Owns a short background assertion for one download. Expiration stops its connection, then the
/// normal retry loop waits for the foreground without spending the remaining attempts offscreen.
@MainActor
private final class DownloadBackgroundExecution {
    #if os(iOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif
    private var task: URLSessionTask?
    private(set) var expired = false

    init() { begin() }

    private func begin() {
        expired = false
        #if os(iOS)
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Pack download") { [weak self] in
            guard let self else { return }
            self.expired = true
            self.task?.cancel()
            self.end()
        }
        #endif
    }

    func prepareForAttempt() async throws {
        guard expired else { return }
        #if os(iOS)
        while UIApplication.shared.applicationState == .background {
            try await Task.sleep(for: .milliseconds(100))
        }
        #endif
        try Task.checkCancellation()
        begin()
    }

    func track(_ task: URLSessionTask?) {
        self.task = task
        if expired { task?.cancel() }
    }

    func end() {
        task = nil
        #if os(iOS)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        #endif
    }
}

/// Writes each response on the session's serial delegate queue. State is read only after task
/// completion; resuming requires both range support and a validator for the bytes already stored.
/// Bodies stay on disk and progress is coalesced so a busy main actor cannot queue every chunk.
private final class DownloadFileWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Progress: Sendable {
        let received: Int64
        let expected: Int64
    }

    struct Resume: Sendable {
        let received: Int64
        let expected: Int64
        let validator: String
    }

    let progress: AsyncThrowingStream<Progress, Error>
    private let continuation: AsyncThrowingStream<Progress, Error>.Continuation
    private let destination: URL
    private let previous: Resume?
    private(set) var response: URLResponse?
    private var handle: FileHandle?
    private var received: Int64
    private(set) var expected: Int64
    private var validator: String?
    private var failure: Error?

    var resumeState: Resume? {
        guard received > 0, let validator else { return nil }
        return Resume(received: received, expected: expected, validator: validator)
    }

    private let completionLock = NSLock()
    private var isComplete = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(destination: URL, resume: Resume?) {
        self.destination = destination
        previous = resume
        received = resume?.received ?? 0
        expected = resume?.expected ?? -1
        validator = resume?.validator
        (progress, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func cancelOnTermination(_ task: URLSessionTask) {
        continuation.onTermination = { _ in task.cancel() }
    }

    /// Deliberately not cancellable: cleanup must wait for the file to close on cancellation too.
    func waitUntilComplete() async {
        await withCheckedContinuation { waiter in
            let alreadyComplete = completionLock.withLock {
                if !isComplete { completionWaiters.append(waiter) }
                return isComplete
            }
            if alreadyComplete { waiter.resume() }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            failure = UniPackDownloader.DownloadError.httpError(statusCode: http.statusCode)
            completionHandler(.cancel)
            return
        }
        do {
            if let http = response as? HTTPURLResponse, http.statusCode == 206 {
                guard let previous, Self.validPartialResponse(http, previous: previous) else {
                    throw UniPackDownloader.DownloadError.invalidResponse
                }
                handle = try FileHandle(forWritingTo: destination)
                let size = try handle?.seekToEnd()
                guard size == UInt64(previous.received) else {
                    throw UniPackDownloader.DownloadError.writeFailed
                }
                expected = Self.partialTotal(http) ?? previous.expected
            } else {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw UniPackDownloader.DownloadError.writeFailed
                }
                handle = try FileHandle(forWritingTo: destination)
                received = 0
                expected = response.expectedContentLength
                validator = (response as? HTTPURLResponse).flatMap(Self.resumeValidator)
            }
            self.response = response
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    private static func resumeValidator(_ http: HTTPURLResponse) -> String? {
        guard http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else { return nil }
        if let tag = http.value(forHTTPHeaderField: "ETag"), tag.hasPrefix("\""), tag.hasSuffix("\"") { return tag }
        guard let date = http.value(forHTTPHeaderField: "Last-Modified"), !date.isEmpty else { return nil }
        return date
    }

    private static func partialTotal(_ http: HTTPURLResponse) -> Int64? {
        guard let parts = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/"), parts.count == 2 else { return nil }
        return Int64(parts[1])
    }

    private static func validPartialResponse(_ http: HTTPURLResponse, previous: Resume) -> Bool {
        guard let range = http.value(forHTTPHeaderField: "Content-Range"), range.hasPrefix("bytes "),
              let total = partialTotal(http), total > previous.received,
              previous.expected < 0 || total == previous.expected else { return false }
        let bounds = range.dropFirst(6).split(separator: "/").first?.split(separator: "-") ?? []
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start == previous.received, end == total - 1,
              http.expectedContentLength < 0 || http.expectedContentLength == total - start,
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else { return false }
        // A server honoring If-Range may omit the validator, but must not send a different one.
        if let validator = http.value(forHTTPHeaderField: "ETag"), previous.validator.hasPrefix("\"") {
            return validator == previous.validator
        }
        if let date = http.value(forHTTPHeaderField: "Last-Modified"), !previous.validator.hasPrefix("\"") {
            return date == previous.validator
        }
        return true
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle, failure == nil else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        continuation.yield(Progress(received: received, expected: expected))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try handle?.close() } catch { if failure == nil { failure = error } }
        handle = nil
        if failure == nil, error == nil, expected >= 0, received != expected {
            failure = received < expected ? URLError(.networkConnectionLost) : UniPackDownloader.DownloadError.invalidResponse
        }
        let waiters = completionLock.withLock {
            isComplete = true
            defer { completionWaiters.removeAll() }
            return completionWaiters
        }
        waiters.forEach { $0.resume() }
        if let failure = failure ?? error {
            continuation.finish(throwing: failure)
        } else {
            continuation.finish()
        }
    }
}
