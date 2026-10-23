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
    private let stagingRoot: URL

    init(stagingRoot: URL = UniPackStaging.defaultRoot) {
        self.stagingRoot = stagingRoot
    }

    /// Import a UniPack from a local file URL (ZIP). Errors reach the delegate and are rethrown, so
    /// a caller that has no delegate (TransferView) can still tell a failure from a success.
    /// The pack is built in a staging folder and enters the library only once it is complete.
    @discardableResult
    func importPack(from sourceURL: URL, to workspace: URL, delegate: Delegate?) async throws -> URL {
        try await importPack(from: sourceURL, named: Self.folderName(forArchiveNamed: sourceURL.lastPathComponent),
                             to: workspace, delegate: delegate)
    }

    private func importPack(from sourceURL: URL, named folderName: String, to workspace: URL, delegate: Delegate?) async throws -> URL {
        await delegate?.onImportStart()

        var staging: UniPackStaging?
        defer { staging?.discard() }

        do {
            let staged = try UniPackStaging(root: stagingRoot)
            staging = staged

            let archive = staged.file(named: "import.zip")
            try FileManager.default.copyItem(at: sourceURL, to: archive)

            try extractZip(at: archive, to: staged.packFolder)

            try FileManagerExtensions.unwrapUniPackFolder(at: staged.packFolder)

            // Validate the extracted unipack. load() runs checkFile + parseInfo; without it
            // loadDetail parsed nothing and criticalError was never set, so any ZIP passed.
            let unipack = UniPackFolder(rootFolder: staged.packFolder)
            unipack.load()
            unipack.loadDetail()
            if unipack.criticalError {
                throw ImportError.criticalError(unipack.errorDetail ?? "Invalid unipack structure")
            }

            // A download or another import of the same name may finish meanwhile; publishing takes
            // the next free name instead of replacing it.
            let targetFolder = try staged.publish(to: workspace, name: folderName)

            await delegate?.onImportComplete(folder: targetFolder)
            logger.info("Import completed: \(targetFolder.lastPathComponent)")
            return targetFolder

        } catch {
            logger.error("Import failed: \(error.localizedDescription)")
            await delegate?.onImportError(error)
            throw error
        }
    }

    /// Import an archive held in memory. Files the user picks or opens in UniPad are imported
    /// from their location instead, so a pack of hundreds of megabytes is never read into memory.
    @discardableResult
    func importPack(data: Data, fileName: String, to workspace: URL, delegate: Delegate?) async throws -> URL {
        var staging: UniPackStaging?
        defer { staging?.discard() }

        let archive: URL
        do {
            let staged = try UniPackStaging(root: stagingRoot)
            staging = staged
            archive = staged.file(named: "received.zip")
            try data.write(to: archive)
        } catch {
            logger.error("Failed to write temp ZIP: \(error.localizedDescription)")
            await delegate?.onImportError(error)
            throw error
        }
        return try await importPack(from: archive, named: Self.folderName(forArchiveNamed: fileName),
                                    to: workspace, delegate: delegate)
    }

    /// The library folder for an archive the user named: its name without the extension, reduced
    /// to one folder name inside the library. The library is shown in the Files app, so the folder
    /// keeps the name the user knows the pack by.
    static func folderName(forArchiveNamed fileName: String) -> String {
        // A leading-dot archive such as ".zip" also has no usable stem. NSString treats it
        // as an extensionless hidden file, so remove the final suffix explicitly.
        let stem = fileName.lastIndex(of: ".").map { String(fileName[..<$0]) } ?? fileName
        var name = FileManagerExtensions.filterFilename(stem)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        // Room for the " (2)" a taken name gets, within the file system's 255-byte name limit.
        while name.utf8.count > maxFolderNameBytes { name.removeLast() }
        return name.isEmpty ? fallbackFolderName : name
    }

    private static let maxFolderNameBytes = 200
    static let fallbackFolderName = "UniPack"

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

