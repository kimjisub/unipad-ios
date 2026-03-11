import Foundation

final class LaunchpadMK2Driver: BaseMidiDriver {
    static let circleCode: [[Int]] = [
        [11, -80, 104],
        [11, -80, 105],
        [11, -80, 106],
        [11, -80, 107],
        [11, -80, 108],
        [11, -80, 109],
        [11, -80, 110],
        [11, -80, 111],
        [9, -112, 89],
        [9, -112, 79],
        [9, -112, 69],
        [9, -112, 59],
        [9, -112, 49],
        [9, -112, 39],
        [9, -112, 29],
        [9, -112, 19],
    ]

    override func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        if cmd == 9 {
            let x = 9 - note / 10
            let y = note % 10
            if (1...8).contains(y) {
                onPadTouch(x: x - 1, y: y - 1, upDown: velocity != 0, velocity: velocity)
            } else if y == 9 {
                onChainTouch(c: x - 1, upDown: velocity != 0)
                onFunctionKeyTouch(f: x - 1 + 8, upDown: velocity != 0)
            }
        } else if cmd == 11 {
            if (104...111).contains(note) {
                onFunctionKeyTouch(f: note - 104, upDown: velocity != 0)
            }
        }
    }

    override func sendPadLed(x: Int, y: Int, velocity: Int) {
        sendSignal(cmd: 9, sig: -112, note: 10 * (8 - x) + y + 1, velocity: velocity)
    }

    override func sendChainLed(c: Int, velocity: Int) {
        if (0...7).contains(c) {
            sendFunctionKeyLed(f: c + 8, velocity: velocity)
        }
    }

    override func sendFunctionKeyLed(f: Int, velocity: Int) {
        if (0...15).contains(f) {
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
        for i in 0...15 {
            sendFunctionKeyLed(f: i, velocity: 0)
        }
    }
}
