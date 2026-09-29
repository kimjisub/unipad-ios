import Foundation
import Testing
@testable import unipad

/// LED velocities come straight out of a pack's keyLED text (`on 1 1 FF0000 200` parses), so the
/// MIDI drivers are the last place that can keep them inside the 7-bit data range 0...127.
struct LedVelocityRangeTests {
    private final class Capture: MidiDriverSendSignalListener {
        var sent: [(cmd: UInt8, sig: UInt8, note: UInt8, velocity: UInt8)] = []
        var raw: [[UInt8]] = []

        func onSend(cmd: UInt8, sig: UInt8, note: UInt8, velocity: UInt8) { sent.append((cmd, sig, note, velocity)) }
        func onSendRaw(messages: [[UInt8]], cableNumber: Int) { raw.append(contentsOf: messages) }
    }

    private struct Case {
        let name: String
        let make: () -> BaseMidiDriver
        let hasFunctionKeys: Bool
        let hasLogo: Bool
    }

    private static let clamped: [(input: Int, expected: UInt8)] = [
        (200, 127), (-1, 0), (0, 0), (127, 127), (40, 40), (61, 61),
    ]

    private static let drivers: [Case] = [
        Case(name: "MK2", make: { LaunchpadMK2Driver() }, hasFunctionKeys: true, hasLogo: false),
        Case(name: "Pro", make: { LaunchpadProDriver() }, hasFunctionKeys: true, hasLogo: true),
        Case(name: "ProMK3", make: { LaunchpadProMK3Driver() }, hasFunctionKeys: true, hasLogo: true),
        Case(name: "X", make: { LaunchpadXDriver() }, hasFunctionKeys: true, hasLogo: true),
        Case(name: "MiniMK3", make: { LaunchpadMiniMK3Driver() }, hasFunctionKeys: true, hasLogo: true),
        Case(name: "Matrix", make: { MatrixDriver() }, hasFunctionKeys: true, hasLogo: false),
        Case(name: "CoreCFW", make: { LaunchpadCoreCFWDriver() }, hasFunctionKeys: true, hasLogo: true),
        Case(name: "ProCFW", make: { LaunchpadProCFWDriver() }, hasFunctionKeys: true, hasLogo: true),
        Case(name: "MidiFighter", make: { MidiFighterDriver() }, hasFunctionKeys: false, hasLogo: false),
    ]

    private static func run(_ driver: BaseMidiDriver, _ body: (BaseMidiDriver) -> Void) -> Capture {
        let capture = Capture()
        driver.sendSignalListener = capture
        body(driver)
        return capture
    }

    @Test func padLedVelocityStaysInMidiRange() {
        for entry in Self.drivers {
            for (input, expected) in Self.clamped {
                let capture = Self.run(entry.make()) { $0.sendPadLed(x: 0, y: 0, velocity: input) }
                #expect(capture.sent.map(\.velocity) == [expected], "\(entry.name) pad velocity \(input)")
            }
        }
    }

    @Test func functionKeyAndChainLedVelocityStayInMidiRange() {
        for entry in Self.drivers where entry.hasFunctionKeys {
            for (input, expected) in Self.clamped {
                let key = Self.run(entry.make()) { $0.sendFunctionKeyLed(f: 0, velocity: input) }
                #expect(key.sent.map(\.velocity) == [expected], "\(entry.name) function key velocity \(input)")

                let chain = Self.run(entry.make()) { $0.sendChainLed(c: 0, velocity: input) }
                #expect(chain.sent.map(\.velocity) == [expected], "\(entry.name) chain velocity \(input)")
            }
        }
    }

    @Test func logoLedVelocityStaysInMidiRange() {
        for entry in Self.drivers where entry.hasLogo && !(entry.make() is LaunchpadProDriver) {
            for (input, expected) in Self.clamped {
                let capture = Self.run(entry.make()) { $0.sendFunctionKeyLed(f: 32, velocity: input) }
                #expect(capture.sent.map(\.velocity) == [expected], "\(entry.name) logo velocity \(input)")
            }
        }
    }

