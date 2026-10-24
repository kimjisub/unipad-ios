import Testing
@testable import unipad

/// What each controller driver reports for the messages a device sends, and what it sends for the
/// lights the play screen asks for. The expected values are the Android drivers' (and their tests').
struct MidiDriverSignalTests {
    final class Capture: MidiDriverReceiveSignalListener, MidiDriverSendSignalListener {
        struct Pad: Equatable { let x: Int, y: Int, down: Bool }
        struct Key: Equatable { let f: Int, down: Bool }
        struct Chain: Equatable { let c: Int, down: Bool }
        struct Sent: Equatable { let note: UInt8, velocity: UInt8 }

        var pads: [Pad] = []
        var chains: [Chain] = []
        var keys: [Key] = []
        var sent: [Sent] = []
        var raw: [[UInt8]] = []

        func onReceived(cmd: Int, sig: Int, note: Int, velocity: Int) {}
        func onUnknownReceived(cmd: Int, sig: Int, note: Int, velocity: Int) {}
        func onPadTouch(x: Int, y: Int, upDown: Bool, velocity: Int) { pads.append(Pad(x: x, y: y, down: upDown)) }
        func onChainTouch(c: Int, upDown: Bool) { chains.append(Chain(c: c, down: upDown)) }
        func onFunctionKeyTouch(f: Int, upDown: Bool) { keys.append(Key(f: f, down: upDown)) }
        func onSend(cmd: UInt8, sig: UInt8, note: UInt8, velocity: UInt8) { sent.append(Sent(note: note, velocity: velocity)) }
        func onSendRaw(messages: [[UInt8]], cableNumber: Int) { raw += messages }
    }

    private func attach<D: BaseMidiDriver>(_ driver: D) -> (D, Capture) {
        let capture = Capture()
        driver.receiveSignalListener = capture
        driver.sendSignalListener = capture
        return (driver, capture)
    }

    // MARK: - Launchpad Pro MK3

    @MainActor
    @Test func originalLaunchpadUsesTheLegacyPadAndRedGreenLightMap() throws {
        let entry = try #require(MidiManager.driverEntry(forName: "Launchpad"))
        let driver = entry.factory()
        let capture = Capture()
        driver.receiveSignalListener = capture
        driver.sendSignalListener = capture
        driver.getSignal(cmd: 9, sig: -112, note: 0, velocity: 127)
        driver.getSignal(cmd: 9, sig: -112, note: 119, velocity: 0)
        driver.getSignal(cmd: 11, sig: -80, note: 104, velocity: 127)
        driver.getSignal(cmd: 9, sig: -112, note: 120, velocity: 127)
        #expect(capture.pads == [.init(x: 0, y: 0, down: true), .init(x: 7, y: 7, down: false)])
        #expect(capture.keys == [.init(f: 0, down: true), .init(f: 15, down: true)])
        #expect(capture.chains == [.init(c: 7, down: true)])
        driver.sendPadLed(x: 0, y: 0, velocity: 5)
        driver.sendPadLed(x: 7, y: 7, velocity: 5)
        #expect(capture.sent == [.init(note: 0, velocity: 2), .init(note: 119, velocity: 2)])
    }

    /// Programmer mode reports presses on the first ("MIDI") interface and lights LEDs sent to it;
    /// the second interface is the DIN jacks (Launchpad Pro [MK3] Programmer's Reference).
    @MainActor
    @Test func proMK3UsesItsFirstInterface() {
        for name in ["LPProMK3 MIDI", "Launchpad Pro MK3"] {
            #expect(MidiManager.driverEntry(forName: name)?.preferredPort == 0, "\(name)")
        }
        for name in ["LPX MIDI", "LPMiniMK3 MIDI"] {
            #expect(MidiManager.driverEntry(forName: name)?.preferredPort == 1, "\(name): the X and Mini MK3 report on their second interface")
        }
    }

    /// A press reaches the play screen whichever port number the connection gives it.
    @Test func proMK3PressesArriveOnEitherPort() {
        let (driver, capture) = attach(LaunchpadProMK3Driver())
        driver.getSignal(cmd: 9, sig: -112, note: 81, velocity: 100)
        driver.getSignal(cmd: 9, sig: -112, note: 81, velocity: 0)
        driver.getSignal(cmd: 25, sig: -112, note: 18, velocity: 80)
        driver.getSignal(cmd: 27, sig: -80, note: 89, velocity: 127)
        #expect(capture.pads == [.init(x: 0, y: 0, down: true), .init(x: 0, y: 0, down: false), .init(x: 7, y: 7, down: true)])
        #expect(capture.chains == [.init(c: 0, down: true)])
        #expect(capture.keys == [.init(f: 8, down: true)])
    }

    /// The top row (91…98) is a row of round buttons, not a pad row above the grid.
    @Test func proMK3TopRowNoteIsNotAPad() {
        let (driver, capture) = attach(LaunchpadProMK3Driver())
        driver.getSignal(cmd: 9, sig: -112, note: 91, velocity: 100)
        #expect(capture.pads.isEmpty)
    }

    // MARK: - Matrix / Mystrix

