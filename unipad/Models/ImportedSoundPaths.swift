import Foundation

/// Original ZIP sound names and their installed paths. APFS treats NFC and NFD names as the same
/// file, so colliding entries need separate storage while lookup must still compare original names.
nonisolated struct ImportedSoundPaths: Codable {
    struct Entry: Codable {
        let name: String
        let stored: String
        var archiveEntry: String? = nil
    }

    static let fileName = ".unipad-sound-paths.json"
    let version: Int
    let entries: [Entry]

    static func read(in directory: URL) -> [Entry]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let paths = try? JSONDecoder().decode(Self.self, from: data), paths.version == 1,
              paths.entries.allSatisfy({ valid($0.name) && valid($0.stored) && !$0.stored.contains("/") }) else { return nil }
        return paths.entries
    }

    /// Catalogs live beside their files. Taking the original path's trailing components recovers
    /// names below this folder even after wrappers have moved away or folder spellings have merged.
    static func files(in directory: URL, fileManager: FileManager = .default) -> [Entry] {
        let paths = ((try? fileManager.subpathsOfDirectory(atPath: directory.path)) ?? []).filter { path in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: directory.appendingPathComponent(path).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        let existing = Set(paths)
        var catalogs = Set<String>()
        var imported: [Entry] = []
        for path in paths where path.split(separator: "/").last == Substring(fileName) {
            let parent = directory.appendingPathComponent(path).deletingLastPathComponent()
            guard let entries = read(in: parent) else { continue }
            catalogs.insert(path)
            let components = path.split(separator: "/").dropLast()
            for entry in entries {
                let stored = (components.map(String.init) + [entry.stored]).joined(separator: "/")
                let depth = components.count + 1
                let original = entry.name.split(separator: "/")
                guard existing.contains(stored), original.count >= depth else { continue }
                imported.append(Entry(name: original.suffix(depth).joined(separator: "/"), stored: stored,
                                      archiveEntry: entry.archiveEntry))
            }
        }
        let mapped = Set(imported.map(\.stored))
        return imported + paths.filter { !catalogs.contains($0) && !mapped.contains($0) }
            .map { Entry(name: $0, stored: $0) }
    }

    private static func valid(_ path: String) -> Bool {
        guard let normalized = PackFileFinder.normalizedPath(path) else { return false }
        return Array(normalized.utf8) == Array(path.utf8)
    }

    static func write(_ entries: [Entry], in directory: URL) throws {
        let paths = Self(version: 1, entries: entries.sorted { $0.name.utf16.lexicographicallyPrecedes($1.name.utf16) })
        try JSONEncoder().encode(paths).write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }
}
