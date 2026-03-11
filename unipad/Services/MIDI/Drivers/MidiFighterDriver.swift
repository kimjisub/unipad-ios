import Foundation

/// Driver for DJ TechTools Midi Fighter.
/// Maps notes 36-99 to an 8x8 grid with separate note-on/note-off commands.
final class MidiFighterDriver: BaseMidiDriver {
    override func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        var x: Int
        var y: Int

        if cmd == 9 {
            if (36...67).contains(note) {
                x = (67 - note) / 4 + 1
                y = 4 - (67 - note) % 4
                onPadTouch(x: x - 1, y: y - 1, upDown: true, velocity: velocity)
            } else if (68...99).contains(note) {
                x = (99 - note) / 4 + 1
                y = 8 - (99 - note) % 4
                onPadTouch(x: x - 1, y: y - 1, upDown: true, velocity: velocity)
            }
        } else if cmd == 8 {
            if (36...67).contains(note) {
                x = (67 - note) / 4 + 1
                y = 4 - (67 - note) % 4
                onPadTouch(x: x - 1, y: y - 1, upDown: false, velocity: velocity)
            } else if (68...99).contains(note) {
                x = (99 - note) / 4 + 1
                y = 8 - (99 - note) % 4
                onPadTouch(x: x - 1, y: y - 1, upDown: false, velocity: velocity)
            }
        }
    }

    override func sendPadLed(x: Int, y: Int, velocity: Int) {
        let padX = x + 1
        let padY = y + 1
        if (1...4).contains(padY) {
            sendSignal(cmd: 9, sig: -110, note: -4 * padX + padY + 67, velocity: velocity)
        } else if (5...8).contains(padY) {
            sendSignal(cmd: 9, sig: -110, note: -4 * padX + padY + 95, velocity: velocity)
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
