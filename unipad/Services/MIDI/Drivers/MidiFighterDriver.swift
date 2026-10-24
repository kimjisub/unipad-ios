import Foundation

/// Driver for DJ TechTools Midi Fighter.
/// Maps notes 36-99 to an 8x8 grid on the drum-rack layout.
final class MidiFighterDriver: BaseMidiDriver {
    override func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        reportDrumRackPad(cmd: cmd, note: note, velocity: velocity)
    }

    override func sendPadLed(x: Int, y: Int, velocity: Int) {
        guard let note = DrumRackLayout.note(x: x, y: y) else { return }
        sendSignal(cmd: 9, sig: -110, note: note, velocity: velocity)
    }

    override func sendClearLed() {
        for i in 0...7 {
            for j in 0...7 {
                sendPadLed(x: i, y: j, velocity: 0)
            }
        }
    }
}
