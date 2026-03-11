import Foundation

/// Driver for Matrix-style MIDI controllers.
/// Supports 8x8 pad grid, 8 chain buttons, and 32 function keys.
final class MatrixDriver: BaseMidiDriver {
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
        var x: Int
        var y: Int

        switch cmd {
        case 9:
            switch note {
            case 36...67:
                x = (67 - note) / 4 + 1
                y = 4 - (67 - note) % 4
                onPadTouch(x: x - 1, y: y - 1, upDown: true, velocity: velocity)
            case 68...99:
                x = (99 - note) / 4 + 1
                y = 8 - (99 - note) % 4
                onPadTouch(x: x - 1, y: y - 1, upDown: true, velocity: velocity)
            case 100...107:
                let c = note - 100
                onChainTouch(c: c, upDown: velocity != 0)
                onFunctionKeyTouch(f: c + 8, upDown: velocity != 0)
            case 108...115:
                let c = 8 - (note - 108) + 8
                onFunctionKeyTouch(f: c + 8, upDown: velocity != 0)
            default:
                break
            }
        case 8:
            switch note {
            case 36...67:
                x = (67 - note) / 4 + 1
                y = 4 - (67 - note) % 4
                onPadTouch(x: x - 1, y: y - 1, upDown: false, velocity: velocity)
            case 68...99:
                x = (99 - note) / 4 + 1
                y = 8 - (99 - note) % 4
                onPadTouch(x: x - 1, y: y - 1, upDown: false, velocity: velocity)
            default:
                break
            }
        default:
            break
        }
    }

    override func sendPadLed(x: Int, y: Int, velocity: Int) {
        let padX = x + 1
        let padY = y + 1
        if (1...4).contains(padY) {
            sendSignal(cmd: 9, sig: -111, note: -4 * padX + padY + 67, velocity: velocity)
        } else if (5...8).contains(padY) {
            sendSignal(cmd: 9, sig: -111, note: -4 * padX + padY + 95, velocity: velocity)
        }
    }

    override func sendChainLed(c: Int, velocity: Int) {
        if (0...7).contains(c) {
            sendFunctionKeyLed(f: c + 8, velocity: velocity)
        }
    }

    override func sendFunctionKeyLed(f: Int, velocity: Int) {
        if (0...31).contains(f) {
            sendSignal(cmd: UInt8(truncatingIfNeeded: Self.circleCode[f][0]),
                       sig: UInt8(truncatingIfNeeded: Self.circleCode[f][1]),
                       note: UInt8(truncatingIfNeeded: Self.circleCode[f][2]),
                       velocity: UInt8(truncatingIfNeeded: velocity))
        }
    }

    override func sendClearLed() {
        for i in 0...7 {
            for j in 0...7 {
                sendPadLed(x: i, y: j, velocity: 0)
            }
        }
    }
}