nonisolated extension FileManager {
    /// The most one entry may unpack to. The sizes an archive records are not trusted, so this is
    /// what bounds an archive that decodes to far more than it claims.
    static let maxZipEntrySize = 512 * 1024 * 1024

    /// ZIP extraction using zlib (available on all Apple platforms).
    /// Parses central directory entries first (like zip tools) to support data-descriptor ZIPs.
    /// Stops between entries when the task is cancelled.
    func unzipItem(at sourceURL: URL, to destinationURL: URL) throws {
        // Mapped: a 300 MB store pack read into memory and re-copied per entry peaked well past
        // twice its size and got the app killed on low-memory devices.
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)

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
        for index in 0..<totalEntries {
            // A list shorter than the end record says means a cut or damaged archive; unpacking the
            // entries that happen to be readable would install part of a pack.
            guard cursor + 46 <= data.count, readUInt32LE(at: cursor) == 0x0201_4B50 else {
                throw UniPackImporter.ImportError.extractionFailed("Central directory ends after \(index) of \(totalEntries) entries")
            }

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
            let extra = data[fileNameEnd..<min(fileNameEnd + extraLength, data.count)]
            let fileName = Self.decodeEntryName(Data(rawName), extra: Data(extra))
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

        var folders = ArchiveFolderNames()
        var soundFiles = ArchiveSoundFiles()
        for entry in entries {
            try Task.checkCancellation()
            guard let path = Self.entryPath(entry.fileName) else { continue }

            let placed = folders.place(path.components, isDirectory: path.isDirectory)
            let entryPath = path.isDirectory ? destinationURL.appendingPathComponent(placed)
                : soundFiles.destination(original: path.components, archiveEntry: entry.fileName, placed: placed,
                                         root: destinationURL, fileManager: self)
            if path.isDirectory {
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
                try compressedData.write(to: entryPath)
            } else if entry.compressionMethod == 8 {
                try inflate(compressedData, declaredSize: entry.uncompressedSize, to: entryPath)
            } else {
                throw UniPackImporter.ImportError.extractionFailed(
                    "Unsupported compression method \(entry.compressionMethod) for \(entry.fileName)"
                )
            }
        }
        try soundFiles.save(in: destinationURL)
    }

    /// Where an entry goes below the destination, or nil for one that must not be written. `\`
    /// separates folders as `/` does (PowerShell 5.1's Compress-Archive and older .NET write it);
    /// leading slashes and `.` are dropped. An entry with a `..` folder is skipped so nothing lands
    /// outside the destination; names that only contain dots (`Faded.../`, `wait...wav`) are kept.
    static func entryPath(_ name: String) -> (components: [String], isDirectory: Bool)? {
        let slashed = name.replacingOccurrences(of: "\\", with: "/")
        var components: [String] = []
        for component in slashed.split(separator: "/") where component != "." {
            if component == ".." { return nil }
            components.append(String(component))
        }
        return components.isEmpty ? nil : (components, slashed.hasSuffix("/"))
    }

    /// The Info-ZIP Unicode Path field (0x7075) when it belongs to this name (its CRC-32 matches the
    /// raw name); otherwise the raw name as UTF-8 when it is valid UTF-8, and as CP949 when it is not,
    /// whatever the UTF-8 flag says: some Korean archivers set the flag on CP949 names. Android and
    /// the web read names the same way.
    private static func decodeEntryName(_ raw: Data, extra: Data) -> String {
        if let unicode = unicodePath(in: extra, of: raw) { return unicode }
        if let utf8 = String(data: raw, encoding: .utf8) { return utf8 }
        return LegacyText.cp949(raw)
    }

    private static func unicodePath(in extra: Data, of raw: Data) -> String? {
        let bytes = [UInt8](extra)
        func uint16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        var offset = 0
        while offset + 4 <= bytes.count {
            let body = offset + 4
            let end = body + uint16(offset + 2)
            guard end <= bytes.count else { return nil }
            if uint16(offset) == 0x7075, end - body >= 5, bytes[body] == 1 {
                let crc = UInt32(uint16(body + 1)) | UInt32(uint16(body + 3)) << 16
                guard crc == crc32(raw), let name = String(bytes: bytes[(body + 5)..<end], encoding: .utf8),
                      !name.isEmpty else { return nil }
                return name
            }
            offset = end
        }
        return nil
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return ~crc
    }

    /// Decodes a deflated entry into `file` one block at a time, so memory use does not grow with
    /// the entry, and stops once the output passes the limit whatever size the archive declared.
    private func inflate(_ compressed: Data, declaredSize: Int, to file: URL) throws {
        let limit = Self.maxZipEntrySize
        guard declaredSize <= limit else {
            throw UniPackImporter.ImportError.extractionFailed("Entry too large (\(declaredSize) bytes)")
        }
        try Data().write(to: file)
        // A zero-byte entry stored with method 8 (an empty autoPlay is common) has nothing to decode.
        guard !compressed.isEmpty else { return }

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw UniPackImporter.ImportError.extractionFailed("Decompression failed")
        }
        defer { compression_stream_destroy(stream) }
        let blockSize = 1 << 20
        let block = UnsafeMutablePointer<UInt8>.allocate(capacity: blockSize)
        defer { block.deallocate() }

        var written = 0
        try compressed.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            stream.pointee.src_ptr = source.baseAddress!.assumingMemoryBound(to: UInt8.self)
            stream.pointee.src_size = source.count
            while true {
                stream.pointee.dst_ptr = block
                stream.pointee.dst_size = blockSize
                let status = compression_stream_process(stream, 0)
                let produced = blockSize - stream.pointee.dst_size
                written += produced
                guard written <= limit else {
                    throw UniPackImporter.ImportError.extractionFailed("Decompressed entry exceeds \(limit) bytes")
                }
                if produced > 0 {
                    try handle.write(contentsOf: Data(bytesNoCopy: block, count: produced, deallocator: .none))
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK where produced > 0 || stream.pointee.src_size > 0:
                    continue
                default:
                    // An error, or all input read without reaching the end of the stream: the data is cut short.
                    throw UniPackImporter.ImportError.extractionFailed("Decompression failed")
                }
            }
        }
    }
}

