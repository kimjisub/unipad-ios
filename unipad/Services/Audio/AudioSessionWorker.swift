import Foundation

/// The serial queue that owns the audio calls which can block on the audio server: configuring and
/// activating the session, starting and stopping the engine, and attaching or detaching its nodes.
///
/// AVAudioSession warns that these "can lead to UI unresponsiveness if called on the main thread",
/// and before this queue existed a route change or the end of an interruption made the pad press
/// that followed wait for them. Callers hand work over and hear back on the main queue; nothing on
/// the main thread ever waits for this queue, so it cannot stall the screen. The session is shared by
/// the whole app, so there is one queue: work for one pack's engine runs after the previous pack's.
nonisolated final class AudioSessionWorker: @unchecked Sendable {
    static let shared = AudioSessionWorker()

    private init() {}

    private let queue = DispatchQueue(label: "UniPad.audioSession", qos: .userInitiated)

    /// Runs `work` on the queue, then `completion` with its result on the main queue.
    func run<Result>(_ work: @escaping () -> Result, then completion: @escaping (Result) -> Void) {
        queue.async {
            let result = work()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Runs `work` on the queue, after everything handed over before it.
    func run(_ work: @escaping () -> Void) {
        queue.async { work() }
    }
}