    /// Stock-firmware Pro drives its logo with SysEx: a velocity of 0 turns it off and any other
    /// value is the palette index, which must be a 7-bit byte.
    @Test func proLogoSysExUsesTheClampedVelocity() {
        let lit: [(input: Int, expected: UInt8)] = [(200, 127), (127, 127), (40, 40)]
        for (input, expected) in lit {
            let capture = Self.run(LaunchpadProDriver()) { $0.sendFunctionKeyLed(f: 32, velocity: input) }
            #expect(capture.raw == [[0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x0A, 0x63, expected, 0xF7]], "Pro logo velocity \(input)")
        }
        for input in [-1, 0] {
            let capture = Self.run(LaunchpadProDriver()) { $0.sendFunctionKeyLed(f: 32, velocity: input) }
            #expect(capture.raw == [
                [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x0B, 0x63, 0x00, 0x00, 0x00, 0xF7],
                [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x0A, 0x63, 0x00, 0xF7],
            ], "Pro logo velocity \(input)")
        }
    }

    /// The status, channel and note bytes are deliberately signed on the way in (`sig: -80`), so
    /// only the velocity may be clamped.
    @Test func clampingLeavesStatusAndNoteBytesAlone() {
        let capture = Self.run(LaunchpadProMK3Driver()) { $0.sendFunctionKeyLed(f: 0, velocity: 200) }
        #expect(capture.sent.count == 1)
        #expect(capture.sent[0].cmd == 11 && capture.sent[0].sig == 0xB0 && capture.sent[0].note == 91)
    }

    /// Launchpad S maps the velocity through its own 128-entry table, which already clamped.
    @Test func launchpadSKeepsItsTableLookup() {
        let last = UInt8(LaunchpadColor.sCode[LaunchpadColor.sCode.count - 1])
        for (input, expected) in [(200, last), (-1, UInt8(LaunchpadColor.sCode[0])), (0, 0)] {
            let pad = Self.run(LaunchpadSDriver()) { $0.sendPadLed(x: 0, y: 0, velocity: input) }
            let key = Self.run(LaunchpadSDriver()) { $0.sendFunctionKeyLed(f: 0, velocity: input) }
            #expect(pad.sent.map(\.velocity) == [expected], "S pad velocity \(input)")
            #expect(key.sent.map(\.velocity) == [expected], "S function key velocity \(input)")
        }
    }

    // MARK: - From pack text to MIDI

    private func loadLedEvents(_ lines: [String]) throws -> [LedAnimation.LedEvent] {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LedVelocityRangeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyLed = root.appending(path: "keyLED", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: keyLed, withIntermediateDirectories: true)
        try "title=T\nproducerName=P\nbuttonX=8\nbuttonY=8\nchain=1\n"
            .write(to: root.appending(path: "info"), atomically: true, encoding: .utf8)
        try "".write(to: root.appending(path: "keySound"), atomically: true, encoding: .utf8)
        try lines.joined(separator: "\n").write(to: keyLed.appending(path: "1 1 1"), atomically: true, encoding: .utf8)

        let pack = UniPackFolder(rootFolder: root)
        pack.checkFile()
        pack.loadInfo()
        pack.loadDetail()
        let table = try #require(pack.ledAnimationTable)
        return try #require(table[0][0][0]?.first).ledEvents
    }

    /// Replays a parsed `.on` event through the driver call PlayViewModel makes for it: pads
    /// use `sendPadLed`, chains and the logo (index 32) use `sendFunctionKeyLed`.
    private func replay(_ event: LedAnimation.LedEvent, on driver: BaseMidiDriver) {
        guard case .on(let x, let y, _, let velocity) = event else { return }
        if x >= 0 {
            driver.sendPadLed(x: x, y: y, velocity: velocity)
        } else {
            driver.sendFunctionKeyLed(f: y, velocity: velocity)
        }
    }

    @Test func packLinesWithOutOfRangeVelocitiesReachTheDriverInRange() throws {
        let inputs = [200, -1, 0, 127]
        let targets: [(label: String, prefix: String)] = [
            ("pad", "on 1 1"), ("chain", "on mc 1"), ("logo", "on l 1"),
        ]
        for target in targets {
            let events = try loadLedEvents(inputs.map { "\(target.prefix) FF0000 \($0)" })
            let parsed = events.compactMap { event -> Int? in
                if case .on(_, _, _, let velocity) = event { return velocity }
                return nil
            }
            #expect(parsed == inputs, "\(target.label) pack text is read as written")

            for entry in Self.drivers where target.label == "pad" || entry.hasFunctionKeys {
                if target.label == "logo" && !entry.hasLogo { continue }
                if target.label == "logo" && entry.make() is LaunchpadProDriver { continue }
                let driver = entry.make()
                let capture = Capture()
                driver.sendSignalListener = capture
                events.forEach { replay($0, on: driver) }
                #expect(capture.sent.map(\.velocity) == [127, 0, 0, 127], "\(entry.name) \(target.label) from pack text")
            }
        }
    }
}
