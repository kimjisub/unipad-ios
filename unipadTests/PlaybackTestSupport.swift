import Foundation
@testable import unipad

/// SoundEngine reports an engine it cannot start (session or AVAudioEngine) before `onStart`, and a
/// pack none of whose sounds decode after it; only the first is this platform's limit. Both failures
/// can be NSError values, so the test harness relies on this callback order rather than error type.
/// Keep these callbacks on the main queue, as SoundEngine does.
final class TestSoundLoadListener: SoundEngine.LoadingListener {
    private(set) var finished = false
    private(set) var engineFailure: Error?
    private var lateFailure: Error?
    /// What the engine said of the pack's sound files when it finished.
    private(set) var report: SoundLoadReport?
    /// The pack uses sounds and none of them can play.
    var loadFailure: Error? {
        lateFailure ?? report.flatMap { $0.nothingPlays ? NothingPlays(report: $0) : nil }
    }
    var failure: Error? { engineFailure ?? loadFailure }
    private var started = false
    func onStart(soundCount: Int) { started = true }
    func onProgressTick() {}
    func onEnd(_ report: SoundLoadReport) {
        self.report = report
        finished = true
    }
    func onException(_ error: Error) {
        if started { lateFailure = error } else { engineFailure = error }
        finished = true
    }
}

struct NothingPlays: Error {
    let report: SoundLoadReport
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
