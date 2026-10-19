import Foundation
@testable import unipad

nonisolated enum LedTimingPackFiles {
    /// Writes a pack with `keyLed` files (named "chain x y loop") and an `autoPlay` script.
    static func write(to root: URL, buttons: Int, keyLed: [String: String], autoPlay: String, chains: Int = 1) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("keyLed"), withIntermediateDirectories: true)
        try "title=LED timing\nproducerName=Test\nbuttonX=\(buttons)\nbuttonY=\(buttons)\nchain=\(chains)\n"
            .write(to: root.appendingPathComponent("info"), atomically: true, encoding: .utf8)
        try "1 1 1 a.wav\n".write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        try Data().write(to: root.appendingPathComponent("sounds/a.wav"))
        for (name, text) in keyLed {
            try text.write(to: root.appendingPathComponent("keyLed/\(name)"), atomically: true, encoding: .utf8)
        }
        try autoPlay.write(to: root.appendingPathComponent("autoPlay"), atomically: true, encoding: .utf8)
        return root
    }

    /// A fresh pack from `root`; each run and timeline needs its own, as both rotate its multi-mapping queues.
    static func load(_ root: URL) -> UniPack {
        let pack = UniPackFolder(rootFolder: root)
        pack.load()
        if !pack.criticalError { pack.loadDetail() }
        return pack
    }

    /// The shallowest folder holding an info file; store zips nest the pack in one or more folders.
    static func packRoot(in folder: URL) -> URL? {
        let fm = FileManager.default
        var level = [folder]
        while !level.isEmpty {
            if let root = level.sorted(by: { $0.path < $1.path }).first(where: { dir in
                ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.lowercased() == "info" }
            }) {
                return root
            }
            level = level.flatMap { dir in
                ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
        }
        return nil
    }
}
