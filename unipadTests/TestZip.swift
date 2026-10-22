import Compression
import Foundation

/// Builds a ZIP archive in memory.
enum TestZip {
    /// An uncompressed (stored) archive. `corruptingSizeOf` declares that entry's size past the end
    /// of the archive, so extraction fails on it after writing the entries before it.
    static func stored(_ files: [(name: String, data: Data)], corruptingSizeOf corrupted: String? = nil) -> Data {
        archive(files, deflated: false, corruptingSizeOf: corrupted)
    }

    /// A deflate-compressed archive, much smaller than its contents when they repeat (silence).
    static func deflated(_ files: [(name: String, data: Data)]) -> Data {
        archive(files, deflated: true, corruptingSizeOf: nil)
    }

    /// Raw entry names and flags, independent of the text encoding of each file's contents. `extras`
    /// holds each entry's extra field, written to both its local and central headers.
    static func storedRawNames(_ files: [(name: Data, data: Data)], utf8Flag: Bool, extras: [Data]? = nil) -> Data {
        archive(files.enumerated().map { (name: String($0.offset), data: $0.element.data) },
                deflated: false, corruptingSizeOf: nil,
                rawNames: files.map(\.name), extras: extras, flags: utf8Flag ? 0x0800 : 0)
    }

    /// An Info-ZIP Unicode Path extra field (0x7075) naming `name` for the raw name `rawName`.
    static func unicodePathExtra(_ name: String, rawName: Data, crcOf crcName: Data? = nil) -> Data {
        let body = Data([1]) + le32(crc32(crcName ?? rawName)) + Data(name.utf8)
        return le16(0x7075) + le16(UInt16(body.count)) + body
    }

    private static func archive(_ files: [(name: String, data: Data)], deflated: Bool, corruptingSizeOf corrupted: String?,
                                rawNames: [Data]? = nil, extras: [Data]? = nil, flags: UInt16 = 0x0800) -> Data {
        var archive = Data()
        var centralDirectory = Data()
        let method: UInt16 = deflated ? 8 : 0

        for (index, file) in files.enumerated() {
            let name = rawNames?[index] ?? Data(file.name.utf8)
            let extra = extras?[index] ?? Data()
            let crc = crc32(file.data)
            let body = deflated ? deflate(file.data) : file.data
            let size = UInt32(file.data.count)
            let compressedSize = UInt32(body.count)
            let declaredSize = file.name == corrupted ? UInt32.max / 2 : compressedSize
            let localHeaderOffset = UInt32(archive.count)

            archive.append(le32(0x0403_4B50))
            archive.append(le16(20)); archive.append(le16(flags)); archive.append(le16(method))
            archive.append(le16(0)); archive.append(le16(0))
            archive.append(le32(crc)); archive.append(le32(compressedSize)); archive.append(le32(size))
            archive.append(le16(UInt16(name.count))); archive.append(le16(UInt16(extra.count)))
            archive.append(name)
            archive.append(extra)
            archive.append(body)

            centralDirectory.append(le32(0x0201_4B50))
            centralDirectory.append(le16(20)); centralDirectory.append(le16(20))
            centralDirectory.append(le16(flags)); centralDirectory.append(le16(method))
            centralDirectory.append(le16(0)); centralDirectory.append(le16(0))
            centralDirectory.append(le32(crc)); centralDirectory.append(le32(declaredSize))
            centralDirectory.append(le32(file.name == corrupted ? declaredSize : size))
            centralDirectory.append(le16(UInt16(name.count)))
            centralDirectory.append(le16(UInt16(extra.count))); centralDirectory.append(le16(0))
            centralDirectory.append(le16(0)); centralDirectory.append(le16(0))
            centralDirectory.append(le32(0))
            centralDirectory.append(le32(localHeaderOffset))
            centralDirectory.append(name)
            centralDirectory.append(extra)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.append(le32(0x0605_4B50))
        archive.append(le16(0)); archive.append(le16(0))
        archive.append(le16(UInt16(files.count))); archive.append(le16(UInt16(files.count)))
        archive.append(le32(UInt32(centralDirectory.count))); archive.append(le32(centralDirectoryOffset))
        archive.append(le16(0))
        return archive
    }

    /// Raw DEFLATE, the form ZIP stores and `COMPRESSION_ZLIB` reads and writes.
    private static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        precondition(written > 0, "deflate failed")
        return output.prefix(written)
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return ~crc
    }
}
