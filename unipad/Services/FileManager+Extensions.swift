import Foundation
import os.log

nonisolated enum FileManagerExtensions {
    private static let logger = Logger(subsystem: "com.kimjisub.unipad", category: "FileManager")
    private static let copyBufferSize = 4096
    private static let bytesPerMB: Double = 1024.0 * 1024.0
    private static let filenameFilterRegex = try! NSRegularExpression(pattern: #"[|\\?*<":>/]+"#)

    /// Removes a redundant nested folder (e.g., extracted ZIP that wraps content in a single subfolder).
    /// Throws when an item cannot be moved up: the folder is then only partly unwrapped, and a pack
    /// accepted in that state is missing whatever stayed behind.
    static func removeDoubleFolder(at path: URL) throws {
        try unwrap(at: path) { visible in
            guard visible.count == 1, let single = visible.first, isDirectory(single) else { return nil }
            return single
        }
    }

    /// Unwraps an extracted UniPack to the folder that holds its `info` file. Wrapper folders are
    /// removed as `removeDoubleFolder` does, and files or folders left beside the pack (a readme next
    /// to the pack folder) are ignored as long as exactly one folder at that level leads to an
    /// `info`. Two packs in one archive are left as they are, so the import reports that none is found.
    static func unwrapUniPackFolder(at path: URL) throws {
        try unwrap(at: path, discardSiblings: true) { visible in
            guard !visible.contains(where: { isInfoFile($0) }) else { return nil }
            let folders = visible.filter(isDirectory)
            if visible.count == 1 { return folders.first }
            let leadingToInfo = folders.filter(containsInfoFile)
            return leadingToInfo.count == 1 ? leadingToInfo.first : nil
        }
    }

    /// Moves the contents of the folder `next` picks up into `path`, level by level, until it
    /// picks none. `next` sees the folder's items without Finder's `__MACOSX` sibling and dot files:
    /// every pack zipped on a Mac used to fail to import because the root had two children.
    private static func unwrap(at path: URL, discardSiblings: Bool = false, next: ([URL]) -> URL?) throws {
        while true {
            guard let contents = try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            guard let wrapped = next(contents.filter { !isHiddenFromUnwrap($0) }) else { return }
            // Only the selected pack belongs here. Leaving siblings in place would merge their
            // sounds into the pack or let an outside file satisfy a missing keySound entry.
            if discardSiblings {
                for sibling in contents where sibling != wrapped {
                    try FileManager.default.removeItem(at: sibling)
                }
            }
            try moveDirectory(from: wrapped, to: path)
        }
    }

    private static func isHiddenFromUnwrap(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(".") || url.lastPathComponent == "__MACOSX"
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// The pack reader matches `info` without regard to case.
    private static func isInfoFile(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased() == "info" && !isDirectory(url)
    }

    private static func containsInfoFile(_ folder: URL) -> Bool {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return false }
        for case let item as URL in items {
            if item.lastPathComponent == "__MACOSX" {
                items.skipDescendants()
            } else if isInfoFile(item) {
                return true
            }
        }
        return false
    }

    static func makeNextPath(dir: URL, name: String, extension ext: String) -> URL {
        let filtered = filterFilename(name)
        var i = 1
        while true {
            let candidate = numberedPath(dir: dir, filteredName: filtered, extension: ext, index: i)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            i += 1
        }
    }

    /// Like `makeNextPath`, but creates the empty file or folder in the same step that finds the
    /// name free, so a concurrent caller asking for the same name gets the next number instead.
    /// The caller owns the returned path and is the only one that may delete it.
    static func claimNextPath(dir: URL, name: String, extension ext: String, isDirectory: Bool) throws -> URL {
        let fm = FileManager.default
        return try firstFreePath(dir: dir, name: name, extension: ext) { candidate in
            if isDirectory {
                try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
            } else {
                try Data().write(to: candidate, options: .withoutOverwriting)
            }
        }
    }

    /// Moves `item` to the first free numbered name in `dir` with a single rename that refuses to
    /// replace anything already there, so the destination never holds a partly moved item and a
    /// concurrent caller's claim is never taken over. `item` must be on the same volume as `dir`.
    static func moveToNextFreePath(_ item: URL, dir: URL, name: String, extension ext: String = "") throws -> URL {
        try firstFreePath(dir: dir, name: name, extension: ext) { candidate in
            guard renamex_np(item.path, candidate.path, UInt32(RENAME_EXCL)) == 0 else {
                let code = errno
                if code == EEXIST { throw CocoaError(.fileWriteFileExists) }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
    }

    /// Runs `take` on `name`, `name (2)`, `name (3)`, ... until it does not fail with "file exists".
    private static func firstFreePath(dir: URL, name: String, extension ext: String, take: (URL) throws -> Void) throws -> URL {
        let filtered = filterFilename(name)
        var i = 1
        while true {
            let candidate = numberedPath(dir: dir, filteredName: filtered, extension: ext, index: i)
            do {
                try take(candidate)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                i += 1
            }
        }
    }

    private static func numberedPath(dir: URL, filteredName: String, extension ext: String, index: Int) -> URL {
        let fileName = index == 1 ? filteredName + ext : "\(filteredName) (\(index))\(ext)"
        return dir.appendingPathComponent(fileName)
    }

    static func filterFilename(_ original: String) -> String {
        let range = NSRange(original.startIndex..., in: original)
        return filenameFilterRegex.stringByReplacingMatches(in: original, range: range, withTemplate: "")
    }

    /// Moves the contents of `source` into `target` and removes `source`. Directories that exist
    /// on both sides are merged (as Android's FileManager.moveDirectory does); an item whose
    /// destination is `source` itself (including another spelling on a case-insensitive disk) is
    /// parked beside the tree and moved in after `source` is gone. The old version deleted the destination first, which for
    /// that layout deleted the source subtree and destroyed the pack being imported.
    static func moveDirectory(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        let sourcePath = source.standardizedFileURL.path
        guard sourcePath != target.standardizedFileURL.path, !sameFile(source, target) else { return }
        do {
            let sourceContents = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])

            var deferred: [(parked: URL, dest: URL)] = []
            for item in sourceContents {
                let dest = target.appendingPathComponent(item.lastPathComponent)
                // The simulator can report a differently cased alias as missing but still
                // refuse the move because that alias is the source. Parking a possible alias
                // is safe on case-sensitive disks too, and avoids relying on that lookup.
                if dest.standardizedFileURL.path.lowercased() == sourcePath.lowercased() || sameFile(source, dest) {
                    let parked = target.appendingPathComponent(".unipad-move-" + UUID().uuidString)
                    try fm.moveItem(at: item, to: parked)
                    deferred.append((parked: parked, dest: dest))
                    continue
                }
                var destIsDir: ObjCBool = false
                let destExists = fm.fileExists(atPath: dest.path, isDirectory: &destIsDir)
                let itemIsDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if destExists && destIsDir.boolValue && itemIsDir {
                    try moveDirectory(from: item, to: dest)
                    continue
                }
                if destExists {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: item, to: dest)
            }

            try fm.removeItem(at: source)
            for entry in deferred {
                try fm.moveItem(at: entry.parked, to: entry.dest)
            }
        } catch {
            logger.error("moveDirectory failed: \(error.localizedDescription)")
            throw error
        }
    }

    private static func sameFile(_ first: URL, _ second: URL) -> Bool {
        guard let lhs = try? FileManager.default.attributesOfItem(atPath: first.path),
              let rhs = try? FileManager.default.attributesOfItem(atPath: second.path),
              let leftDevice = lhs[.systemNumber] as? NSNumber,
              let rightDevice = rhs[.systemNumber] as? NSNumber,
              let leftFile = lhs[.systemFileNumber] as? NSNumber,
              let rightFile = rhs[.systemFileNumber] as? NSNumber else { return false }
        return leftDevice == rightDevice && leftFile == rightFile
    }

    static func copyDirectory(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let contents = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for item in contents {
                try copyDirectory(from: item, to: target.appendingPathComponent(item.lastPathComponent))
            }
        } else {
            try fm.copyItem(at: source, to: target)
        }
    }

    static func ensureDirectoryExists(at url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func byteToMB(_ bytes: Int64, format: String = "%.2f") -> String {
        String(format: format, Double(bytes) / bytesPerMB)
    }

    static func getFolderSize(at url: URL) async -> Int64 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let size = calculateFolderSize(at: url)
                continuation.resume(returning: size)
            }
        }
    }

    private static func calculateFolderSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }

        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return contents.reduce(0) { $0 + calculateFolderSize(at: $1) }
    }

    /// Returns the inner file last modified date for sorting purposes
    static func getInnerFileLastModified(at url: URL) -> Date {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return .distantPast
        }
        for item in contents {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), !isDir.boolValue {
                let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return date
            }
        }
        return .distantPast
    }

    static func sortByTime(_ urls: [URL]) -> [URL] {
        urls.sorted { getInnerFileLastModified(at: $0) > getInnerFileLastModified(at: $1) }
    }
}
