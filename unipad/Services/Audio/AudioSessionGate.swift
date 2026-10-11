import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "AudioSessionGate")

/// Decides whether it is safe to call `play()` on a player node.
///
/// `AVAudioEngine.isRunning` keeps reporting `true` after the audio session has been interrupted or
/// deactivated behind our back, and starting a player node on an engine that is not rendering makes
/// AVFoundation raise the Objective-C exception "player did not see an IO cycle". Swift cannot catch
/// that, so the app dies (Crashlytics d4b0a4e558fdcbcebc06341cd87ba6f6).
///
/// This type owns the small state machine that the notifications drive, so the decision can be unit
/// tested without an audio device: every call into AVFoundation goes through `Hooks`.
///
/// Threads: the state machine lives on the main thread. Taking the session back and restarting the
/// engine block on the audio server, so they run through `Hooks.runOffMain` (the app's
/// `AudioSessionWorker`) and their result comes back on the main queue. Nothing waits for it: the pad
/// that asks for a recovery is silent, like every pad while playback is suppressed, and the pads after
/// the recovery play. Only the newest recovery's result is applied; anything that happened after it
/// was asked for (another interruption, a route change, `shutDown()`) makes it stale. So the gate is
/// `.ready` only when no recovery of ours is left on the worker, and `play()` never runs while one is.
///
/// The state machine:
///
/// - `.ready`: normal. `ensureEngineRunning()` costs one enum check plus `isEngineRunning()`.
/// - `.interrupted`: another app holds the session (a call came in). An interruption does not always
///   end with a notification (after an answered call the app is suspended and may never hear it), so
///   the app coming back (`appBecameActive()`) and a pad press, at most once per
///   `interruptedRetryInterval`, try to take the session back. Activation fails while the other app
///   still holds it, and the state stays `.interrupted` for the next try.
/// - `.needsRecovery`: the session is ours again but the engine is not known to render yet. The next
///   `ensureEngineRunning()` asks for the session to be re-activated and the engine restarted, and only
///   a verified running engine clears the state. After a pad's try fails, the next pads wait
///   `interruptedRetryInterval` before trying again (autoplay presses pads many times a second); a
///   notification lets the next pad try at once.
/// - `.shutDown`: the owner called `destroy()`. Terminal; a late notification cannot resurrect it.
final class AudioSessionGate {
    // SoundEngine releases this gate during its main-actor teardown. Destruction only releases
    // stored state and hooks; it never invokes the hooks or performs audio/UI work. Avoid Swift's
    // older-runtime isolated-deinit task-local cleanup crash when no current task exists (#88036).
    nonisolated deinit {}

    enum State: Equatable {
        case ready
        case interrupted
        case needsRecovery
        case shutDown
    }

    enum Recovery: Equatable {
        case recovered
        case stillSuppressed
    }

    /// What one try to take the session back and restart the engine found, on the worker.
    nonisolated enum Attempt: Sendable {
        case recovered
        case failed(String)
    }

    /// Everything that touches AVFoundation, injected so the state machine is testable.
    nonisolated struct Hooks {
        /// `AVAudioEngine.isRunning`. Read on the main thread and, during a recovery, on the worker.
        var isEngineRunning: () -> Bool
        /// Re-applies the category and preferences and calls `setActive(true)`. Must be idempotent:
        /// it also runs after a media services reset, when the category is gone. Runs on the worker.
        var activateSession: () throws -> Void
        /// `AVAudioEngine.start()`. Runs on the worker.
        var startEngine: () throws -> Void
        /// Runs a recovery away from the main thread and hands its result back on the main queue.
        var runOffMain: (_ work: @escaping () -> Attempt, _ completion: @escaping (Attempt) -> Void) -> Void
        /// A monotonic clock in seconds, for spacing the retries of an interrupted session.
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }

