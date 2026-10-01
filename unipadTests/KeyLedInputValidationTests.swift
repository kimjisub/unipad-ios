import Foundation
import Testing
@testable import unipad

struct KeyLedInputValidationTests {
    struct Case: Sendable {
        let id: String
        let text: String
        let events: [String]
        let errors: Int
    }

    // Exact keyLED text from the preserved corpus; the corpus and its fingerprints stay untouched.
    static let originalCases: [Case] = [
        Case(id: "KL-012", text: "o mc 33 a 3\no * 0 a 3\nf mc 33\nf mc 0\no mc 32 a 3", events: ["on -1 31 fffafafa 3"], errors: 0),
        Case(id: "KL-014", text: "o l\no l ZZZZZZ\no l a 200\no l 0 a 5 9\no l a 5", events: ["on -1 32 ffef5350 5"], errors: 4),
        Case(id: "KL-M11", text: "o 1 1 FF0000 x\nf 1 1", events: ["off 0 0"], errors: 1),
        Case(id: "KL-M12", text: "o 1 1 FF0000 5 6\nf 1 1", events: ["off 0 0"], errors: 1),
        Case(id: "KL-M17", text: "o 1 1 a 200\nf 1 1", events: ["off 0 0"], errors: 1),
        Case(id: "KL-M18", text: "o 1 1 a -1\nf 1 1", events: ["off 0 0"], errors: 1)
    ]

    static let validCases: [Case] = [
        Case(id: "KL-001", text: "on 1 1 FF0000\no 2 1 00FF00\ndelay 100\nd 50\noff 1 1\nf 2 1\nchain 2\nc 1", events: ["on 0 0 ffff0000 4", "on 1 0 ff00ff00 4", "delay 100", "delay 50", "off 0 0", "off 1 0", "chain 1", "chain 0"], errors: 0),
        Case(id: "KL-010", text: "o 1 1 FF0000\no 1 2 00B8D4 5\no 1 3 auto 72\non 2 1 a 5\no 2 2 abcdef\no 2 3 000000", events: ["on 0 0 ffff0000 4", "on 0 1 ff00b8d4 5", "on 0 2 fff72737 72", "on 1 0 ffef5350 5", "on 1 1 ffabcdef 4", "on 1 2 ff000000 4"], errors: 0),
        Case(id: "KL-011", text: "o * 1 FF0000\no mc 32 a 3\non mc 5 00FF00 7\nf * 1\noff mc 32", events: ["on -1 0 ffff0000 4", "on -1 31 fffafafa 3", "on -1 4 ff00ff00 7", "off -1 0", "off -1 31"], errors: 0),
        Case(id: "KL-013", text: "o l FF0000\no l a 5\non l auto 9\no l 0 00FF00\no l 0 a 13\no l 0 0000FF 21\nf l\noff l", events: ["on -1 32 ffff0000 4", "on -1 32 ffef5350 5", "on -1 32 ffffa726 9", "on -1 32 ff00ff00 4", "on -1 32 ffffee58 13", "on -1 32 ff0000ff 21", "off -1 32", "off -1 32"], errors: 0)
    ]