    @Test func matrixNoteOnWithVelocityZeroIsARelease() {
        let (driver, capture) = attach(MatrixDriver())
        driver.getSignal(cmd: 9, sig: -112, note: 36, velocity: 100)
        driver.getSignal(cmd: 9, sig: -112, note: 36, velocity: 0)
        driver.getSignal(cmd: 9, sig: -112, note: 99, velocity: 0)
        driver.getSignal(cmd: 8, sig: -128, note: 99, velocity: 0)
        #expect(capture.pads == [
            .init(x: 7, y: 0, down: true), .init(x: 7, y: 0, down: false),
            .init(x: 0, y: 7, down: false), .init(x: 0, y: 7, down: false),
        ])
    }

    /// Every round button the driver lights is read back as the same button: top row 28…35 (keys
    /// 0…7), right column 100…107 (chains 1…8), bottom row 123…116 (chains 9…16), left column
    /// 115…108 (chains 17…24).
    @Test func matrixRoundButtonsReadBackAsTheButtonsTheyLight() {
        let (driver, capture) = attach(MatrixDriver())
        for f in 0..<32 {
            capture.keys.removeAll(); capture.chains.removeAll()
            driver.getSignal(cmd: 9, sig: -112, note: MatrixDriver.circleCode[f][2], velocity: 127)
            #expect(capture.keys == [.init(f: f, down: true)], "key \(f)")
            #expect(capture.chains == (f < 8 ? [] : [.init(c: f - 8, down: true)]), "key \(f)")
        }
        capture.keys.removeAll(); capture.chains.removeAll()
        driver.getSignal(cmd: 9, sig: -112, note: 116, velocity: 0)
        #expect(capture.chains == [.init(c: 15, down: false)])
        #expect(capture.keys == [.init(f: 23, down: false)])
    }

    /// Leaving the play screen or changing the device turns off the round buttons as well as the pads.
    @Test func matrixClearTurnsOffTheRoundButtons() {
        let (driver, capture) = attach(MatrixDriver())
        driver.sendClearLed()
        let ring = Set(MatrixDriver.circleCode.map { UInt8($0[2]) })
        #expect(capture.sent.count == 96)
        #expect(ring.isSubset(of: Set(capture.sent.map(\.note))))
        #expect(capture.sent.allSatisfy { $0.velocity == 0 })
    }

    // MARK: - Master keyboard and unknown devices

    /// Also the reading of any device UniPad has no driver for (`GenericDriver`).
    @Test func masterKeyboardReleasesOnNoteOffOnly() {
        let (driver, capture) = attach(GenericDriver())
        driver.getSignal(cmd: 9, sig: -112, note: 36, velocity: 100)
        driver.getSignal(cmd: 11, sig: -80, note: 64, velocity: 0)   // sustain pedal up
        driver.getSignal(cmd: 11, sig: -80, note: 36, velocity: 0)   // any controller at 0
        driver.getSignal(cmd: 14, sig: -32, note: 0, velocity: 0)    // pitch bend
        driver.getSignal(cmd: 8, sig: -128, note: 36, velocity: 64)  // note-off with a release velocity
        driver.getSignal(cmd: 9, sig: -112, note: 99, velocity: 0)   // note-on at velocity 0
        #expect(capture.pads == [.init(x: 7, y: 0, down: true), .init(x: 7, y: 0, down: false), .init(x: 0, y: 7, down: false)])
    }

    // MARK: - Midi Fighter

    @Test func midiFighterNoteOnWithVelocityZeroIsARelease() {
        let (driver, capture) = attach(MidiFighterDriver())
        driver.getSignal(cmd: 9, sig: -110, note: 36, velocity: 100)
        driver.getSignal(cmd: 9, sig: -110, note: 36, velocity: 0)
        driver.getSignal(cmd: 8, sig: -126, note: 99, velocity: 0)
        #expect(capture.pads == [.init(x: 7, y: 0, down: true), .init(x: 7, y: 0, down: false), .init(x: 0, y: 7, down: false)])
    }

    // MARK: - Pads the device does not have

    /// A pack may be up to 64 pads on a side. Its pads past the device's 8×8 have no LED; their
    /// light must not land on a round button or another pad.
    @Test func padsOutsideTheEightByEightGridSendNothing() {
        let drivers: [(String, BaseMidiDriver)] = [
            ("Launchpad X", LaunchpadXDriver()), ("Launchpad Mini MK3", LaunchpadMiniMK3Driver()),
            ("Launchpad MK2", LaunchpadMK2Driver()), ("Launchpad Pro", LaunchpadProDriver()),
            ("Launchpad Pro MK3", LaunchpadProMK3Driver()), ("Matrix", MatrixDriver()),
            ("Midi Fighter", MidiFighterDriver()), ("Launchpad S", LaunchpadSDriver()),
            ("Launchpad Pro CFW", LaunchpadProCFWDriver()), ("CoreFW", LaunchpadCoreCFWDriver()),
        ]
        for (name, driver) in drivers {
            let (driver, capture) = attach(driver)
            for (x, y) in [(8, 0), (0, 8), (8, 8), (-1, 0), (0, -1), (9, 3), (3, 15)] {
                driver.sendPadLed(x: x, y: y, velocity: 5)
            }
            #expect(capture.sent.isEmpty, "\(name) sent \(capture.sent)")
            driver.sendPadLed(x: 7, y: 7, velocity: 5)
            #expect(capture.sent.count == 1, "\(name) did not light the last pad of the grid")
        }
    }
}
