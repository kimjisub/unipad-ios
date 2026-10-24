import Testing
@testable import unipad

/// What each driver reports for a press, a release, aftertouch and the ring buttons, and which LEDs it
/// lights. `cmd` carries the port in its high nibble (MidiManager puts it there), so the same message on
/// port 0 and port 1 must mean the same button.
struct MidiDriverButtonRulesTests {
    final class Capture: MidiDriverReceiveSignalListener, MidiDriverSendSignalListener {
        var pads: [String] = []
        var chains: [String] = []
        var keys: [String] = []
        var unknown: [Int] = []
        var sent: [(sig: UInt8, note: UInt8, velocity: UInt8)] = []

        func onReceived(cmd: Int, sig: Int, note: Int, velocity: Int) {}
        func onUnknownReceived(cmd: Int, sig: Int, note: Int, velocity: Int) { unknown.append(note) }
        func onPadTouch(x: Int, y: Int, upDown: Bool, velocity: Int) { pads.append("\(x),\(y) \(upDown ? "down" : "up")") }
        func onChainTouch(c: Int, upDown: Bool) { chains.append("\(c) \(upDown ? "down" : "up")") }
        func onFunctionKeyTouch(f: Int, upDown: Bool) { keys.append("\(f) \(upDown ? "down" : "up")") }
        func onSend(cmd: UInt8, sig: UInt8, note: UInt8, velocity: UInt8) { sent.append((sig, note, velocity)) }
        func onSendRaw(messages: [[UInt8]], cableNumber: Int) {}
    }

    static func attach<D: BaseMidiDriver>(_ driver: D) -> (D, Capture) {
        let capture = Capture()
        driver.receiveSignalListener = capture
        driver.sendSignalListener = capture
        return (driver, capture)
    }

    /// Message kinds as MidiManager reports them on port 0; `+ 16` is the same message on port 1.
    static let noteOff = 8, noteOn = 9, polyAftertouch = 10, controlChange = 11, channelPressure = 13

    // MARK: - Launchpad Pro, Pro MK3, X and Mini MK3 (programmer layout)

    static let programmerDrivers: [(name: String, make: () -> BaseMidiDriver)] = [
        ("Pro", { LaunchpadProDriver() }),
        ("ProMK3", { LaunchpadProMK3Driver() }),
        ("X", { LaunchpadXDriver() }),
        ("MiniMK3", { LaunchpadMiniMK3Driver() }),
    ]

    @Test(arguments: [0, 1])
    func programmerPadsPressAndReleaseOnEitherPort(port: Int) {
        for entry in Self.programmerDrivers {
            let (driver, capture) = Self.attach(entry.make())
            driver.getSignal(cmd: port << 4 | Self.noteOn, sig: -112, note: 81, velocity: 100)
            driver.getSignal(cmd: port << 4 | Self.noteOn, sig: -112, note: 81, velocity: 0)
            driver.getSignal(cmd: port << 4 | Self.noteOn, sig: -112, note: 18, velocity: 1)
            driver.getSignal(cmd: port << 4 | Self.noteOff, sig: -128, note: 18, velocity: 64)
            #expect(capture.pads == ["0,0 down", "0,0 up", "7,7 down", "7,7 up"], "\(entry.name) port \(port)")
            #expect(capture.unknown.isEmpty, "\(entry.name) port \(port): pad notes reported as unknown")
        }
    }

