import Foundation

/// Driver for Matrix-style MIDI controllers.
/// Supports an 8x8 pad grid on the drum-rack layout and 32 round buttons, 24 of them chains.
final class MatrixDriver: BaseMidiDriver {
    /// The round buttons by function key: top row left to right, right column top to bottom, bottom
    /// row right to left, left column bottom to top. Function keys 8...31 are chains 0...23.
    static let circleCode: [[Int]] = [
        [9, -111, 28],
        [9, -111, 29],
        [9, -111, 30],
        [9, -111, 31],
        [9, -111, 32],
        [9, -111, 33],
        [9, -111, 34],
        [9, -111, 35],
        [9, -111, 100],
        [9, -111, 101],
        [9, -111, 102],
        [9, -111, 103],
        [9, -111, 104],
        [9, -111, 105],
        [9, -111, 106],
        [9, -111, 107],
        [9, -111, 123],
        [9, -111, 122],
        [9, -111, 121],
        [9, -111, 120],
        [9, -111, 119],
        [9, -111, 118],
        [9, -111, 117],
        [9, -111, 116],
        [9, -111, 115],
        [9, -111, 114],
        [9, -111, 113],
        [9, -111, 112],
        [9, -111, 111],
        [9, -111, 110],
        [9, -111, 109],
        [9, -111, 108],
    ]

    override func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        guard let down = Self.noteTouch(cmd: cmd, velocity: velocity) else { return }
        if let pad = DrumRackLayout.pad(note: note) {
            onPadTouch(x: pad.x, y: pad.y, upDown: down, velocity: velocity)
        } else if let f = Self.circleCode.firstIndex(where: { $0[2] == note }) {
            if f >= 8 {
                onChainTouch(c: f - 8, upDown: down)
            }
            onFunctionKeyTouch(f: f, upDown: down)
        }
    }

    override func sendPadLed(x: Int, y: Int, velocity: Int) {
        guard let note = DrumRackLayout.note(x: x, y: y) else { return }
        sendSignal(cmd: 9, sig: -111, note: note, velocity: velocity)
    }

    override func sendChainLed(c: Int, velocity: Int) {
        if (0...23).contains(c) {
            sendFunctionKeyLed(f: c + 8, velocity: velocity)
        }
    }

    override func sendFunctionKeyLed(f: Int, velocity: Int) {
        if (0...31).contains(f) {
            sendSignal(cmd: Self.circleCode[f][0],
                       sig: Self.circleCode[f][1],
                       note: Self.circleCode[f][2],
                       velocity: velocity)
        }
    }

    override func sendClearLed() {
        for i in 0...7 {
            for j in 0...7 {
                sendPadLed(x: i, y: j, velocity: 0)
            }
        }
        for i in 0...31 {
            sendFunctionKeyLed(f: i, velocity: 0)
        }
    }
}
