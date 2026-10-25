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

    /// A deflate-compressed archive whose central directory declares `declaredSize` as every
    /// entry's uncompressed size, as a corrupt or carelessly written archive may.
    static func deflated(_ files: [(name: String, data: Data)], declaringUncompressedSize declaredSize: UInt32) -> Data {
        archive(files, deflated: true, corruptingSizeOf: nil, declaredUncompressedSize: declaredSize)
    }

    /// A deflated archive of one entry of `count` copies of `byte`, encoded in chunks so a test of
    /// an entry of hundreds of megabytes never holds it whole. Its CRC is zero; nothing checks it.
    static func deflatedRepeating(_ byte: UInt8, count: Int, name: String) -> Data {
        let body = deflate(repeating: byte, count: count)
        return build([Entry(name: Data(name.utf8), extra: Data(), body: body, method: 8, crc: 0, size: UInt32(count),
                            declaredCompressedSize: UInt32(body.count), declaredSize: UInt32(count))], flags: 0x0800)
    }

    /// Raw entry names and flags, independent of the text encoding of each file's contents.
    static func storedRawNames(_ files: [(name: Data, data: Data)], utf8Flag: Bool, extras: [Data]? = nil) -> Data {
        archive(files.enumerated().map { (name: String($0.offset), data: $0.element.data) },
                deflated: false, corruptingSizeOf: nil,
                rawNames: files.map(\.name), extras: extras, flags: utf8Flag ? 0x0800 : 0)
    }

    /// An Info-ZIP Unicode Path field for the original raw entry name.
    static func unicodePathExtra(_ name: String, rawName: Data, crcOf crcName: Data? = nil) -> Data {
        let body = Data([1]) + le32(crc32(crcName ?? rawName)) + Data(name.utf8)
        return le16(0x7075) + le16(UInt16(body.count)) + body
    }

    private struct Entry {
        let name: Data
        let extra: Data
        let body: Data
        let method: UInt16
        let crc: UInt32
        let size: UInt32
        let declaredCompressedSize: UInt32
        let declaredSize: UInt32
    }

    private static func archive(_ files: [(name: String, data: Data)], deflated: Bool, corruptingSizeOf corrupted: String?,
                                rawNames: [Data]? = nil, extras: [Data]? = nil, flags: UInt16 = 0x0800,
                                declaredUncompressedSize: UInt32? = nil) -> Data {
        let entries = files.enumerated().map { index, file in
            let body = deflated ? deflate(file.data) : file.data
            let corrupt = file.name == corrupted
            return Entry(
                name: rawNames?[index] ?? Data(file.name.utf8), extra: extras?[index] ?? Data(), body: body, method: deflated ? 8 : 0,
                crc: crc32(file.data), size: UInt32(file.data.count),
                declaredCompressedSize: corrupt ? UInt32.max / 2 : UInt32(body.count),
                declaredSize: corrupt ? UInt32.max / 2 : declaredUncompressedSize ?? UInt32(file.data.count)
            )
        }
        return build(entries, flags: flags)
    }

    private static func build(_ entries: [Entry], flags: UInt16) -> Data {
        var archive = Data()
        var centralDirectory = Data()

        for entry in entries {
            let localHeaderOffset = UInt32(archive.count)

            archive.append(le32(0x0403_4B50))
            archive.append(le16(20)); archive.append(le16(flags)); archive.append(le16(entry.method))
            archive.append(le16(0)); archive.append(le16(0))
            archive.append(le32(entry.crc)); archive.append(le32(UInt32(entry.body.count))); archive.append(le32(entry.size))
            archive.append(le16(UInt16(entry.name.count))); archive.append(le16(UInt16(entry.extra.count)))
            archive.append(entry.name)
            archive.append(entry.extra)
            archive.append(entry.body)

            centralDirectory.append(le32(0x0201_4B50))
            centralDirectory.append(le16(20)); centralDirectory.append(le16(20))
            centralDirectory.append(le16(flags)); centralDirectory.append(le16(entry.method))
            centralDirectory.append(le16(0)); centralDirectory.append(le16(0))
            centralDirectory.append(le32(entry.crc)); centralDirectory.append(le32(entry.declaredCompressedSize))
            centralDirectory.append(le32(entry.declaredSize))
            centralDirectory.append(le16(UInt16(entry.name.count)))
            centralDirectory.append(le16(UInt16(entry.extra.count))); centralDirectory.append(le16(0))
            centralDirectory.append(le16(0)); centralDirectory.append(le16(0))
            centralDirectory.append(le32(0))
            centralDirectory.append(le32(localHeaderOffset))
            centralDirectory.append(entry.name)
            centralDirectory.append(entry.extra)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.append(le32(0x0605_4B50))
        archive.append(le16(0)); archive.append(le16(0))
        archive.append(le16(UInt16(entries.count))); archive.append(le16(UInt16(entries.count)))
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

    private static func deflate(repeating byte: UInt8, count: Int) -> Data {
        let chunk = [UInt8](repeating: byte, count: 1 << 20)
        var output = [UInt8](repeating: 0, count: 1 << 16)
        var result = Data()
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        precondition(compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK)
        defer { compression_stream_destroy(stream) }
        var remaining = count
        chunk.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                var status = COMPRESSION_STATUS_OK
                while status == COMPRESSION_STATUS_OK {
                    if stream.pointee.src_size == 0, remaining > 0 {
                        stream.pointee.src_ptr = input.baseAddress!
                        stream.pointee.src_size = min(remaining, input.count)
                        remaining -= stream.pointee.src_size
                    }
                    stream.pointee.dst_ptr = out.baseAddress!
                    stream.pointee.dst_size = out.count
                    let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    status = compression_stream_process(stream, flags)
                    result.append(out.baseAddress!, count: out.count - stream.pointee.dst_size)
                }
                precondition(status == COMPRESSION_STATUS_END, "deflate failed")
            }
        }
        return result
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