    private func load(_ text: String) throws -> (events: [String], errors: [String]) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "KeyLedInputValidationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyLed = root.appending(path: "keyLed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: keyLed, withIntermediateDirectories: true)
        try "title=Conformance\nproducerName=UniPad Conformance\nbuttonX=4\nbuttonY=3\nchain=2\n"
            .write(to: root.appending(path: "info"), atomically: true, encoding: .utf8)
        try "".write(to: root.appending(path: "keySound"), atomically: true, encoding: .utf8)
        try text.write(to: keyLed.appending(path: "1 1 1"), atomically: true, encoding: .utf8)
        let pack = UniPackFolder(rootFolder: root)
        pack.checkFile()
        pack.loadInfo()
        pack.loadDetail()
        #expect(!pack.criticalError)
        let table = try #require(pack.ledAnimationTable)
        let animation = try #require(table[0][0][0]?.first)
        let events = animation.ledEvents.map { event in
            switch event {
            case .on(let x, let y, let color, let velocity):
                return "on \(x) \(y) \(String(color, radix: 16)) \(velocity)"
            case .off(let x, let y): return "off \(x) \(y)"
            case .delay(let delay): return "delay \(delay)"
            case .chain(let chain): return "chain \(chain)"
            }
        }
        return (events, pack.errorDetail?.components(separatedBy: "\n") ?? [])
    }

    @Test(arguments: originalCases)
    func originalDivergences(_ sample: Case) throws {
        try check(sample)
    }

    @Test(arguments: validCases)
    func preservedValidPackInputs(_ sample: Case) throws {
        try check(sample)
    }

    private func check(_ sample: Case) throws {
        let result = try load(sample.text)
        #expect(result.events == sample.events, "\(sample.id)")
        #expect(result.errors.count == sample.errors, "\(sample.id)")
        #expect(result.errors.allSatisfy { $0.hasPrefix("keyLed :") && $0.hasSuffix("format is incorrect") })
    }

    @Test func roundBoundariesAndLogoStayDistinct() throws {
        for target in ["mc", "*"] {
            let result = try load("o \(target) 0 a 3\no \(target) 1 a 3\no \(target) 32 a 3\no \(target) 33 a 3\nf \(target) 0\nf \(target) 1\nf \(target) 32\nf \(target) 33\no l a 3\nf l")
            #expect(result.events == ["on -1 0 fffafafa 3", "on -1 31 fffafafa 3", "off -1 0", "off -1 31", "on -1 32 fffafafa 3", "off -1 32"])
            #expect(result.errors.isEmpty)
        }
    }

    @Test func validColorAndLogoFormsArePreserved() throws {
        let forms: [(String, Int, Int)] = [
            ("a", 0xFF00000A, 4), ("F", 0xFF00000F, 4), ("FF0000", 0xFFFF0000, 4),
            ("FF0000 5", 0xFFFF0000, 5), ("FF0000 200", 0xFFFF0000, 200),
            ("FF0000 -1", 0xFFFF0000, -1), ("a 0", Int(LaunchpadColor.colorFromCode(0)), 0),
            ("auto 127", Int(LaunchpadColor.colorFromCode(127)), 127),
        ]
        for (prefix, x, y) in [("o 1 1", 0, 0), ("on mc 1", -1, 0), ("o * 32", -1, 31), ("o l", -1, 32), ("on l 1", -1, 32)] {
            // Four-token logo syntax reserves a/auto for the palette, so a bare hex a
            // only belongs to the compact three-token logo syntax.
            for (color, value, velocity) in forms where !(prefix == "on l 1" && color == "a")
                && !(prefix == "o l" && color.hasPrefix("FF0000 ")) {
                let result = try load("\(prefix) \(color)")
                #expect(result.events == ["on \(x) \(y) \(String(value, radix: 16)) \(velocity)"])
                #expect(result.errors.isEmpty)
            }
        }
    }

    @Test func malformedColorArgumentsDoNotFallBackAndNextLineSurvives() throws {
        for prefix in ["o 1 1", "o mc 1", "o * 32", "o l", "o l 1"] {
            for color in ["FF0000 x", "a x", "auto x", "a 200", "a -1", "auto 128", "FF0000 5 6", "a 5 9", "FFFFFFF", "ZZZZZZ"] {
                // A five-token logo line is the preserved placeholder form, not an extra argument.
                if prefix == "o l" && color.split(separator: " ").count == 3 { continue }
                let result = try load("\(prefix) \(color)\nf 1 1")
                #expect(result.events == ["off 0 0"], "\(prefix) \(color)")
                #expect(result.errors.count == 1, "\(prefix) \(color)")
            }
        }
    }
}
