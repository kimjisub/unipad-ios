import Foundation

/// Driver for Novation Launchpad S.
/// Uses Launchpad S color codes (4-bit velocity mapping via LaunchpadColor.sCode).
final class LaunchpadSDriver: BaseMidiDriver {
    static let circleCode: [[Int]] = [
        [11, -80, 104],
        [11, -80, 105],
        [11, -80, 106],
        [11, -80, 107],
        [11, -80, 108],
        [11, -80, 109],
        [11, -80, 110],
        [11, -80, 111],
        [9, -112, 8],
        [9, -112, 24],
        [9, -112, 40],
        [9, -112, 56],
        [9, -112, 72],
        [9, -112, 88],
        [9, -112, 104],
        [9, -112, 120],
    ]

    override func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        if cmd == 9 {
            let x = note / 16 + 1
            let y = note % 16 + 1
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
        guard (0...7).contains(x), (0...7).contains(y) else { return }
        sendSignal(cmd: 9, sig: -112, note: x * 16 + y, velocity: Self.sCode(velocity))
    }

    /// velocity is a LED code read out of a pack (`on 1 1 a 200` is valid text); sCode has 128 entries.
    private static func sCode(_ velocity: Int) -> Int {
        LaunchpadColor.sCode[min(max(velocity, 0), LaunchpadColor.sCode.count - 1)]
    }

    override func sendChainLed(c: Int, velocity: Int) {
        if (0...7).contains(c) {
            sendFunctionKeyLed(f: c + 8, velocity: velocity)
        }
    }

    override func sendFunctionKeyLed(f: Int, velocity: Int) {
        if (0...15).contains(f) {
            sendSignal(cmd: UInt8(truncatingIfNeeded: Self.circleCode[f][0]),
                       sig: UInt8(truncatingIfNeeded: Self.circleCode[f][1]),
                       note: UInt8(truncatingIfNeeded: Self.circleCode[f][2]),
                       velocity: UInt8(truncatingIfNeeded: Self.sCode(velocity)))
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
