import Foundation

final class LaunchpadProDriver: BaseMidiDriver {
    static let circleCode: [[Int]] = [
        [11, -80, 91], [11, -80, 92], [11, -80, 93], [11, -80, 94],
        [11, -80, 95], [11, -80, 96], [11, -80, 97], [11, -80, 98],
        [11, -80, 89], [11, -80, 79], [11, -80, 69], [11, -80, 59],
        [11, -80, 49], [11, -80, 39], [11, -80, 29], [11, -80, 19],
        [11, -80, 8],  [11, -80, 7],  [11, -80, 6],  [11, -80, 5],
        [11, -80, 4],  [11, -80, 3],  [11, -80, 2],  [11, -80, 1],
        [11, -80, 10], [11, -80, 20], [11, -80, 30], [11, -80, 40],
        [11, -80, 50], [11, -80, 60], [11, -80, 70], [11, -80, 80],
    ]

    override func getInitSysEx() -> (messages: [[UInt8]], cableNumber: Int)? {
        // Launchpad Pro (original): Live/Ableton mode + Session layout
        return (messages: [
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x21, 0x00, 0xF7],
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x22, 0x00, 0xF7],
        ], cableNumber: 0)
    }

    override func initialize() {
        guard let initData = getInitSysEx() else { return }
        for cable in 0...1 {
            sendRawSignals(messages: initData.messages, cableNumber: cable)
        }
    }

    override func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        if cmd == 9 {
            let x = 9 - note / 10
            let y = note % 10
            if (1...8).contains(y) {
                onPadTouch(x: x - 1, y: y - 1, upDown: velocity != 0, velocity: velocity)
            }
        }
        if cmd == 11 && sig == -80 {
            if (91...98).contains(note) {
                onFunctionKeyTouch(f: note - 91, upDown: velocity != 0)
            }
            if (19...89).contains(note) && note % 10 == 9 {
                let c = 9 - note / 10 - 1
                onChainTouch(c: c, upDown: velocity != 0)
                onFunctionKeyTouch(f: c + 8, upDown: velocity != 0)
            }
            if (1...8).contains(note) {
                onChainTouch(c: 8 - note + 16 - 8, upDown: velocity != 0)
                onFunctionKeyTouch(f: 8 - note + 16, upDown: velocity != 0)
            }
            if (10...80).contains(note) && note % 10 == 0 {
                onChainTouch(c: note / 10 - 1 + 24 - 8, upDown: velocity != 0)
                onFunctionKeyTouch(f: note / 10 - 1 + 24, upDown: velocity != 0)
            }
        } else {
            onUnknownReceived(cmd: cmd, sig: sig, note: note, velocity: velocity)
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
