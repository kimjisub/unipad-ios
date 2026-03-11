import Foundation

class LaunchpadXDriver: BaseMidiDriver {
    static let circleCode: [[Int]] = [
        [27, -80, 91], [27, -80, 92], [27, -80, 93], [27, -80, 94],
        [27, -80, 95], [27, -80, 96], [27, -80, 97], [27, -80, 98],
        [27, -80, 89], [27, -80, 79], [27, -80, 69], [27, -80, 59],
        [27, -80, 49], [27, -80, 39], [27, -80, 29], [27, -80, 19],
        [27, -80, 8],  [27, -80, 7],  [27, -80, 6],  [27, -80, 5],
        [27, -80, 4],  [27, -80, 3],  [27, -80, 2],  [27, -80, 1],
        [27, -80, 10], [27, -80, 20], [27, -80, 30], [27, -80, 40],
        [27, -80, 50], [27, -80, 60], [27, -80, 70], [27, -80, 80],
    ]

    override func getInitSysEx() -> (messages: [[UInt8]], cableNumber: Int)? {
        // Launchpad X: Standalone mode + Programmer mode via DAW port
        return (messages: [
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x10, 0x00, 0xF7],
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x0E, 0x01, 0xF7],
        ], cableNumber: 1)
    }

    override func initialize() {
        guard let initData = getInitSysEx() else { return }
        sendRawSignals(messages: initData.messages, cableNumber: initData.cableNumber)
    }

    override func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        if cmd == 25 {
            let x = 9 - note / 10
            let y = note % 10
            if (1...8).contains(x) && (1...8).contains(y) {
                onPadTouch(x: x - 1, y: y - 1, upDown: velocity != 0, velocity: velocity)
            }
        } else if cmd == 27 && sig == -80 {
            if (91...98).contains(note) {
                onFunctionKeyTouch(f: note - 91, upDown: velocity != 0)
            }
            if (19...89).contains(note) && note % 10 == 9 {
                let c = 9 - note / 10 - 1
                onChainTouch(c: c, upDown: velocity != 0)
                onFunctionKeyTouch(f: c + 8, upDown: velocity != 0)
            }
            if (1...8).contains(note) {
                onChainTouch(c: 16 - note, upDown: velocity != 0)
                onFunctionKeyTouch(f: 24 - note, upDown: velocity != 0)
            }
            if (10...80).contains(note) && note % 10 == 0 {
                onChainTouch(c: note / 10 + 15, upDown: velocity != 0)
                onFunctionKeyTouch(f: note / 10 + 23, upDown: velocity != 0)
            }
        } else {
            onUnknownReceived(cmd: cmd, sig: sig, note: note, velocity: velocity)
        }
    }

    override func sendPadLed(x: Int, y: Int, velocity: Int) {
        sendSignal(cmd: 25, sig: -112, note: 10 * (8 - x) + y + 1, velocity: velocity)
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
        for i in 0...31 {
            sendFunctionKeyLed(f: i, velocity: 0)
        }
    }
}
