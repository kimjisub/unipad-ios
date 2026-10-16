import Foundation

/// Finds a file a pack names by path below one of its folders. The exact name wins; without it, the
/// file whose path differs only in letter case. Packs are written on Windows and macOS disks, which
/// ignore case, so a keySound line may name `End.wav` for a file stored as `END.wav`; an iPhone's disk
/// tells them apart. The web player and Android's default pack storage find such files, and this
/// does the same. Folder listings are read once per finder.
nonisolated final class PackFileFinder {
    private let fileManager: FileManager
    /// Folder path -> lowercased entry name -> entry. Of names that differ only in case, the first in
    /// name order is kept.
    private var listings: [String: [String: URL]] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func file(_ relativePath: String, in directory: URL) -> URL? {
        let exact = directory.appendingPathComponent(relativePath)
        if isFile(exact) { return exact }

        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        var current = directory
        for component in components {
            guard let entry = entries(of: current)[component.lowercased()] else { return nil }
            current = entry
        }
        return isFile(current) ? current : nil
    }

    private func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func entries(of directory: URL) -> [String: URL] {
        if let cached = listings[directory.path] { return cached }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var entries: [String: URL] = [:]
        for name in names.sorted() where entries[name.lowercased()] == nil {
            entries[name.lowercased()] = directory.appendingPathComponent(name)
        }
        listings[directory.path] = entries
        return entries
    }
}
