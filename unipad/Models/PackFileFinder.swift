import Foundation

/// Finds a file a pack names by path below one of its folders, as Android and the web find it.
///
/// The name is relative to that folder: `\` separates folders as `/` does (Windows authors write
/// `fx\sweep.wav`), leading slashes, `.` and repeated slashes are dropped, and a name with `..` is
/// never looked up, so it cannot reach a file outside the folder.
///
/// The exact stored path wins; then one that is the same composed (NFC); then one that differs only in
/// letter case. Packs are written on Windows and macOS disks, which ignore case, so a keySound line may
/// name `End.wav` for a file stored as `END.wav`; an iPhone's disk tells them apart. Whole paths are
/// compared, and of several candidates the first in UTF-16 order is taken. The folder is listed once
/// per finder.
nonisolated final class PackFileFinder {
    private let fileManager: FileManager
    /// Folder path -> its files' paths below it.
    private var indexes: [String: Index] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func file(_ name: String, in directory: URL) -> URL? {
        guard let path = Self.normalizedPath(name),
              let stored = index(of: directory).match(path) else { return nil }
        return directory.appendingPathComponent(stored)
    }

    /// `name` as a path below the folder, or nil when it names nothing there.
    static func normalizedPath(_ name: String) -> String? {
        var components: [Substring] = []
        for component in name.replacingOccurrences(of: "\\", with: "/").split(separator: "/") where component != "." {
            if component == ".." { return nil }
            components.append(component)
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    /// Stored paths keyed by their exact, composed and composed lower-cased spelling. Swift compares
    /// and hashes strings by canonical equivalence, so the keys are UTF-8 bytes.
    struct Index {
        private var exact: [[UInt8]: String] = [:]
        private var composed: [[UInt8]: String] = [:]
        private var folded: [[UInt8]: String] = [:]

        init(paths: [String]) {
            self.init(entries: paths.map { ImportedSoundPaths.Entry(name: $0, stored: $0) })
        }

        init(entries: [ImportedSoundPaths.Entry]) {
            for entry in entries.sorted(by: { $0.name.utf16.lexicographicallyPrecedes($1.name.utf16) }) {
                let path = entry.name
                let nfc = path.precomposedStringWithCanonicalMapping
                exact[Array(path.utf8)] = exact[Array(path.utf8)] ?? entry.stored
                composed[Array(nfc.utf8)] = composed[Array(nfc.utf8)] ?? entry.stored
                folded[Array(nfc.lowercased().utf8)] = folded[Array(nfc.lowercased().utf8)] ?? entry.stored
            }
        }

        func match(_ path: String) -> String? {
            let nfc = path.precomposedStringWithCanonicalMapping
            return exact[Array(path.utf8)] ?? composed[Array(nfc.utf8)] ?? folded[Array(nfc.lowercased().utf8)]
        }
    }

    private func index(of directory: URL) -> Index {
        if let cached = indexes[directory.path] { return cached }
        let paths = ((try? fileManager.subpathsOfDirectory(atPath: directory.path)) ?? []).filter { path in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: directory.appendingPathComponent(path).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        let manifest = ImportedSoundPaths.read(in: directory)
        let imported = (manifest ?? []).filter { entry in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: directory.appendingPathComponent(entry.stored).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        let mapped = Set(imported.map(\.stored))
        let additional = paths.filter { (manifest == nil || $0 != ImportedSoundPaths.fileName) && !mapped.contains($0) }
            .map { ImportedSoundPaths.Entry(name: $0, stored: $0) }
        let index = Index(entries: imported + additional)
        indexes[directory.path] = index
        return index
    }
}
