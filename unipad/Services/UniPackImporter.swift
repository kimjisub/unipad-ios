import Foundation
import Compression
import os.log

actor UniPackImporter {
    enum ImportError: LocalizedError {
        case emptyZip
        case criticalError(String)
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyZip: return "ZIP file is empty"
            case .criticalError(let msg): return "Critical error: \(msg)"
            case .extractionFailed(let msg): return "Extraction failed: \(msg)"
            }
        }
    }

    enum ImportState: Sendable {
        case idle
        case importing
        case completed(URL)
        case failed(String)
    }

    protocol Delegate: AnyObject, Sendable {
        @MainActor func onImportStart()
        @MainActor func onImportComplete(folder: URL)
        @MainActor func onImportError(_ error: Error)
    }

    private let logger = Logger(subsystem: "com.kimjisub.unipad", category: "Importer")

    /// Import a UniPack from a local file URL (ZIP).
    func importPack(from sourceURL: URL, to workspace: URL, delegate: Delegate?) async {
        let fileName = sourceURL.deletingPathExtension().lastPathComponent
        let targetFolder = FileManagerExtensions.makeNextPath(dir: workspace, name: fileName, extension: "")

        await delegate?.onImportStart()

        do {
            let fm = FileManager.default
            try fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)

            // Copy source to temp location for extraction
            let tempZip = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            defer { try? fm.removeItem(at: tempZip) }

            try fm.copyItem(at: sourceURL, to: tempZip)

            try extractZip(at: tempZip, to: targetFolder)

            FileManagerExtensions.removeDoubleFolder(at: targetFolder)

            // Validate the extracted unipack
            let unipack = UniPackFolder(rootFolder: targetFolder)
            unipack.loadDetail()
            if unipack.criticalError {
                FileManagerExtensions.deleteDirectory(at: targetFolder)
                throw ImportError.criticalError(unipack.errorDetail ?? "Invalid unipack structure")
            }

            await delegate?.onImportComplete(folder: targetFolder)
            logger.info("Import completed: \(targetFolder.lastPathComponent)")

        } catch {
            logger.error("Import failed: \(error.localizedDescription)")
            FileManagerExtensions.deleteDirectory(at: targetFolder)
            await delegate?.onImportError(error)
        }
    }

    /// Import from Data (e.g., from share sheet or document picker)
    func importPack(data: Data, fileName: String, to workspace: URL, delegate: Delegate?) async {
        let fm = FileManager.default
        let tempZip = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")

        do {
            try data.write(to: tempZip)
            await importPack(from: tempZip, to: workspace, delegate: delegate)
        } catch {
            logger.error("Failed to write temp ZIP: \(error.localizedDescription)")
            await delegate?.onImportError(error)
        }

        try? fm.removeItem(at: tempZip)
    }

    /// Extract a ZIP file without import validation (used by UniPackDownloader)
    func extractOnly(at zipURL: URL, to destination: URL) throws {
        try extractZip(at: zipURL, to: destination)
    }

    // MARK: - ZIP Extraction

    /// Uses Compression framework for ZIP extraction on all Apple platforms.
    private func extractZip(at zipURL: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.unzipItem(at: zipURL, to: destination)
    }
}

// MARK: - FileManager ZIP Extension

extension FileManager {
    /// ZIP extraction using zlib (available on all Apple platforms).
    /// Parses central directory entries first (like zip tools) to support data-descriptor ZIPs.
    func unzipItem(at sourceURL: URL, to destinationURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)

        func readUInt16LE(at offset: Int) -> UInt16? {
            guard offset >= 0, offset + 2 <= data.count else { return nil }
            let b0 = UInt16(data[offset])
            let b1 = UInt16(data[offset + 1]) << 8
            return b0 | b1
        }

