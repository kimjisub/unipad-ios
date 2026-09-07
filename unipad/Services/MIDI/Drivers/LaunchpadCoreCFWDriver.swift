import Foundation

/// Unified driver for Novation Launchpad devices running the "Launchpad Core Firmware" (CoreFW).
/// Compatible with Launchpad Pro, MK2, S, Mini mk1, X, Mini MK3, and Pro MK3 running CoreFW.
final class LaunchpadCoreCFWDriver: BaseMidiDriver {
    private static let channelLed = 0 // MIDI channel 1 (0x90)
    private static let statusNoteOn = 0x90 | channelLed
    private static let cinNoteOn = 0x09

    override func getInitSysEx() -> (messages: [[UInt8]], cableNumber: Int)? {
        return (messages: [
            // Pro: Enter Performance Mode + Clear canvas 
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x22, 0x03, 0xF7],
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x0E, 0x00, 0xF7],
            // MK2: Enter Performance Mode + Clear canvas 
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x18, 0x22, 0x01, 0xF7],
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x18, 0x0E, 0x00, 0xF7],
            // X: Enter Performance Mode + Clear canvas
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x00, 0x7E, 0xF7],
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x12, 0x01, 0x01, 0x01, 0xF7],
            // Mini MK3: Enter Performance Mode + Clear canvas
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0D, 0x00, 0x7E, 0xF7],
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0D, 0x12, 0x01, 0x00, 0x01, 0xF7],
            // Pro MK3: Enter Performance Mode + Clear canvas
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0E, 0x00, 0x14, 0x00, 0x00, 0xF7],
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

        switch note {
        case 36...99:
            let index = note - 36
            let row = 7 - (index % 32) / 4
            let col = index < 32 ? index % 4 : (index % 4) + 4
            onPadTouch(x: row, y: col, upDown: isDown, velocity: velocity)
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
        guard (0...7).contains(x), (0...7).contains(y) else { return }
        let rowInverted = 7 - x
        let note = y < 4 ? 36 + rowInverted * 4 + y : 68 + rowInverted * 4 + (y - 4)
        sendSignal(cmd: Self.cinNoteOn, sig: Self.statusNoteOn, note: note, velocity: velocity)
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
        sendSignal(cmd: Self.cinNoteOn, sig: Self.statusNoteOn, note: note, velocity: velocity)
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
