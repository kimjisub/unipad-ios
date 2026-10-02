import Foundation

/// A device boundary for deterministic tests. The shared manager uses CoreMIDI directly.
/// Input uses the same status/note/velocity representation as CoreMIDI's read callback.
@MainActor
protocol MidiTransport: AnyObject {
    var deviceNames: [String] { get }
    func start(receive: @escaping @MainActor (Int, Int, Int, Int) -> Void)
    func connect(index: Int) -> Bool
    func disconnect()
    func stop()
    func send(_ bytes: [UInt8])
}
