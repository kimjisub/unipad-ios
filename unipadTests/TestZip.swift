import Foundation

/// Builds an uncompressed (stored) ZIP archive in memory.
enum TestZip {
    /// `corruptingSizeOf` declares that entry's size past the end of the archive, so extraction
    /// fails on it after writing the entries before it.
    static func stored(_ files: [(name: String, data: Data)], corruptingSizeOf corrupted: String? = nil) -> Data {
        var archive = Data()
        var centralDirectory = Data()

        for file in files {
            let name = Data(file.name.utf8)
            let crc = crc32(file.data)
            let size = UInt32(file.data.count)
            let declaredSize = file.name == corrupted ? UInt32.max / 2 : size
            let localHeaderOffset = UInt32(archive.count)

            archive.append(le32(0x0403_4B50))
            archive.append(le16(20)); archive.append(le16(0x0800)); archive.append(le16(0))
            archive.append(le16(0)); archive.append(le16(0))
            archive.append(le32(crc)); archive.append(le32(size)); archive.append(le32(size))
            archive.append(le16(UInt16(name.count))); archive.append(le16(0))
            archive.append(name)
            archive.append(file.data)

            centralDirectory.append(le32(0x0201_4B50))
            centralDirectory.append(le16(20)); centralDirectory.append(le16(20))
            centralDirectory.append(le16(0x0800)); centralDirectory.append(le16(0))
            centralDirectory.append(le16(0)); centralDirectory.append(le16(0))
            centralDirectory.append(le32(crc)); centralDirectory.append(le32(declaredSize)); centralDirectory.append(le32(declaredSize))
            centralDirectory.append(le16(UInt16(name.count)))
            centralDirectory.append(le16(0)); centralDirectory.append(le16(0))
            centralDirectory.append(le16(0)); centralDirectory.append(le16(0))
            centralDirectory.append(le32(0))
            centralDirectory.append(le32(localHeaderOffset))
            centralDirectory.append(name)
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