    /// How long pads stay ignored after an interruption began or after a pad's failed try to take the
    /// session back. Activation fails while a call is on; this keeps it off most pad presses.
    static let interruptedRetryInterval: TimeInterval = 1

    /// Settable so the owner's tests can make the session refuse, which a simulator never does.
    var hooks: Hooks
    private(set) var state: State = .ready
    /// Counts the log lines the gate has written about the current suppression, so a stuck session
    /// does not write one line per pad press.
    private(set) var suppressionLogCount = 0
    /// How often `mediaServicesWereReset` has been seen. Read by tests and by the PR description.
    private(set) var mediaServicesResetCount = 0
    private var lastInterruptedAttempt: TimeInterval = 0
    /// When a pad's try to recover from `.needsRecovery` last failed; nil once something changed.
    private var lastFailedPadRecovery: TimeInterval?
    /// Moves on with every event and every recovery asked for; a recovery whose generation is no
    /// longer current comes back stale and changes nothing.
    private var generation = 0
    /// A recovery for the current generation is on the worker, so a pad has nothing to add.
    private(set) var isRecovering = false

    var isPlaybackSuppressed: Bool { state != .ready }

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    // MARK: - Notifications

    /// `AVAudioSession.interruptionNotification` with type `.began`.
    func interruptionBegan() {
        guard state != .shutDown else { return }
        state = .interrupted
        invalidateRecovery()
        lastInterruptedAttempt = hooks.now()
        suppressionLogCount = 0
        logSuppressionOnce("audio session interrupted; playback suppressed")
    }

    /// `AVAudioSession.interruptionNotification` with type `.ended`.
    ///
    /// Only `.shouldResume` makes us re-activate right away. Without it the gate stays suppressed and
    /// waits for the user: the next pad press is the user asking for sound, and that press asks for
    /// the same recovery through `ensureEngineRunning()`. `completion` hears whether playback is back.
    func interruptionEnded(shouldResume: Bool, completion: ((Recovery) -> Void)? = nil) {
        guard state != .shutDown else { completion?(.stillSuppressed); return }
        enterNeedsRecovery()
        guard shouldResume else { completion?(.stillSuppressed); return }
        requestRecovery(completion: completion)
    }

    /// `AVAudioSession.mediaServicesWereResetNotification`. The audio server died and took the
    /// session configuration with it, so nothing may be played until the session has been configured
    /// again and the engine reports that it runs.
    func mediaServicesWereReset(completion: ((Recovery) -> Void)? = nil) {
        guard state != .shutDown else { completion?(.stillSuppressed); return }
        mediaServicesResetCount += 1
        enterNeedsRecovery()
        suppressionLogCount = 0
        logSuppressionOnce("media services were reset; rebuilding the audio session before playing")
        requestRecovery(completion: completion)
    }

    /// `AVAudioEngineConfigurationChange`: a route change (headphones in or out) stopped the engine.
    func configurationChanged(completion: ((Recovery) -> Void)? = nil) {
        switch state {
        case .shutDown, .interrupted:
            completion?(.stillSuppressed)
        case .ready:
            if hooks.isEngineRunning() { completion?(.recovered); return }
            enterNeedsRecovery()
            requestRecovery(completion: completion)
        case .needsRecovery:
            enterNeedsRecovery()
            requestRecovery(completion: completion)
        }
    }

    /// The app is in front again (`UIApplication.didBecomeActiveNotification`). Apple's guidance:
    /// the end of an interruption is not guaranteed, so re-activate when the app comes back.
    func appBecameActive(completion: ((Recovery) -> Void)? = nil) {
        switch state {
        case .shutDown:
            completion?(.stillSuppressed)
        case .ready:
            completion?(.recovered)
        case .interrupted:
            lastInterruptedAttempt = hooks.now()
            requestRecovery(completion: completion)
        case .needsRecovery:
            enterNeedsRecovery()
            requestRecovery(completion: completion)
        }
    }

