import Foundation
import Testing
@testable import unipad

/// Android reads every number field of keySound, keyLED and autoPlay with a 32-bit `toInt()`: a value
/// beyond it is not a number, so the line or file is skipped with a format error, while a 32-bit value
/// outside the pack stays a range error. iOS read 64-bit integers and reported those values as a wrong
/// chain or coordinate instead.
struct PackNumberRangeTests {
    static let beyond = [
        "2147483648", "-2147483649", "99999999999", "9007199254740993", "9223372036854775808",
        String(repeating: "9", count: 400)
    ]
    /// A file name holds at most 255 bytes on the device's disk, so the 400-digit value is cut to fit.
    static let beyondInFileName = beyond.map { String($0.prefix(240)) }
    static let inRange = ["2147483647", "-2147483648"]

    private struct Loaded {
        let pack: UniPackFolder
        let errors: [String]
    }

    private func load(keySound: String = "1 1 1 a.wav", keyLed: [String: String] = [:], autoPlay: String? = nil) throws -> Loaded {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appending(path: "PackNumberRangeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: root) }
        let sounds = root.appending(path: "sounds", directoryHint: .isDirectory)
        try fm.createDirectory(at: sounds, withIntermediateDirectories: true)
        try Data(count: 4).write(to: sounds.appending(path: "a.wav"))
        try "title=Numbers\nproducerName=UniPad\nbuttonX=2\nbuttonY=2\nchain=2\n"
            .write(to: root.appending(path: "info"), atomically: true, encoding: .utf8)
        try keySound.write(to: root.appending(path: "keySound"), atomically: true, encoding: .utf8)
        if !keyLed.isEmpty {
            let dir = root.appending(path: "keyLed", directoryHint: .isDirectory)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, text) in keyLed {
                try text.write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
            }
        }
        if let autoPlay {
            try autoPlay.write(to: root.appending(path: "autoPlay"), atomically: true, encoding: .utf8)
        }
        let pack = UniPackFolder(rootFolder: root)
        pack.checkFile()
        pack.loadInfo()
        pack.loadDetail()
        #expect(!pack.criticalError)
        return Loaded(pack: pack, errors: pack.errorDetail?.components(separatedBy: "\n") ?? [])
    }

    private func ledEvents(_ pack: UniPackFolder, x: Int = 0, y: Int = 0) throws -> (loop: Int, events: [String]) {
        let animation = try #require(pack.ledAnimationTable?[0][x][y]?.first)
        let events = animation.ledEvents.map { event in
            switch event {
            case .on(let x, let y, let color, let velocity): "on \(x) \(y) \(String(color, radix: 16)) \(velocity)"
            case .off(let x, let y): "off \(x) \(y)"
            case .delay(let delay): "delay \(delay)"
            case .chain(let chain): "chain \(chain)"
            }
        }
        return (animation.loop, events)
    }

    private func autoPlayElements(_ pack: UniPackFolder) -> [String] {
        (pack.autoPlayTable?.elements ?? []).map { element in
            switch element {
            case .on(let x, let y, let currChain, let num): "on \(x) \(y) \(currChain) \(num)"
            case .off(let x, let y, let currChain): "off \(x) \(y) \(currChain)"
            case .chain(let c): "chain \(c)"
            case .delay(let delay): "delay \(delay)"
            }
        }
    }

    @Test(arguments: beyond, [0, 1, 2, 4, 5])
    func keySoundFieldBeyond32BitsIsAFormatError(_ token: String, _ field: Int) throws {
        var parts = ["1", "1", "1", "a.wav", "1", "1"]
        parts[field] = token
        let line = parts.joined(separator: " ")
        let loaded = try load(keySound: "\(line)\n1 1 1 a.wav")

        #expect(loaded.errors == ["keySound : [\(line)] format is incorrect"])
        #expect(loaded.pack.soundCount == 1)
    }

    @Test(arguments: beyondInFileName, [0, 1, 2, 3])
    func keyLedFileNameFieldBeyond32BitsIsAFormatError(_ token: String, _ field: Int) throws {
        var parts = ["1", "1", "1", "1"]
        parts[field] = token
        let name = parts.joined(separator: " ")
        let loaded = try load(keyLed: [name: "f 1 1", "1 1 1": "f 1 1"])

        #expect(loaded.errors == ["keyLed : [\(name)] format is incorrect"])
        #expect(loaded.pack.ledTableCount == 1)
    }

