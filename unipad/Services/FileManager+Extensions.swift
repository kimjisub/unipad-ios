import Foundation
import os.log

enum FileManagerExtensions {
    private static let logger = Logger(subsystem: "com.kimjisub.unipad", category: "FileManager")
    private static let copyBufferSize = 4096
    private static let bytesPerMB: Double = 1024.0 * 1024.0
    private static let filenameFilterRegex = try! NSRegularExpression(pattern: #"[|\\?*<":>/]+"#)

    /// Removes a redundant nested folder (e.g., extracted ZIP that wraps content in a single subfolder)
    static func removeDoubleFolder(at path: URL) {
        let fm = FileManager.default
        var current = path
        while true {
            guard let contents = try? fm.contentsOfDirectory(at: current, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            let nonHidden = contents.filter { !$0.lastPathComponent.hasPrefix(".") }
            guard nonHidden.count == 1,
                  let single = nonHidden.first,
                  (try? single.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { break }
            moveDirectory(from: single, to: current)
            current = path
        }
    }

    static func makeNextPath(dir: URL, name: String, extension ext: String) -> URL {
        let filtered = filterFilename(name)
        var i = 1
        while true {
            let fileName = i == 1 ? filtered + ext : "\(filtered) (\(i))\(ext)"
            let candidate = dir.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            i += 1
        }
    }

    static func filterFilename(_ original: String) -> String {
        let range = NSRange(original.startIndex..., in: original)
        return filenameFilterRegex.stringByReplacingMatches(in: original, range: range, withTemplate: "")
    }

    static func moveDirectory(from source: URL, to target: URL) {
        let fm = FileManager.default
        do {
            guard let sourceContents = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }

            for item in sourceContents {
                let dest = target.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: item, to: dest)
            }

            try fm.removeItem(at: source)
        } catch {
            logger.error("moveDirectory failed: \(error.localizedDescription)")
        }
    }

    static func deleteDirectory(at url: URL) {
        try? FileManager.default.removeItem(at: url)
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
