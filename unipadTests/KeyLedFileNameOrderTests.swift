import Foundation
import Testing
@testable import unipad

/// Several keyLed files of one pad play in the order of their names. The same letters can be written
/// composed (`ñ`, `가`) or decomposed (`n` + accent, `ᄀ` + `ᅡ`) depending on the tool that made the
/// archive, so names are compared composed, lower-cased and by UTF-16 code units, as the Android and
/// web apps compare them. These packs go through the importer's own extraction, the path a pack opened
/// from Files or another app takes.
@MainActor
@Suite(.serialized)
struct KeyLedFileNameOrderTests {
    private let root: URL
    private let workspace: URL
    private let stagingRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "KeyLedFileNameOrder-\(UUID().uuidString)", directoryHint: .isDirectory)
        workspace = root.appending(path: "packs", directoryHint: .isDirectory)
        stagingRoot = root.appending(path: "staging", directoryHint: .isDirectory)
        for folder in [workspace, stagingRoot] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// Imports a pack whose pad (1, 1) of chain 1 has two keyLed files, named as given in the archive.
    private func importPack(first: String, second: String) async throws -> URL {
        let files: [(name: String, data: Data)] = [
            ("info", Data("title=Order\nproducerName=UniPad\nbuttonX=4\nbuttonY=3\nchain=2\nsquareButton=true\n".utf8)),
            ("keySound", Data("1 4 3 c.wav\n".utf8)),
            ("sounds/c.wav", Data(count: 4)),
            ("keyLed/1 1 1 1 \(first)", Data("d 20\n".utf8)),
            ("keyLed/1 1 1 1 \(second)", Data("d 10\n".utf8)),
        ]
        return try await UniPackImporter(stagingRoot: stagingRoot)
            .importPack(data: TestZip.stored(files), fileName: "Order.zip", to: workspace, delegate: nil)
    }

    /// The delays of pad (1, 1) of chain 1, in queue order.
    private func delays(of folder: URL) -> [Int] {
        let pack = UniPackFolder(rootFolder: folder)
        pack.checkFile()
        pack.loadInfo()
        pack.loadDetail()
        let queue = pack.ledAnimationTable?[0][0][0].map(Array.init) ?? []
        return queue.flatMap { animation in
            animation.ledEvents.compactMap { event -> Int? in
                if case .delay(let delay) = event { return delay }
                return nil
            }
        }
    }

    /// The code points of the last word of each keyLed file name as the disk stores it.
    private func storedNames(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "keyLed").path)
            .map { name in
                name.split(separator: " ").last.map { word in
                    word.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
                } ?? ""
            }
            .sorted()
    }

    @Test(arguments: [
        ("decomposed Latin accent", "n\u{0303}", "o"),
        ("composed Latin accent", "\u{00F1}", "o"),
        ("decomposed Hangul", "\u{1100}\u{1161}", "\u{3131}"),
        ("composed Hangul", "\u{AC00}", "\u{3131}"),
        ("supplementary plane", "\u{FFFD}", "\u{1F600}"),
    ])
    func theSecondNameComesFirst(form: String, first: String, second: String) async throws {
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = try await importPack(first: first, second: second)
        print("KEYLED-NAME-ORDER \(form): stored \(try storedNames(in: folder)), delays \(delays(of: folder))")

        #expect(delays(of: folder) == [10, 20])
    }
}