    @Test(arguments: beyond)
    func keyLedLineBeyond32BitsIsAFormatError(_ token: String) throws {
        let lines = [
            "o \(token) 1 a 5", "o 1 \(token) a 5", "o 1 1 a \(token)", "f \(token) 1", "f 1 \(token)",
            "o mc \(token) a 5", "f mc \(token)", "d \(token)", "c \(token)"
        ]
        for line in lines {
            let loaded = try load(keyLed: ["1 1 1": "\(line)\nf 1 1"])

            #expect(loaded.errors == ["keyLed : [1 1 1].[\(line)] format is incorrect"])
            #expect(try ledEvents(loaded.pack).events == ["off 0 0"], "\(line)")
        }
    }

    @Test(arguments: beyond)
    func autoPlayLineBeyond32BitsIsAFormatError(_ token: String) throws {
        for line in ["o \(token) 1", "f 1 \(token)", "t \(token) 1", "c \(token)", "d \(token)"] {
            let loaded = try load(autoPlay: "\(line)\non 1 1")

            #expect(loaded.errors == ["autoPlay : [\(line)] format is incorrect"])
            #expect(autoPlayElements(loaded.pack) == ["on 0 0 0 0"], "\(line)")
        }
    }

    @Test(arguments: inRange)
    func a32BitValueOutsideThePackIsARangeError(_ token: String) throws {
        let loaded = try load(
            keySound: "\(token) 1 1 a.wav\n1 \(token) 1 a.wav\n1 1 1 a.wav",
            keyLed: ["1 1 \(token)": "f 1 1"],
            autoPlay: "o \(token) 1\nc \(token)"
        )

        #expect(loaded.errors == [
            "keySound : [\(token) 1 1 a.wav] chain is incorrect",
            "keySound : [1 \(token) 1 a.wav] x is incorrect",
            "keyLed : [1 1 \(token)] y is incorrect",
            "autoPlay : [o \(token) 1] x is incorrect",
            "autoPlay : [c \(token)] chain is incorrect"
        ])
        #expect(loaded.pack.soundCount == 1)
    }

    @Test func theLargest32BitDelayAndLoopAreKeptAndARoundLedPast32IsDroppedSilently() throws {
        let loaded = try load(
            keySound: "1 1 1 a.wav 2147483647",
            keyLed: ["1 1 1 2147483647": "d 2147483647\nd 2147483647\no mc 2147483647 a 5\nf 1 1"],
            autoPlay: "d 2147483647\nd -2147483648\non 1 1"
        )

        #expect(loaded.errors.isEmpty)
        let sound = try #require(loaded.pack.soundTable?[0][0][0]?.first)
        #expect(sound.loop == 2147483646)
        let led = try ledEvents(loaded.pack)
        #expect(led.loop == 2147483647)
        #expect(led.events == ["delay 2147483647", "delay 2147483647", "off 0 0"])
        #expect(autoPlayElements(loaded.pack) == ["delay 2147483647", "delay -2147483648", "on 0 0 0 0"])
    }

    /// The smallest 64-bit integer minus one, as the 0-based index of a chain or pad, trapped and closed
    /// the app while the pack opened.
    @Test func theSmallest64BitValueIsAFormatErrorInsteadOfACrash() throws {
        let token = "-9223372036854775808"
        let loaded = try load(
            keySound: "\(token) 1 1 a.wav\n1 1 1 a.wav",
            keyLed: ["1 1 \(token)": "f 1 1", "1 1 1": "c \(token)\nf mc \(token)\nf 1 1"],
            autoPlay: "o 1 \(token)\nc \(token)\non 1 1"
        )

        #expect(loaded.errors == [
            "keySound : [\(token) 1 1 a.wav] format is incorrect",
            "keyLed : [1 1 \(token)] format is incorrect",
            "keyLed : [1 1 1].[c \(token)] format is incorrect",
            "keyLed : [1 1 1].[f mc \(token)] format is incorrect",
            "autoPlay : [o 1 \(token)] format is incorrect",
            "autoPlay : [c \(token)] format is incorrect"
        ])
        #expect(loaded.pack.soundCount == 1)
        #expect(try ledEvents(loaded.pack).events == ["off 0 0"])
        #expect(autoPlayElements(loaded.pack) == ["on 0 0 0 0"])
    }
}
