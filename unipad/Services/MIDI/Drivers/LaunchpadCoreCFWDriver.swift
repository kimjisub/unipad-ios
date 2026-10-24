import Foundation

/// Unified driver for Novation Launchpad devices running the "Launchpad Core Firmware" (CoreFW).
/// Compatible with Launchpad Pro, MK2, S, Mini mk1, X, Mini MK3, and Pro MK3 running CoreFW.
final class LaunchpadCoreCFWDriver: BaseMidiDriver {
    /// How the device reads a note-on velocity as an LED colour.
    enum LedColors {
        /// Pro, MK2, X, Mini MK3 and Pro MK3: the velocity is an index into the device's palette.
        case palette
        /// Launchpad S and Mini mk1: red-green LEDs read the Launchpad S colour format.
        case redGreen
    }

    private static let channelLed = 0 // MIDI channel 1 (0x90)
    private static let statusNoteOn = 0x90 | channelLed
    private static let cinNoteOn = 0x09

    private let ledColors: LedColors

    init(ledColors: LedColors = .palette) {
        self.ledColors = ledColors
    }

    /// CoreFW boots in its own performance mode, which is the layout this driver speaks. The stock
    /// firmwares' mode and layout selection messages are left out so they cannot switch it away.
    override func getInitSysEx() -> (messages: [[UInt8]], cableNumber: Int)? {
        return (messages: [
            // Pro: set all LEDs to colour 0
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x0E, 0x00, 0xF7],
            // MK2: set all LEDs to colour 0
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x18, 0x0E, 0x00, 0xF7],
            // X: clear session, drum rack and CC LEDs
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x12, 0x01, 0x01, 0x01, 0xF7],
            // Mini MK3: clear session and CC LEDs
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0D, 0x12, 0x01, 0x00, 0x01, 0xF7],
        ], cableNumber: 0)
    }

    override func initialize() {
        if let initData = getInitSysEx() {
            sendRawSignals(messages: initData.messages, cableNumber: initData.cableNumber)
        }
    }

    override func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        let cin = cmd & 0x0F
        guard cin == 8 || cin == 9 else { return }
        let isDown = cin == 9 && velocity > 0

        if let pad = DrumRackLayout.pad(note: note) {
            onPadTouch(x: pad.x, y: pad.y, upDown: isDown, velocity: velocity)
            return
        }
        switch note {
        case 28...35:
            onFunctionKeyTouch(f: note - 28, upDown: isDown)
        case 100...107:
            let c = note - 100
            onChainTouch(c: c, upDown: isDown)
            onFunctionKeyTouch(f: c + 8, upDown: isDown)
        case 116...123:
            let c = 15 - (note - 116)
            onChainTouch(c: c, upDown: isDown)
            onFunctionKeyTouch(f: c + 8, upDown: isDown)
        case 108...115:
            let c = 23 - (note - 108)
            onChainTouch(c: c, upDown: isDown)
            onFunctionKeyTouch(f: c + 8, upDown: isDown)
        case 27:
            onFunctionKeyTouch(f: 32, upDown: isDown)
        default:
            onUnknownReceived(cmd: cmd, sig: sig, note: note, velocity: velocity)
        }
    }

    override func sendPadLed(x: Int, y: Int, velocity: Int) {
        guard let note = DrumRackLayout.note(x: x, y: y) else { return }
        sendLed(note: note, velocity: velocity)
    }

    override func sendChainLed(c: Int, velocity: Int) {
        if (0...23).contains(c) {
            sendFunctionKeyLed(f: c + 8, velocity: velocity)
        }
    }

    override func sendFunctionKeyLed(f: Int, velocity: Int) {
        let note: Int
        switch f {
        case 0...7: note = 28 + f
        case 8...15: note = 100 + (f - 8)
        case 16...23: note = 123 - (f - 16)
        case 24...31: note = 115 - (f - 24)
        case 32: note = 27
        default: return
        }
        sendLed(note: note, velocity: velocity)
    }

    private func sendLed(note: Int, velocity: Int) {
        let code = ledColors == .redGreen ? LaunchpadColor.sCodeClamped(velocity) : velocity
        sendSignal(cmd: Self.cinNoteOn, sig: Self.statusNoteOn, note: note, velocity: code)
    }

    override func sendClearLed() {
        for i in 0...7 {
            for j in 0...7 {
                sendPadLed(x: i, y: j, velocity: 0)
            }
        }
        for i in 0...32 {
            sendFunctionKeyLed(f: i, velocity: 0)
        }
    }
}
