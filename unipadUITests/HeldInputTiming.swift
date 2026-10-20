import Foundation

/// Offsets use the monotonic clock, measured from just before invoking the gesture.
struct HeldInputTiming {
    let started: TimeInterval
    let completed: TimeInterval

    // A gesture cannot finish its requested hold earlier than invocation + duration.
    // Allow no observation in the last quarter second, or after an early command return.
    static let releaseMargin: TimeInterval = 0.25

    func finishedWhileHeld(duration: TimeInterval, commandReturned: TimeInterval) -> Bool {
        started >= 0 && completed >= started
            && completed < duration - Self.releaseMargin && completed < commandReturned
    }
}
