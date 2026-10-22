import Foundation
import Testing
@testable import unipad

/// How the pack's text files are read: encodings, line ends, byte order marks, colours and the grid
/// size, as Android and the web read the same bytes.
struct PackTextReadingTests {
    private static let info = Data("title=Text\nproducerName=UniPad\nbuttonX=4\nbuttonY=4\nchain=2\n".utf8)

    private struct Pack {
        let pack: UniPackFolder
        let root: URL

        func sounds(c: Int = 0, x: Int, y: Int) -> [String] {
            (pack.soundTable?[c][x][y].map(Array.init) ?? []).map(\.file.lastPathComponent)
        }

        func animations(x: Int, y: Int) -> [LedAnimation] {
            pack.ledAnimationTable?[0][x][y].map(Array.init) ?? []
        }

        var errors: [String] { pack.errorDetail?.components(separatedBy: "\n") ?? [] }
    }

    /// LED events are not Equatable; their descriptions name every field.
    private func describe(_ events: [LedAnimation.LedEvent]?) -> [String]? {
        events?.map { "\($0)" }
    }

    /// A pack with sounds/a.wav and the given files, loaded as the library loads it.
    private func load(info: Data = info, keySound: Data = Data("1 1 1 a.wav\n".utf8),
                      keyLED: [String: Data] = [:], autoPlay: Data? = nil) throws -> Pack {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PackTextReadingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "sounds"), withIntermediateDirectories: true)
        try Data(count: 4).write(to: root.appending(path: "sounds/a.wav"))
        try info.write(to: root.appending(path: "info"))
        try keySound.write(to: root.appending(path: "keySound"))
        if !keyLED.isEmpty {
            try FileManager.default.createDirectory(at: root.appending(path: "keyLED"), withIntermediateDirectories: true)
            for (name, data) in keyLED { try data.write(to: root.appending(path: "keyLED/\(name)")) }
        }
        try autoPlay?.write(to: root.appending(path: "autoPlay"))
        let pack = UniPackFolder(rootFolder: root)
        pack.load()
        pack.loadDetail()
        return Pack(pack: pack, root: root)
    }

    // MARK: Text that is not valid CP949

    @Test func anInfoWithBytesOutsideCP949StillOpens() throws {
        // 83 7C is Shift-JIS; in CP949 0x83 starts a character that 0x7C cannot end.
        let title = Data("title=".utf8) + Data([0x83, 0x7C]) + Data("\n".utf8)
        let loaded = try load(info: title + Data("producerName=UniPad\nbuttonX=4\nbuttonY=4\nchain=2\n".utf8))
        defer { try? FileManager.default.removeItem(at: loaded.root) }
        #expect(!loaded.pack.criticalError)
        #expect(loaded.pack.title == "\u{FFFD}|")
        #expect(loaded.pack.chain == 2)
        #expect(loaded.sounds(x: 0, y: 0) == ["a.wav"])
    }

    @Test func aKeySoundWithBytesOutsideCP949KeepsItsOtherLines() throws {
        let keySound = Data("1 1 1 caf".utf8) + Data([0xE9]) + Data(".wav\n1 2 1 a.wav\n".utf8)
        let loaded = try load(keySound: keySound)
        defer { try? FileManager.default.removeItem(at: loaded.root) }
        #expect(!loaded.pack.criticalError)
        #expect(loaded.sounds(x: 1, y: 0) == ["a.wav"])
        #expect(loaded.errors == ["keySound : [1 1 1 caf\u{FFFD}.wav] sound was not found"])
    }

    @Test func anLEDFileWithBytesOutsideCP949StillCountsAsAnAnimation() throws {
        let led = Data("o 1 1 FF0000\n".utf8) + Data([0x80, 0xFF]) + Data("\nf 1 1\n".utf8)
        let loaded = try load(keyLED: ["1 1 1": led, "1 1 1 1": Data("o 1 1 00FF00\n".utf8)])
        defer { try? FileManager.default.removeItem(at: loaded.root) }
        let animations = loaded.animations(x: 0, y: 0)
        #expect(animations.count == 2)
        #expect(describe(animations.first?.ledEvents) == describe([.on(x: 0, y: 0, color: Int(0xFFFF0000), velocity: 4), .off(x: 0, y: 0)]))
        #expect(loaded.errors == ["keyLed : [1 1 1].[\u{FFFD}\u{FFFD}] format is incorrect"])
    }

    @Test func anAutoPlayWithBytesOutsideCP949IsStillRead() throws {
        let autoPlay = Data("on 1 1\n".utf8) + Data([0x80]) + Data("\noff 1 1\n".utf8)
        let loaded = try load(autoPlay: autoPlay)
        defer { try? FileManager.default.removeItem(at: loaded.root) }
        #expect(loaded.pack.autoPlayTable?.elements.count == 2)
    }

    // MARK: Colours

    @Test func aSignedColourIsAFormatError() throws {
        let led = "o 1 1 +FF00\no 1 1 -1\no 1 1 -1 5\no 2 1 FF0000\n"
        let loaded = try load(keyLED: ["1 1 1": Data(led.utf8)])
        defer { try? FileManager.default.removeItem(at: loaded.root) }
        #expect(describe(loaded.animations(x: 0, y: 0).first?.ledEvents) == describe([.on(x: 1, y: 0, color: Int(0xFFFF0000), velocity: 4)]))
        #expect(loaded.errors == [
            "keyLed : [1 1 1].[o 1 1 +FF00] format is incorrect",
            "keyLed : [1 1 1].[o 1 1 -1] format is incorrect",
            "keyLed : [1 1 1].[o 1 1 -1 5] format is incorrect",
        ])
    }

    // MARK: Grid size

    @Test(arguments: ["buttonX", "buttonY"])
    func aMissingGridSizeRefusesThePack(key: String) throws {
        let info = "title=Text\nproducerName=UniPad\nbuttonX=4\nbuttonY=4\nchain=2\n"
            .components(separatedBy: "\n").filter { !$0.hasPrefix(key) }.joined(separator: "\n")
        let loaded = try load(info: Data(info.utf8))
        defer { try? FileManager.default.removeItem(at: loaded.root) }
        #expect(loaded.pack.criticalError)
        #expect(loaded.errors == ["info : \(key) was missing"])
    }

    @Test func aWrittenZeroGridSizeStillOpensWithAWarning() throws {
        let loaded = try load(info: Data("title=Text\nproducerName=UniPad\nbuttonX=0\nbuttonY=4\nchain=2\n".utf8))
        defer { try? FileManager.default.removeItem(at: loaded.root) }
        #expect(!loaded.pack.criticalError)
        #expect(loaded.errors.first == "info : buttonX was missing")
    }

    // MARK: Line ends

    @Test(arguments: ["\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"])
    func onlyLFAndCREndAKeySoundLine(separator: String) throws {
        let loaded = try load(keySound: Data("1 1 1 a.wav 1 1\(separator)1 2 1 a.wav\r\n1 3 1 a.wav\r1 4 1 a.wav".utf8))
        defer { try? FileManager.default.removeItem(at: loaded.root) }
        #expect(loaded.sounds(x: 1, y: 0).isEmpty)
        #expect(loaded.sounds(x: 2, y: 0) == ["a.wav"])
        #expect(loaded.sounds(x: 3, y: 0) == ["a.wav"])
    }

    @Test(arguments: ["\u{0B}", "\u{2028}"])
    func onlyLFAndCREndAnLEDLine(separator: String) throws {
        let loaded = try load(keyLED: ["1 1 1": Data("o 1 1 FF0000\(separator)f 1 1\n".utf8)])
        defer { try? FileManager.default.removeItem(at: loaded.root) }
        #expect(loaded.animations(x: 0, y: 0).first?.ledEvents.isEmpty == true)
        #expect(loaded.errors == ["keyLed : [1 1 1].[o 1 1 FF0000\(separator)f 1 1] format is incorrect"])
    }

    // MARK: Byte order marks inside a file

    @Test func aByteOrderMarkStartingALineIsIgnored() throws {
        let loaded = try load(
            info: Data("title=Text\nproducerName=UniPad\nbuttonX=4\nbuttonY=4\n\u{FEFF}chain=2\n".utf8),
            keySound: Data("\u{FEFF}1 1 1 a.wav\n\u{FEFF}1 2 1 a.wav\n".utf8),
            keyLED: ["1 1 1": Data("o 1 1 FF0000\n\u{FEFF}f 1 1\n".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: loaded.root) }
        #expect(loaded.pack.chain == 2)
        #expect(loaded.sounds(x: 0, y: 0) == ["a.wav"])
        #expect(loaded.sounds(x: 1, y: 0) == ["a.wav"])
        #expect(describe(loaded.animations(x: 0, y: 0).first?.ledEvents) == describe([.on(x: 0, y: 0, color: Int(0xFFFF0000), velocity: 4), .off(x: 0, y: 0)]))
        #expect(loaded.errors.isEmpty)
    }
}
