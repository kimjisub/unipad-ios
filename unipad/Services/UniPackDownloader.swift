import Foundation
import os.log

actor UniPackDownloader {
    private let logger = Logger(subsystem: "com.kimjisub.unipad", category: "Downloader")

    enum DownloadError: LocalizedError {
        case emptyResponse
        case criticalError(String)
        case cancelled
        case httpError(statusCode: Int)
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "Empty response body"
            case .httpError(let statusCode): return "Server returned HTTP \(statusCode)"
            case .writeFailed: return "Could not write the downloaded file"
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

    /// Chunks are written to disk on the session's delegate queue, so downloads get their own
    /// session instead of occupying the queue that `URLSession.shared` callbacks share.
    private static let downloadSession = URLSession(configuration: .default)

    init(session: URLSession = downloadSession) {
        self.session = session
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

        // Another download of the same name may run at the same time, so only paths claimed here
        // are written to or deleted.
        var zipFile: URL?
        var folder: URL?

        do {
            guard let requestURL = URL(string: url) else {
                throw DownloadError.emptyResponse
            }

            let claimedZip = try FileManagerExtensions.claimNextPath(dir: workspace, name: folderName, extension: ".zip", isDirectory: false)
            zipFile = claimedZip

            // Download with progress reporting
            let (tempURL, response) = try await downloadWithProgress(
                from: requestURL,
                to: claimedZip,
                preKnownFileSize: preKnownFileSize,
                delegate: delegate
            )

            let contentLength = Int64(response.expectedContentLength)
            let fileSize = max(contentLength, preKnownFileSize)
            await delegate?.onGetFileSize(fileSize: fileSize, contentLength: contentLength, preKnownFileSize: preKnownFileSize)

            await delegate?.onImportStart()

            // Extract ZIP
            let fm = FileManager.default
            let claimedFolder = try FileManagerExtensions.claimNextPath(dir: workspace, name: folderName, extension: "", isDirectory: true)
            folder = claimedFolder

            // Move downloaded file to expected location if needed
            if tempURL != claimedZip {
                if fm.fileExists(atPath: claimedZip.path) {
                    try fm.removeItem(at: claimedZip)
                }
                try fm.moveItem(at: tempURL, to: claimedZip)
            }

            try await importer.extractOnly(at: claimedZip, to: claimedFolder)
            FileManagerExtensions.removeDoubleFolder(at: claimedFolder)

            // Validate extracted pack. load() runs the case-insensitive checkFile; the exact-case
            // `info` pre-check that used to sit here rejected a pack named `Info` that imports fine.
            let unipack = UniPackFolder(rootFolder: claimedFolder)
            unipack.load()
            unipack.loadDetail()
            if unipack.criticalError {
                throw DownloadError.criticalError(unipack.errorDetail ?? "Invalid unipack structure")
            }

            await delegate?.onInstallComplete(folder: claimedFolder)
            logger.info("Download + install complete: \(claimedFolder.lastPathComponent)")

        } catch {
            logger.error("Download failed: \(error.localizedDescription)")
            if let folder {
                FileManagerExtensions.deleteDirectory(at: folder)
            }
            await delegate?.onError(error)
        }

        // Cleanup ZIP
        if let zipFile {
            FileManagerExtensions.deleteDirectory(at: zipFile)
        }
    }

    // MARK: - Download with Progress

    private func downloadWithProgress(
        from url: URL,
        to destination: URL,
        preKnownFileSize: Int64,
        delegate: Delegate?
    ) async throws -> (URL, URLResponse) {
        let writer = DownloadFileWriter(destination: destination)
        let task = session.dataTask(with: url)
        task.delegate = writer
        writer.cancelOnTermination(task)
        task.resume()

        do {
            var prevPercent = -1
            for try await progress in writer.progress {
                let fileSize = max(progress.expected, preKnownFileSize)
                guard fileSize > 0 else { continue }
                let percent = Int(Double(progress.received) / Double(fileSize) * 100)
                if percent != prevPercent {
                    prevPercent = percent
                    await delegate?.onDownloadProgress(percent: percent, downloadedSize: progress.received, fileSize: fileSize)
                }
            }
            // A cancelled consumer ends the stream without an error; the file is incomplete then.
            try Task.checkCancellation()
        } catch {
            // The caller deletes the partial file next; a callback still in flight must not recreate it.
            await writer.waitUntilComplete()
            throw error
        }

        guard let response = writer.response else { throw DownloadError.emptyResponse }
        return (destination, response)
    }
}

/// Appends a data task's body to `destination` in the chunks URLSession delivers, so the body is
/// never collected in memory. Progress is coalesced to the newest value so a busy main actor
/// cannot make it queue.
private final class DownloadFileWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Progress: Sendable {
        let received: Int64
        let expected: Int64
    }

    let progress: AsyncThrowingStream<Progress, Error>
    private let continuation: AsyncThrowingStream<Progress, Error>.Continuation
    private let destination: URL

    // Written only on the session's serial delegate queue; `response` is read after `progress` ends.
    private(set) var response: URLResponse?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var failure: Error?

    private let completionLock = NSLock()
    private var isComplete = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(destination: URL) {
        self.destination = destination
        (progress, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Stops the transfer when the consumer goes away (its task is cancelled).
    func cancelOnTermination(_ task: URLSessionTask) {
        continuation.onTermination = { _ in task.cancel() }
    }

    /// Returns once the task has completed and the file is closed. Deliberately not cancellable:
    /// it is awaited on the cancellation path itself, and a cancelled task always completes.
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
            // A 404/HTML body used to be written to disk and surface later as "EOCD not found".
            failure = UniPackDownloader.DownloadError.httpError(statusCode: http.statusCode)
            completionHandler(.cancel)
            return
        }
        do {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw UniPackDownloader.DownloadError.writeFailed
            }
            handle = try FileHandle(forWritingTo: destination)
            self.response = response
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
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
        continuation.yield(Progress(received: received, expected: response?.expectedContentLength ?? -1))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
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
