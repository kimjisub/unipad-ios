import Foundation

/// Finds a file a pack names by path below one of its folders, as Android and the web find it.
///
/// The name is relative to that folder: `\` separates folders as `/` does (Windows authors write
/// `fx\sweep.wav`), leading slashes, `.` and repeated slashes are dropped, and `..` steps back one
/// folder as written (`fx/../kick.wav` is `kick.wav`). A name that steps above the folder names
/// nothing there, so it cannot reach a file outside it.
///
/// The exact path wins, then a path that differs only in Unicode composition (NFC), then NFC paths
/// compared without letter case. Packs are written on Windows and macOS disks, which ignore case, so
/// a keySound line may name `End.wav` for a file stored as `END.wav`; an iPhone's disk tells them
/// apart. Whole paths are compared, and of several candidates the first in UTF-16 order is taken.
/// The folder is listed once per finder.
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
        var components: [String] = []
        for component in segments(name) {
            if component == ".." {
                guard components.popLast() != nil else { return nil }
            } else {
                components.append(component)
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    /// An archive entry's folders and name. An entry with a `..` folder names nothing, so archive
    /// extraction never writes outside its destination.
    static func pathComponents(_ name: String) -> [String]? {
        let components = segments(name)
        return components.isEmpty || components.contains("..") ? nil : components
    }

    private static func segments(_ name: String) -> [String] {
        name.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            .filter { $0 != "." }.map(String.init)
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
                func keepFirst(_ key: String, in paths: inout [[UInt8]: String]) {
                    paths[Array(key.utf8)] = paths[Array(key.utf8)] ?? entry.stored
                }
                let nfc = entry.name.precomposedStringWithCanonicalMapping
                keepFirst(entry.name, in: &exact)
                keepFirst(nfc, in: &composed)
                keepFirst(nfc.lowercased(), in: &folded)
            }
        }

        func match(_ path: String) -> String? {
            let nfc = path.precomposedStringWithCanonicalMapping
            return exact[Array(path.utf8)] ?? composed[Array(nfc.utf8)] ?? folded[Array(nfc.lowercased().utf8)]
        }
    }

    private func index(of directory: URL) -> Index {
        if let cached = indexes[directory.path] { return cached }
        let index = Index(entries: ImportedSoundPaths.files(in: directory, fileManager: fileManager))
        indexes[directory.path] = index
        return index
    }
}
