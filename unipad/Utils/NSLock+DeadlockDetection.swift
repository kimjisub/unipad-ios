import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "DeadlockDetection")

extension NSLock {
    /// Debug builds trap when a lock takes longer than `timeout`, which is how deadlocks in the
    /// runners were found. Release builds log the fault and keep waiting: a 5 s stall under thermal
    /// throttling, a priority inversion, or an app suspended mid-lock is not a deadlock, and
    /// killing the app for it lost sessions in production.
    func lockWithDeadlockDetection(
        timeout: TimeInterval = 5.0,
        file: String = #fileID,
        line: Int = #line
    ) {
        if !lock(before: Date(timeIntervalSinceNow: timeout)) {
            logger.fault("Deadlock suspected: NSLock not acquired within \(timeout)s at \(file):\(line)")
            #if DEBUG
            fatalError("Deadlock detected: NSLock not acquired within \(timeout)s at \(file):\(line)")
            #else
            lock()
            #endif
        }
    }
}