    @Test(arguments: [0, 1])
    func programmerRingButtonsReportChainsOnEitherPort(port: Int) {
        for entry in Self.programmerDrivers {
            let (driver, capture) = Self.attach(entry.make())
            for note in [91, 89, 19, 8, 1, 10, 80, 99] {
                driver.getSignal(cmd: port << 4 | Self.controlChange, sig: -80, note: note, velocity: 127)
            }
            driver.getSignal(cmd: port << 4 | Self.controlChange, sig: -80, note: 89, velocity: 0)
            #expect(capture.chains == ["0 down", "7 down", "8 down", "15 down", "16 down", "23 down", "0 up"], "\(entry.name) port \(port)")
            #expect(capture.keys == ["0 down", "8 down", "15 down", "16 down", "23 down", "24 down", "31 down", "32 down", "8 up"],
                    "\(entry.name) port \(port)")
        }
    }

    @Test func programmerTopRowNotesAndAftertouchAreNotPads() {
        for entry in Self.programmerDrivers {
            let (driver, capture) = Self.attach(entry.make())
            driver.getSignal(cmd: Self.noteOn, sig: -112, note: 91, velocity: 100)          // top row as a note: row -1
            driver.getSignal(cmd: Self.polyAftertouch, sig: -96, note: 81, velocity: 0)     // pressure easing off
            driver.getSignal(cmd: Self.channelPressure, sig: -48, note: 0, velocity: 0)
            #expect(capture.pads.isEmpty, "\(entry.name)")
        }
    }

    @Test func programmerLedsStayOnTheGridAndRing() {
        for entry in Self.programmerDrivers {
            let (driver, capture) = Self.attach(entry.make())
            driver.sendPadLed(x: 8, y: 0, velocity: 5)
            driver.sendPadLed(x: 0, y: 8, velocity: 5)
            driver.sendPadLed(x: -1, y: 0, velocity: 5)
            #expect(capture.sent.isEmpty, "\(entry.name) lit an LED outside the 8x8 pads")

            driver.sendPadLed(x: 0, y: 0, velocity: 5)
            driver.sendChainLed(c: 8, velocity: 6)    // bottom row, rightmost: CC 8
            driver.sendChainLed(c: 23, velocity: 7)   // left column, top: CC 80
            driver.sendChainLed(c: 24, velocity: 7)
            #expect(capture.sent.map { "\($0.sig) \($0.note) \($0.velocity)" } == ["144 81 5", "176 8 6", "176 80 7"], "\(entry.name)")
        }
    }

    // MARK: - Launchpad MK2 and S

    @Test func mk2AndSLedsStayOnTheGrid() {
        let drivers: [(String, BaseMidiDriver)] = [("MK2", LaunchpadMK2Driver()), ("S", LaunchpadSDriver())]
        for (name, driver) in drivers {
            let (driver, capture) = Self.attach(driver)
            driver.sendPadLed(x: 8, y: 0, velocity: 5)
            driver.sendPadLed(x: 0, y: 8, velocity: 5)
            #expect(capture.sent.isEmpty, "\(name)")
        }
    }

    @Test(arguments: [0, 1])
    func mk2PressReleaseAndRightColumn(port: Int) {
        let (driver, capture) = Self.attach(LaunchpadMK2Driver())
        driver.getSignal(cmd: port << 4 | Self.noteOn, sig: -112, note: 81, velocity: 100)
        driver.getSignal(cmd: port << 4 | Self.noteOff, sig: -128, note: 81, velocity: 64)
        driver.getSignal(cmd: port << 4 | Self.polyAftertouch, sig: -96, note: 81, velocity: 0)
        driver.getSignal(cmd: port << 4 | Self.noteOn, sig: -112, note: 19, velocity: 100)
        driver.getSignal(cmd: port << 4 | Self.controlChange, sig: -80, note: 104, velocity: 127)
        #expect(capture.pads == ["0,0 down", "0,0 up"])
        #expect(capture.chains == ["7 down"])
        #expect(capture.keys == ["15 down", "0 down"])
    }

    // MARK: - Matrix

    @Test func matrixNoteOnWithVelocityZeroReleases() {
        let (driver, capture) = Self.attach(MatrixDriver())
        driver.getSignal(cmd: Self.noteOn, sig: -112, note: 36, velocity: 100)
        driver.getSignal(cmd: Self.noteOn, sig: -112, note: 36, velocity: 0)
        driver.getSignal(cmd: Self.noteOn, sig: -112, note: 99, velocity: 100)
        driver.getSignal(cmd: Self.noteOff, sig: -128, note: 99, velocity: 64)
        driver.getSignal(cmd: Self.polyAftertouch, sig: -96, note: 99, velocity: 0)
        #expect(capture.pads == ["7,0 down", "7,0 up", "0,7 down", "0,7 up"])
    }

    /// Every ring note a Matrix reports is the button its LED code lights.
    @Test func matrixRingInputMatchesItsLeds() throws {
        for f in 0...31 {
            let (driver, capture) = Self.attach(MatrixDriver())
            driver.sendFunctionKeyLed(f: f, velocity: 1)
            let note = try #require(capture.sent.first).note
            driver.getSignal(cmd: Self.noteOn, sig: -112, note: Int(note), velocity: 127)
            #expect(capture.keys == ["\(f) down"], "ring button \(f) (note \(note))")
            #expect(capture.chains == ((8...31).contains(f) ? ["\(f - 8) down"] : []), "ring button \(f) (note \(note))")
        }
    }

    @Test func matrixLedsStayOnTheGridAndClearTheRing() {
        let (driver, capture) = Self.attach(MatrixDriver())
        driver.sendPadLed(x: 8, y: 0, velocity: 5)
        driver.sendPadLed(x: 0, y: 8, velocity: 5)
        driver.sendPadLed(x: -1, y: 0, velocity: 5)
        #expect(capture.sent.isEmpty)

        driver.sendChainLed(c: 8, velocity: 5)
        #expect(capture.sent.map(\.note) == [123])

        capture.sent.removeAll()
        driver.sendClearLed()
        #expect(capture.sent.count == 64 + 32)
        #expect(capture.sent.allSatisfy { $0.velocity == 0 })
    }

    // MARK: - Midi Fighter and master keyboard

    @Test func midiFighterNoteOnWithVelocityZeroReleases() {
        let (driver, capture) = Self.attach(MidiFighterDriver())
        driver.getSignal(cmd: Self.noteOn, sig: -112, note: 36, velocity: 100)
        driver.getSignal(cmd: Self.noteOn, sig: -112, note: 36, velocity: 0)
        driver.getSignal(cmd: Self.noteOn, sig: -112, note: 68, velocity: 100)
        driver.getSignal(cmd: Self.noteOff, sig: -128, note: 68, velocity: 64)
        driver.getSignal(cmd: Self.polyAftertouch, sig: -96, note: 68, velocity: 0)
        #expect(capture.pads == ["7,0 down", "7,0 up", "7,4 down", "7,4 up"])

        driver.sendPadLed(x: 8, y: 0, velocity: 5)
        driver.sendPadLed(x: 0, y: -1, velocity: 5)
        #expect(capture.sent.isEmpty)
    }

    @Test(arguments: [0, 1])
    func keyboardReleasesOnNoteOffWithAnyVelocity(port: Int) {
        let (driver, capture) = Self.attach(MasterKeyboardDriver())
        driver.getSignal(cmd: port << 4 | Self.noteOn, sig: -112, note: 36, velocity: 100)
        driver.getSignal(cmd: port << 4 | Self.noteOff, sig: -128, note: 36, velocity: 64)
        driver.getSignal(cmd: port << 4 | Self.noteOn, sig: -112, note: 99, velocity: 100)
        driver.getSignal(cmd: port << 4 | Self.noteOn, sig: -112, note: 99, velocity: 0)
        #expect(capture.pads == ["7,0 down", "7,0 up", "0,7 down", "0,7 up"])
    }

    @Test func keyboardIgnoresAftertouchAndControllers() {
        let (driver, capture) = Self.attach(MasterKeyboardDriver())
        driver.getSignal(cmd: Self.noteOn, sig: -112, note: 36, velocity: 100)
        driver.getSignal(cmd: Self.polyAftertouch, sig: -96, note: 36, velocity: 0)
        driver.getSignal(cmd: Self.controlChange, sig: -80, note: 36, velocity: 0)
        driver.getSignal(cmd: Self.channelPressure, sig: -48, note: 0, velocity: 0)
        #expect(capture.pads == ["7,0 down"])
    }
}
