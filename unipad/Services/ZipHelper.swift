import Foundation
import Compression

enum ZipHelper {
    enum ZipError: LocalizedError {
        case compressionFailed(String)
        case directoryNotFound(String)

        var errorDescription: String? {
            switch self {
            case .compressionFailed(let msg): return "Compression failed: \(msg)"
            case .directoryNotFound(let path): return "Directory not found: \(path)"
            }
        }
    }

    /// Create a ZIP archive from a directory.
    static func zipDirectory(source: URL, destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw ZipError.directoryNotFound(source.path)
        }

        var zipData = Data()
        var entries: [(name: String, localHeaderOffset: Int, crc32: UInt32, compressedSize: Int, uncompressedSize: Int)] = []

        let basePath = source.path
        let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])

        while let fileURL = enumerator?.nextObject() as? URL {
            let relativePath = String(fileURL.path.dropFirst(basePath.count + 1))
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            let entryName = isDirectory ? relativePath + "/" : relativePath
            let nameData = Data(entryName.utf8)

            let localHeaderOffset = zipData.count

            if isDirectory {
                // Local file header for directory
                writeLocalFileHeader(to: &zipData, nameData: nameData, crc32: 0, compressedSize: 0, uncompressedSize: 0)
                entries.append((name: entryName, localHeaderOffset: localHeaderOffset, crc32: 0, compressedSize: 0, uncompressedSize: 0))
            } else {
                let fileData = try Data(contentsOf: fileURL)
                let crc = crc32Checksum(fileData)
                let compressed = compressDeflate(fileData)

                // Use deflate only if it actually saves space
                if let compressed, compressed.count < fileData.count {
                    writeLocalFileHeader(to: &zipData, nameData: nameData, crc32: crc, compressedSize: compressed.count, uncompressedSize: fileData.count, method: 8)
                    zipData.append(compressed)
                    entries.append((name: entryName, localHeaderOffset: localHeaderOffset, crc32: crc, compressedSize: compressed.count, uncompressedSize: fileData.count))
                } else {
                    writeLocalFileHeader(to: &zipData, nameData: nameData, crc32: crc, compressedSize: fileData.count, uncompressedSize: fileData.count, method: 0)
                    zipData.append(fileData)
                    entries.append((name: entryName, localHeaderOffset: localHeaderOffset, crc32: crc, compressedSize: fileData.count, uncompressedSize: fileData.count))
                }
            }
        }

        // Central directory
        let centralDirOffset = zipData.count
        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let method: UInt16 = (entry.compressedSize != entry.uncompressedSize) ? 8 : 0
            writeCentralDirectoryEntry(to: &zipData, nameData: nameData, crc32: entry.crc32, compressedSize: entry.compressedSize, uncompressedSize: entry.uncompressedSize, localHeaderOffset: entry.localHeaderOffset, method: method)
        }
        let centralDirSize = zipData.count - centralDirOffset

        // End of central directory
        writeEndOfCentralDirectory(to: &zipData, entryCount: entries.count, centralDirSize: centralDirSize, centralDirOffset: centralDirOffset)

        try zipData.write(to: destination)
    }

    // MARK: - ZIP Structure Writers

    private static func writeLocalFileHeader(to data: inout Data, nameData: Data, crc32: UInt32, compressedSize: Int, uncompressedSize: Int, method: UInt16 = 0) {
        appendUInt32(&data, 0x04034B50) // Local file header signature
        appendUInt16(&data, 20)          // Version needed
        appendUInt16(&data, 0)           // General purpose bit flag
        appendUInt16(&data, method)      // Compression method
        appendUInt16(&data, 0)           // Last mod file time
        appendUInt16(&data, 0)           // Last mod file date
        appendUInt32(&data, crc32)
        appendUInt32(&data, UInt32(compressedSize))
        appendUInt32(&data, UInt32(uncompressedSize))
        appendUInt16(&data, UInt16(nameData.count))
        appendUInt16(&data, 0)           // Extra field length
        data.append(nameData)
    }

    private static func writeCentralDirectoryEntry(to data: inout Data, nameData: Data, crc32: UInt32, compressedSize: Int, uncompressedSize: Int, localHeaderOffset: Int, method: UInt16 = 0) {
        appendUInt32(&data, 0x02014B50) // Central directory header signature
        appendUInt16(&data, 20)          // Version made by
        appendUInt16(&data, 20)          // Version needed
        appendUInt16(&data, 0)           // General purpose bit flag
        appendUInt16(&data, method)      // Compression method
        appendUInt16(&data, 0)           // Last mod file time
        appendUInt16(&data, 0)           // Last mod file date
        appendUInt32(&data, crc32)
        appendUInt32(&data, UInt32(compressedSize))
        appendUInt32(&data, UInt32(uncompressedSize))
        appendUInt16(&data, UInt16(nameData.count))
        appendUInt16(&data, 0)           // Extra field length
        appendUInt16(&data, 0)           // File comment length
        appendUInt16(&data, 0)           // Disk number start
        appendUInt16(&data, 0)           // Internal file attributes
        appendUInt32(&data, 0)           // External file attributes
        appendUInt32(&data, UInt32(localHeaderOffset))
        data.append(nameData)
    }

    private static func writeEndOfCentralDirectory(to data: inout Data, entryCount: Int, centralDirSize: Int, centralDirOffset: Int) {
        appendUInt32(&data, 0x06054B50) // End of central directory signature
        appendUInt16(&data, 0)           // Disk number
        appendUInt16(&data, 0)           // Disk with central directory
        appendUInt16(&data, UInt16(entryCount))
        appendUInt16(&data, UInt16(entryCount))
        appendUInt32(&data, UInt32(centralDirSize))
        appendUInt32(&data, UInt32(centralDirOffset))
        appendUInt16(&data, 0)           // Comment length
    }

    // MARK: - Helpers

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var le = value.littleEndian
        data.append(Data(bytes: &le, count: 2))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        data.append(Data(bytes: &le, count: 4))
    }

    private static func compressDeflate(_ input: Data) -> Data? {
        let bufferSize = max(input.count, 64)
        let destBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destBuffer.deallocate() }

        let compressedSize = input.withUnsafeBytes { srcPtr -> Int in
            guard let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_encode_buffer(
                destBuffer, bufferSize,
                srcBase, input.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard compressedSize > 0 else { return nil }
        return Data(bytes: destBuffer, count: compressedSize)
    }

    private static func crc32Checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        let polynomial: UInt32 = 0xEDB88320

        data.withUnsafeBytes { buffer in
            guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<data.count {
                crc ^= UInt32(bytes[i])
                for _ in 0..<8 {
                    if crc & 1 != 0 {
                        crc = (crc >> 1) ^ polynomial
                    } else {
                        crc >>= 1
                    }
                }
            }
        }

        return crc ^ 0xFFFFFFFF
    }
}
