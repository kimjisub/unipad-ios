import Foundation
@testable import unipad

/// SoundEngine reports an engine it cannot start (session or AVAudioEngine) before `onStart`, and a
/// pack none of whose sounds decode after it; only the first is this platform's limit. Both failures
/// can be NSError values, so the test harness relies on this callback order rather than error type.
/// Keep these callbacks on the main queue, as SoundEngine does.
final class TestSoundLoadListener: SoundEngine.LoadingListener {
    private(set) var finished = false
    private(set) var engineFailure: Error?
    private(set) var loadFailure: Error?
    var failure: Error? { engineFailure ?? loadFailure }
    private var started = false
    func onStart(soundCount: Int) { started = true }
    func onProgressTick() {}
    func onEnd() { finished = true }
    func onException(_ error: Error) {
        if started { loadFailure = error } else { engineFailure = error }
        finished = true
    }
}

final class TestManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Int64 = 1000
    private var reads = 0

    func read() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return now
    }

    var wasRead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reads > 0
    }

    func advance(_ ms: Int64) {
        lock.lock()
        now += ms
        lock.unlock()
    }
}