/// Folders an archive spells in different letter case (`Pack/Sounds/a.wav`, `Pack/sounds/b.wav`) are
/// one folder on the Windows or macOS disk the pack was made on, and two on an iPhone's disk, where the
/// pack then reads only one of them. Each folder keeps the spelling of its first entry.
nonisolated struct ArchiveFolderNames {
    /// Lower-cased composed folder path -> the path as first spelled.
    private var spelled: [String: String] = [:]

    /// The path below the destination for an entry's components.
    mutating func place(_ components: [String], isDirectory: Bool) -> String {
        let folderCount = isDirectory ? components.count : components.count - 1
        var placed = ""
        var insideSounds = false
        for (index, component) in components.enumerated() {
            let path = placed.isEmpty ? component : placed + "/" + component
            guard index < folderCount else { return path }
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            let reserved = insideSounds && component.lowercased() == ImportedSoundPaths.fileName
            let firstSpelling = reserved ? placed + "/.unipad-sound-folder-" + UUID().uuidString : path
            placed = spelled[key] ?? firstSpelling
            spelled[key] = placed
            if component.lowercased() == "sounds" { insideSounds = true }
        }
        return placed
    }
}

/// Keeps every sound entry even when the destination disk merges its spelling with another entry.
/// Each index stays beside its files, so wrapper removal moves them together. Byte keys distinguish
/// canonically equivalent names that Swift String keys merge.
nonisolated struct ArchiveSoundFiles {
    private var directories: [String: [[UInt8]: ImportedSoundPaths.Entry]] = [:]
    private var placedFiles: [[UInt8]: String] = [:]

    mutating func destination(original: [String], archiveEntry: String, placed: String, root: URL, fileManager: FileManager) -> URL {
        let target = root.appendingPathComponent(placed)
        guard original.dropLast().contains(where: { $0.lowercased() == "sounds" }) else { return target }
        let components = placed.split(separator: "/").map(String.init)
        let directory = components.dropLast().joined(separator: "/")
        let name = original.joined(separator: "/")
        let key = Array(name.utf8)
        let parent = root.appendingPathComponent(directory)
        // Repeated entries with the identical original path retain ZIP's last-entry-wins behavior.
        if let existing = placedFiles[key] {
            let stored = existing.split(separator: "/").last.map(String.init) ?? ""
            directories[directory, default: [:]][key] = ImportedSoundPaths.Entry(name: name, stored: stored,
                                                                              archiveEntry: archiveEntry)
            return root.appendingPathComponent(existing)
        }

        var stored = components.last ?? ""
        let reserved = stored.lowercased() == ImportedSoundPaths.fileName
        if reserved || fileManager.fileExists(atPath: target.path) {
            let ext = target.pathExtension
            stored = ".unipad-sound-" + UUID().uuidString
            // The original filename can fit while the UUID prefix plus its extension does not.
            // Preserve a whole extension only when the decomposed filename still fits on disk.
            if !ext.isEmpty, stored.utf8.count + 1 + ext.decomposedStringWithCanonicalMapping.utf8.count <= 255 {
                stored += "." + ext
            }
        }
        directories[directory, default: [:]][key] = ImportedSoundPaths.Entry(name: name, stored: stored,
                                                                          archiveEntry: archiveEntry)
        placedFiles[key] = directory + "/" + stored
        return parent.appendingPathComponent(stored)
    }

    func save(in root: URL) throws {
        for (directory, entries) in directories {
            // Plain ASCII names already survive unchanged on disk. Keep ordinary imports free of
            // extra files; only a spelling the filesystem cannot preserve needs a catalog.
            let needsCatalog = entries.values.contains { entry in
                !entry.name.utf8.allSatisfy({ $0 < 0x80 })
                    || entry.name != directory + "/" + entry.stored
                    || entry.archiveEntry != entry.name
            }
            guard needsCatalog else { continue }
            try ImportedSoundPaths.write(Array(entries.values), in: root.appendingPathComponent(directory))
        }
    }
}
