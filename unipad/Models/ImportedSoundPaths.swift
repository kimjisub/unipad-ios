import Foundation

/// Original ZIP sound names and their installed paths. APFS treats NFC and NFD names as the same
/// file, so colliding entries need separate storage while lookup must still compare original names.
nonisolated struct ImportedSoundPaths: Codable {
    struct Entry: Codable {
        let name: String
        let stored: String
    }

    static let fileName = ".unipad-sound-paths.json"
    let version: Int
    let entries: [Entry]

    static func read(in directory: URL) -> [Entry]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let paths = try? JSONDecoder().decode(Self.self, from: data), paths.version == 1,
              paths.entries.allSatisfy({ valid($0.name) && valid($0.stored) }) else { return nil }
        return paths.entries
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