    /// The owner is tearing down. Terminal: a notification that arrives afterwards must not restart a
    /// destroyed engine, and a recovery still on the worker comes back stale.
    func shutDown() {
        state = .shutDown
        invalidateRecovery()
    }

    // MARK: - Hot path

    /// True only when the engine is known to be rendering, so `play()` is safe to call.
    ///
    /// In the normal case this is an enum comparison plus `AVAudioEngine.isRunning`, which is what the
    /// call site paid before this gate existed. Otherwise it may ask the worker for a recovery and
    /// returns false at once; the pad never waits for the audio server.
    func ensureEngineRunning() -> Bool {
        switch state {
        case .ready:
            if hooks.isEngineRunning() { return true }
            // The engine stopped without a notification we saw.
            enterNeedsRecovery()
            requestRecovery(byPad: true)
            return false
        case .interrupted:
            let now = hooks.now()
            guard !isRecovering, now - lastInterruptedAttempt >= Self.interruptedRetryInterval else {
                logSuppressionOnce("pad ignored: the audio session is interrupted")
                return false
            }
            lastInterruptedAttempt = now
            requestRecovery()
            return false
        case .needsRecovery:
            if isRecovering {
                logSuppressionOnce("pad ignored: the audio engine is being restarted")
                return false
            }
            if let lastFailed = lastFailedPadRecovery,
               hooks.now() - lastFailed < Self.interruptedRetryInterval {
                logSuppressionOnce("pad ignored: the last try to restart the audio engine failed")
                return false
            }
            requestRecovery(byPad: true)
            return false
        case .shutDown:
            return false
        }
    }

    /// Called when `play()` raised anyway. The engine is not in a state we understand, so suppress and
    /// re-activate before the next pad.
    func playbackFailed(reason: String) {
        guard state != .shutDown else { return }
        enterNeedsRecovery()
        suppressionLogCount = 0
        logSuppressionOnce("play() failed (\(reason)); the engine will be restarted before the next pad")
    }

    // MARK: - Recovery

    /// Something changed, so the next pad may try to recover at once.
    private func enterNeedsRecovery() {
        state = .needsRecovery
        lastFailedPadRecovery = nil
        invalidateRecovery()
    }

    private func invalidateRecovery() {
        generation += 1
        isRecovering = false
    }

    /// `completion` hears `.stillSuppressed` when the recovery came back stale.
    private func requestRecovery(byPad: Bool = false, completion: ((Recovery) -> Void)? = nil) {
        invalidateRecovery()
        isRecovering = true
        let requested = generation
        let hooks = self.hooks
        hooks.runOffMain({ Self.recover(hooks) }) { [weak self] attempt in
            guard let self, self.generation == requested else {
                completion?(.stillSuppressed)
                return
            }
            self.isRecovering = false
            switch attempt {
            case .recovered:
                self.state = .ready
                self.lastFailedPadRecovery = nil
                self.suppressionLogCount = 0
                logger.info("audio engine recovered; playback resumed")
                completion?(.recovered)
            case .failed(let message):
                if byPad { self.lastFailedPadRecovery = self.hooks.now() }
                self.logSuppressionOnce(message)
                completion?(.stillSuppressed)
            }
        }
    }

    /// Runs on the worker.
    nonisolated private static func recover(_ hooks: Hooks) -> Attempt {
        do {
            try hooks.activateSession()
        } catch {
            return .failed("could not activate the audio session: \(error.localizedDescription)")
        }
        if !hooks.isEngineRunning() {
            do {
                try hooks.startEngine()
            } catch {
                return .failed("could not restart the audio engine: \(error.localizedDescription)")
            }
        }
        guard hooks.isEngineRunning() else {
            return .failed("the audio engine still does not report running")
        }
        return .recovered
    }

    private func logSuppressionOnce(_ message: String) {
        guard suppressionLogCount == 0 else { return }
        suppressionLogCount += 1
        logger.error("\(message, privacy: .public)")
    }
}
