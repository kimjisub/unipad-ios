import Foundation

/// Launchpad Pro MK2 running the "Launchpad Open" custom firmware (CFW).
/// Port of the Android `LaunchpadPROCFW` driver (unipad-android #25): performance mode,
/// note-on LEDs on channel 16, pads at notes 36...99 in two 4-wide column blocks,
/// ring buttons at 27...35 and 100...123.
final class LaunchpadProCFWDriver: BaseMidiDriver {
    private static let channelLed = 15 // MIDI channel 16
    private static let statusNoteOn = 0x90 | channelLed
    private static let cinNoteOn = 0x09

    override func getInitSysEx() -> (messages: [[UInt8]], cableNumber: Int)? {
        return (messages: [
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x21, 0x01, 0xF7], // Enter Performance Mode
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x0E, 0x00, 0xF7], // Clear canvas
        ], cableNumber: 0)
    }

    override func initialize() {
        guard let initData = getInitSysEx() else { return }
        sendRawSignals(messages: initData.messages, cableNumber: initData.cableNumber)
    }

    override func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        let cin = cmd & 0x0F
        guard cin == 8 || cin == 9 || cin == 11 else { return }
        let isDown = (cin == 9 || cin == 11) && velocity > 0

        if let pad = DrumRackLayout.pad(note: note) {
            onPadTouch(x: pad.x, y: pad.y, upDown: isDown, velocity: velocity)
            return
        }
        switch note {
        case 28...35:
            // Top row (f 0...7), left to right
            onFunctionKeyTouch(f: note - 28, upDown: isDown)
        case 100...107:
            // Right column (c 0...7 / f 8...15), top to bottom
            let c = note - 100
            onChainTouch(c: c, upDown: isDown)
            onFunctionKeyTouch(f: c + 8, upDown: isDown)
        case 116...123:
            // Bottom row (c 8...15 / f 16...23), right to left
            let c = 15 - (note - 116)
            onChainTouch(c: c, upDown: isDown)
            onFunctionKeyTouch(f: c + 8, upDown: isDown)
        case 108...115:
            // Left column (c 16...23 / f 24...31), bottom to top
            let c = 23 - (note - 108)
            onChainTouch(c: c, upDown: isDown)
            onFunctionKeyTouch(f: c + 8, upDown: isDown)
        case 27:
            // Top-right corner (Setup)
            onFunctionKeyTouch(f: 32, upDown: isDown)
        default:
            onUnknownReceived(cmd: cmd, sig: sig, note: note, velocity: velocity)
        }
    }

    override func sendPadLed(x: Int, y: Int, velocity: Int) {
        guard let note = DrumRackLayout.note(x: x, y: y) else { return }
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
        case 0...7: note = 28 + f             // Top, left to right (28...35)
        case 8...15: note = 100 + (f - 8)     // Right, top to bottom (100...107)
        case 16...23: note = 123 - (f - 16)   // Bottom, right to left (123...116)
        case 24...31: note = 115 - (f - 24)   // Left, bottom to top (115...108)
        case 32: note = 27                    // Top-right corner
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
