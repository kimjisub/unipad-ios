import Foundation

/// Launchpad Pro, Pro MK3, X and Mini MK3 in programmer mode: the pads are notes `10 * row + column`
/// (11 bottom-left to 88 top-right), the 32 round buttons around them are control changes, and the
/// logo is function key 32.
class LaunchpadProgrammerDriver: BaseMidiDriver {
    /// The round buttons' controllers by function key: top row left to right, right column top to
    /// bottom, bottom row right to left, left column bottom to top. Function keys 8...31 are chains 0...23.
    static let circleNotes: [Int] = [
        91, 92, 93, 94, 95, 96, 97, 98,
        89, 79, 69, 59, 49, 39, 29, 19,
        8, 7, 6, 5, 4, 3, 2, 1,
        10, 20, 30, 40, 50, 60, 70, 80,
    ]
    static let logoNote = 99

    override func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        if let down = Self.noteTouch(cmd: cmd, velocity: velocity) {
            let row = 9 - note / 10
            let column = note % 10
            if (1...8).contains(row) && (1...8).contains(column) {
                onPadTouch(x: row - 1, y: column - 1, upDown: down, velocity: velocity)
            }
        } else if Self.isControlChange(cmd) && sig == -80 {
            let down = velocity != 0
            if note == Self.logoNote {
                onFunctionKeyTouch(f: 32, upDown: down)
            } else if let f = Self.circleNotes.firstIndex(of: note) {
                if f >= 8 {
                    onChainTouch(c: f - 8, upDown: down)
                }
                onFunctionKeyTouch(f: f, upDown: down)
            }
        } else {
            onUnknownReceived(cmd: cmd, sig: sig, note: note, velocity: velocity)
        }
    }

    override func sendPadLed(x: Int, y: Int, velocity: Int) {
        guard Self.isOnGrid(x: x, y: y) else { return }
        sendSignal(cmd: 9, sig: -112, note: 10 * (8 - x) + y + 1, velocity: velocity)
    }

    override func sendChainLed(c: Int, velocity: Int) {
        if (0...23).contains(c) {
            sendFunctionKeyLed(f: c + 8, velocity: velocity)
        }
    }

    override func sendFunctionKeyLed(f: Int, velocity: Int) {
        if Self.circleNotes.indices.contains(f) {
            sendSignal(cmd: 11, sig: -80, note: Self.circleNotes[f], velocity: velocity)
        } else if f == 32 || f == 99 {
            sendLogoLed(velocity: velocity)
        }
    }

    /// Pro MK3, X and Mini MK3 light the logo with control change 99 on channel 1.
    func sendLogoLed(velocity: Int) {
        sendSignal(cmd: 11, sig: -80, note: Self.logoNote, velocity: velocity)
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
