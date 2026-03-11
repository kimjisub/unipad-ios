import Foundation

typealias GenericDriver = MasterKeyboardDriver

/// No-op driver used when no device is connected.
final class NotingDriver: BaseMidiDriver {
    override func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {}
}
