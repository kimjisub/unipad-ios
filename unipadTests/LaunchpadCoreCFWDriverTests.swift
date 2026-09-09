import Testing
@testable import unipad

/// Note map of the "Launchpad Core Firmware" in Performance mode.
struct LaunchpadCoreCFWDriverTests {
    private final class Capture: MidiDriverReceiveSignalListener, MidiDriverSendSignalListener {
        var pads: [(x: Int, y: Int, down: Bool)] = []
        var chains: [(c: Int, down: Bool)] = []
        var keys: [(f: Int, down: Bool)] = []
        var sent: [(cmd: UInt8, sig: UInt8, note: UInt8, velocity: UInt8)] = []
        var raw: [(messages: [[UInt8]], cable: Int)] = []
        var unknown: [Int] = []

        func onReceived(cmd: Int, sig: Int, note: Int, velocity: Int) {}
        func onUnknownReceived(cmd: Int, sig: Int, note: Int, velocity: Int) { unknown.append(note) }
        func onPadTouch(x: Int, y: Int, upDown: Bool, velocity: Int) { pads.append((x, y, upDown)) }
        func onChainTouch(c: Int, upDown: Bool) { chains.append((c, upDown)) }
        func onFunctionKeyTouch(f: Int, upDown: Bool) { keys.append((f, upDown)) }
        func onSend(cmd: UInt8, sig: UInt8, note: UInt8, velocity: UInt8) { sent.append((cmd, sig, note, velocity)) }
        func onSendRaw(messages: [[UInt8]], cableNumber: Int) { raw.append((messages, cableNumber)) }
    }

    private func make() -> (LaunchpadCoreCFWDriver, Capture) {
        let driver = LaunchpadCoreCFWDriver()
        let capture = Capture()
        driver.receiveSignalListener = capture
        driver.sendSignalListener = capture
        return (driver, capture)
    }

    @Test func padNotesMapToRowsAndColumns() {
        let (driver, capture) = make()
        driver.getSignal(cmd: 9, sig: 0x90, note: 36, velocity: 100)  // first note: bottom-left (row 7, col 0)
        driver.getSignal(cmd: 9, sig: 0x90, note: 99, velocity: 100)  // last note: top-right (row 0, col 7)
        driver.getSignal(cmd: 8, sig: 0x80, note: 36, velocity: 0)    // note-off: release
        #expect(capture.pads.count == 3)
        #expect(capture.pads[0].x == 7 && capture.pads[0].y == 0 && capture.pads[0].down)
        #expect(capture.pads[1].x == 0 && capture.pads[1].y == 7 && capture.pads[1].down)
        #expect(capture.pads[2].x == 7 && capture.pads[2].y == 0 && !capture.pads[2].down)
    }

    @Test func padLedRoundTripsThroughTheSameNote() {
        let (driver, capture) = make()
        for x in 0..<8 {
            for y in 0..<8 {
                capture.sent.removeAll()
                driver.sendPadLed(x: x, y: y, velocity: 5)
                #expect(capture.sent.count == 1)
                #expect(capture.sent[0].cmd == 9 && capture.sent[0].sig == 0x90)  // note-on, channel 1
                capture.pads.removeAll()
                driver.getSignal(cmd: 9, sig: 0x90, note: Int(capture.sent[0].note), velocity: 1)
                #expect(capture.pads.first?.x == x && capture.pads.first?.y == y)
            }
        }
    }

    @Test func ringButtonsMapToChainsAndFunctionKeys() {
        let (driver, capture) = make()
        driver.getSignal(cmd: 9, sig: 0x90, note: 28, velocity: 1)   // top row, leftmost
        driver.getSignal(cmd: 9, sig: 0x90, note: 100, velocity: 1)  // right column, top
        driver.getSignal(cmd: 9, sig: 0x90, note: 123, velocity: 1)  // bottom row, rightmost
        driver.getSignal(cmd: 9, sig: 0x90, note: 115, velocity: 1)  // left column, bottom
        driver.getSignal(cmd: 9, sig: 0x90, note: 27, velocity: 1)   // top-right corner
        #expect(capture.keys.map(\.f) == [0, 8, 16, 24, 32])
        #expect(capture.chains.map(\.c) == [0, 8, 16])
    }

    @Test func notePressReleaseAndUnknownNotes() {
        let (driver, capture) = make()
        driver.getSignal(cmd: 9, sig: 0x90, note: 36, velocity: 127)  // Note on (press)
        driver.getSignal(cmd: 9, sig: 0x90, note: 36, velocity: 0)    // Note on velocity 0 (release)
        driver.getSignal(cmd: 8, sig: 0x80, note: 36, velocity: 0)    // Note off (release)
        driver.getSignal(cmd: 9, sig: 0x90, note: 20, velocity: 1)    // not on the map
        driver.getSignal(cmd: 11, sig: 0xB0, note: 36, velocity: 127) // CC: ignored by CoreFW driver
        driver.getSignal(cmd: 10, sig: 0xA0, note: 36, velocity: 1)   // poly aftertouch: ignored
        #expect(capture.pads.map(\.down) == [true, false, false])
        #expect(capture.unknown == [20])
    }

    @Test func outOfRangeLedsSendNothing() {
        let (driver, capture) = make()
        driver.sendPadLed(x: 8, y: 0, velocity: 5)
        driver.sendPadLed(x: 0, y: 8, velocity: 5)
        driver.sendFunctionKeyLed(f: 33, velocity: 5)
        driver.sendChainLed(c: 24, velocity: 5)
        #expect(capture.sent.isEmpty)
    }

    @Test func initSendsUnifiedSysExSequence() {
        let (driver, capture) = make()
        driver.initialize()
        #expect(capture.raw.map(\.cable) == [0])
        #expect(capture.raw[0].messages.count == 10)
        #expect(capture.raw[0].messages[0] == [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x22, 0x03, 0xF7])
        #expect(capture.raw[0].messages[1] == [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x0E, 0x00, 0xF7])
    }
}