        func readUInt32LE(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1]) << 8
            let b2 = UInt32(data[offset + 2]) << 16
            let b3 = UInt32(data[offset + 3]) << 24
            return b0 | b1 | b2 | b3
        }

        let maxEOCDSearch = min(data.count, 66_000)
        let eocdStart = data.count - maxEOCDSearch
        var eocdOffset: Int?
        if data.count >= 22 {
            var i = data.count - 22
            while i >= eocdStart {
                if readUInt32LE(at: i) == 0x0605_4B50 {
                    eocdOffset = i
                    break
                }
                i -= 1
            }
        }
        guard let eocdOffset else {
            throw UniPackImporter.ImportError.extractionFailed("EOCD not found")
        }

        guard
            let totalEntriesU16 = readUInt16LE(at: eocdOffset + 10),
            let centralDirSizeU32 = readUInt32LE(at: eocdOffset + 12),
            let centralDirOffsetU32 = readUInt32LE(at: eocdOffset + 16)
        else {
            throw UniPackImporter.ImportError.extractionFailed("Invalid EOCD")
        }

        let totalEntries = Int(totalEntriesU16)
        let centralDirSize = Int(centralDirSizeU32)
        let centralDirOffset = Int(centralDirOffsetU32)
        guard centralDirOffset >= 0, centralDirSize >= 0, centralDirOffset + centralDirSize <= data.count else {
            throw UniPackImporter.ImportError.extractionFailed("Invalid central directory range")
        }

        struct Entry {
            let fileName: String
            let compressionMethod: UInt16
            let compressedSize: Int
            let uncompressedSize: Int
            let localHeaderOffset: Int
        }

        var entries: [Entry] = []
        var cursor = centralDirOffset
        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count, readUInt32LE(at: cursor) == 0x0201_4B50 else { break }

            guard
                let compressionMethod = readUInt16LE(at: cursor + 10),
                let compressedSizeU32 = readUInt32LE(at: cursor + 20),
                let uncompressedSizeU32 = readUInt32LE(at: cursor + 24),
                let fileNameLengthU16 = readUInt16LE(at: cursor + 28),
                let extraLengthU16 = readUInt16LE(at: cursor + 30),
                let commentLengthU16 = readUInt16LE(at: cursor + 32),
                let localHeaderOffsetU32 = readUInt32LE(at: cursor + 42)
            else {
                throw UniPackImporter.ImportError.extractionFailed("Corrupted central directory entry")
            }

            let fileNameLength = Int(fileNameLengthU16)
            let extraLength = Int(extraLengthU16)
            let commentLength = Int(commentLengthU16)
            let localHeaderOffset = Int(localHeaderOffsetU32)
            let fileNameStart = cursor + 46
            let fileNameEnd = fileNameStart + fileNameLength
            guard fileNameEnd <= data.count else {
                throw UniPackImporter.ImportError.extractionFailed("Invalid entry filename range")
            }

            let rawName = data[fileNameStart..<fileNameEnd]
            let fileName = String(data: rawName, encoding: .utf8)
                ?? String(data: rawName, encoding: .isoLatin1)
                ?? ""
            if !fileName.isEmpty {
                entries.append(Entry(
                    fileName: fileName,
                    compressionMethod: compressionMethod,
                    compressedSize: Int(compressedSizeU32),
                    uncompressedSize: Int(uncompressedSizeU32),
                    localHeaderOffset: localHeaderOffset
                ))
            }

            cursor = fileNameEnd + extraLength + commentLength
        }

        for entry in entries {
            // Prevent path traversal and absolute-path extraction.
            if entry.fileName.hasPrefix("/") || entry.fileName.contains("..") {
                continue
            }

            let entryPath = destinationURL.appendingPathComponent(entry.fileName)
            if entry.fileName.hasSuffix("/") {
                try createDirectory(at: entryPath, withIntermediateDirectories: true)
                continue
            }

            let localHeader = entry.localHeaderOffset
            guard localHeader + 30 <= data.count, readUInt32LE(at: localHeader) == 0x0403_4B50 else {
                throw UniPackImporter.ImportError.extractionFailed("Invalid local header for \(entry.fileName)")
            }
            guard
                let localNameLength = readUInt16LE(at: localHeader + 26),
                let localExtraLength = readUInt16LE(at: localHeader + 28)
            else {
                throw UniPackImporter.ImportError.extractionFailed("Invalid local header lengths for \(entry.fileName)")
            }

            let dataStart = localHeader + 30 + Int(localNameLength) + Int(localExtraLength)
            let dataEnd = dataStart + entry.compressedSize
            guard dataStart >= 0, dataEnd <= data.count else {
                throw UniPackImporter.ImportError.extractionFailed("Compressed data out of bounds for \(entry.fileName)")
            }

            let parentDir = entryPath.deletingLastPathComponent()
            if !fileExists(atPath: parentDir.path) {
                try createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            let compressedData = data[dataStart..<dataEnd]
            if entry.compressionMethod == 0 {
                try Data(compressedData).write(to: entryPath)
            } else if entry.compressionMethod == 8 {
                let decompressed = try decompressDeflate(Data(compressedData), expectedSize: entry.uncompressedSize)
                try decompressed.write(to: entryPath)
            } else {
                throw UniPackImporter.ImportError.extractionFailed(
                    "Unsupported compression method \(entry.compressionMethod) for \(entry.fileName)"
                )
            }
        }
    }

    /// Decompress deflate data using Apple's Compression framework with dynamic buffer growth
    private func decompressDeflate(_ compressedData: Data, expectedSize: Int) throws -> Data {
        var bufferSize = max(expectedSize, 65536)

        while true {
            let destBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            let decompressedSize = compressedData.withUnsafeBytes { srcPtr -> Int in
                guard let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(
                    destBuffer, bufferSize,
                    srcBase, compressedData.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }

            if decompressedSize == 0 {
                destBuffer.deallocate()
                throw UniPackImporter.ImportError.extractionFailed("Decompression failed")
            }

            if decompressedSize < bufferSize {
                let result = Data(bytes: destBuffer, count: decompressedSize)
                destBuffer.deallocate()
                return result
            }

            // Buffer was fully used — data may have been truncated; retry with larger buffer
            destBuffer.deallocate()
            bufferSize *= 2
        }
    }
}
