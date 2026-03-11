import Foundation

/// Driver for standard MIDI keyboards (master keyboard).
/// Input-only driver that maps notes 36-99 to an 8x8 grid.
/// Uses velocity == 0 as note-off for keyboards that send note-on with zero velocity
/// instead of a separate note-off command.
final class MasterKeyboardDriver: BaseMidiDriver {
    override func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        var x: Int
        var y: Int

        if cmd == 9 {
            if (36...67).contains(note) {
                x = (67 - note) / 4 + 1
                y = 4 - (67 - note) % 4
                onPadTouch(x: x - 1, y: y - 1, upDown: velocity != 0, velocity: velocity)
            } else if (68...99).contains(note) {
                x = (99 - note) / 4 + 1
                y = 8 - (99 - note) % 4
                onPadTouch(x: x - 1, y: y - 1, upDown: velocity != 0, velocity: velocity)
            }
        } else if velocity == 0 {
            if (36...67).contains(note) {
                x = (67 - note) / 4 + 1
                y = 4 - (67 - note) % 4
                onPadTouch(x: x - 1, y: y - 1, upDown: false, velocity: 0)
            } else if (68...99).contains(note) {
                x = (99 - note) / 4 + 1
                y = 8 - (99 - note) % 4
                onPadTouch(x: x - 1, y: y - 1, upDown: false, velocity: 0)
            }
        }
    }
}
