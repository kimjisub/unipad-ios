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

    func download(
        title: String,
        url: String,
        workspace: URL,
        folderName: String,
        preKnownFileSize: Int64 = 0,
        delegate: Delegate?
    ) async {
        let zipFile = FileManagerExtensions.makeNextPath(dir: workspace, name: folderName, extension: ".zip")
        let folder = FileManagerExtensions.makeNextPath(dir: workspace, name: folderName, extension: "")

        await delegate?.onInstallStart()

        do {
            guard let requestURL = URL(string: url) else {
                throw DownloadError.emptyResponse
            }

            // Download with progress reporting
            let (tempURL, response) = try await downloadWithProgress(
                from: requestURL,
                to: zipFile,
                preKnownFileSize: preKnownFileSize,
                delegate: delegate
            )

            let contentLength = Int64(response.expectedContentLength)
            let fileSize = max(contentLength, preKnownFileSize)
            await delegate?.onGetFileSize(fileSize: fileSize, contentLength: contentLength, preKnownFileSize: preKnownFileSize)

            await delegate?.onImportStart()

            // Extract ZIP
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)

            // Move downloaded file to expected location if needed
            if tempURL != zipFile {
                if fm.fileExists(atPath: zipFile.path) {
                    try fm.removeItem(at: zipFile)
                }
                try fm.moveItem(at: tempURL, to: zipFile)
            }

            try await importer.extractOnly(at: zipFile, to: folder)
            FileManagerExtensions.removeDoubleFolder(at: folder)

            // Validate extracted pack
            let infoFile = folder.appendingPathComponent("info")
            let infoJson = folder.appendingPathComponent("info.json")
            if !fm.fileExists(atPath: infoFile.path) && !fm.fileExists(atPath: infoJson.path) {
                FileManagerExtensions.deleteDirectory(at: folder)
                throw DownloadError.criticalError("No info file found in extracted pack")
            }

            let unipack = UniPackFolder(rootFolder: folder)
            unipack.load()
            unipack.loadDetail()
            if unipack.criticalError {
                FileManagerExtensions.deleteDirectory(at: folder)
                throw DownloadError.criticalError(unipack.errorDetail ?? "Invalid unipack structure")
            }

            await delegate?.onInstallComplete(folder: folder)
            logger.info("Download + install complete: \(folder.lastPathComponent)")

        } catch {
            logger.error("Download failed: \(error.localizedDescription)")
            FileManagerExtensions.deleteDirectory(at: folder)
            await delegate?.onError(error)
        }

        // Cleanup ZIP
        FileManagerExtensions.deleteDirectory(at: zipFile)
    }

    // MARK: - Download with Progress

    private func downloadWithProgress(
        from url: URL,
        to destination: URL,
        preKnownFileSize: Int64,
        delegate: Delegate?
    ) async throws -> (URL, URLResponse) {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // A 404/HTML body used to be written to disk and surface later as "EOCD not found".
            throw DownloadError.httpError(statusCode: http.statusCode)
        }

        let contentLength = response.expectedContentLength
        let fileSize = max(contentLength, preKnownFileSize)

        guard let outputStream = OutputStream(url: destination, append: false) else {
            throw DownloadError.emptyResponse
        }
        outputStream.open()
        defer { outputStream.close() }

        let bufferSize = 1024
        var buffer = [UInt8]()
        buffer.reserveCapacity(bufferSize)
        var downloadedSize: Int64 = 0
        var prevPercent = -1

        for try await byte in asyncBytes {
            buffer.append(byte)

            if buffer.count >= bufferSize {
                try Self.writeAll(buffer, to: outputStream)
                downloadedSize += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                if fileSize > 0 {
                    let percent = Int(Double(downloadedSize) / Double(fileSize) * 100)
                    if percent != prevPercent {
                        prevPercent = percent
                        await delegate?.onDownloadProgress(percent: percent, downloadedSize: downloadedSize, fileSize: fileSize)
                    }
                }
            }
        }

        // Flush remaining bytes
        if !buffer.isEmpty {
            try Self.writeAll(buffer, to: outputStream)
        }

        return (destination, response)
    }

    /// OutputStream.write may write fewer bytes than asked (or fail on a full disk); the return
    /// value was ignored before and produced a truncated ZIP that failed later with an opaque error.
    private static func writeAll(_ bytes: [UInt8], to stream: OutputStream) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return stream.write(base, maxLength: ptr.count)
            }
            if written <= 0 {
                throw stream.streamError ?? DownloadError.writeFailed
            }
            offset += written
        }
    }
}
