import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "DeadlockDetection")

extension NSLock {
    func lockWithDeadlockDetection(
        timeout: TimeInterval = 5.0,
        file: String = #fileID,
        line: Int = #line
    ) {
        if !lock(before: Date(timeIntervalSinceNow: timeout)) {
            logger.fault("Deadlock detected: NSLock not acquired within \(timeout)s at \(file):\(line)")
            fatalError("Deadlock detected: NSLock not acquired within \(timeout)s at \(file):\(line)")
        }
    }
}
