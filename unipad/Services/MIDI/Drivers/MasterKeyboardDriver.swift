import Foundation

/// Driver for standard MIDI keyboards (master keyboard).
/// Input-only driver that maps notes 36-99 to an 8x8 grid on the drum-rack layout. A key is released
/// by a note off, whatever its release velocity, or by a note on with velocity 0.
final class MasterKeyboardDriver: BaseMidiDriver {
    override func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        reportDrumRackPad(cmd: cmd, note: note, velocity: velocity)
    }
}
