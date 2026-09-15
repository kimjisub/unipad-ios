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
/// The state machine:
///
/// - `.ready`: normal. `ensureEngineRunning()` costs one enum check plus `isEngineRunning()`.
/// - `.interrupted`: another app holds the session (a call came in). Nothing is attempted, because
///   nothing can succeed; `ensureEngineRunning()` returns false straight away.
/// - `.needsRecovery`: the session is ours again but the engine is not known to render yet. The next
///   `ensureEngineRunning()` re-activates the session and restarts the engine, and only a verified
///   running engine clears the state.
/// - `.shutDown`: the owner called `destroy()`. Terminal; a late notification cannot resurrect it.
final class AudioSessionGate {
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

    /// Everything that touches AVFoundation, injected so the state machine is testable.
    struct Hooks {
        /// `AVAudioEngine.isRunning`.
        var isEngineRunning: () -> Bool
        /// Re-applies the category and preferences and calls `setActive(true)`. Must be idempotent:
        /// it also runs after a media services reset, when the category is gone.
        var activateSession: () throws -> Void
        /// `AVAudioEngine.start()`.
        var startEngine: () throws -> Void
    }

    private let hooks: Hooks
    private(set) var state: State = .ready
    /// Counts the log lines the gate has written about the current suppression, so a stuck session
    /// does not write one line per pad press.
    private(set) var suppressionLogCount = 0
    /// How often `mediaServicesWereReset` has been seen. Read by tests and by the PR description.
    private(set) var mediaServicesResetCount = 0

    var isPlaybackSuppressed: Bool { state != .ready }

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    // MARK: - Notifications

    /// `AVAudioSession.interruptionNotification` with type `.began`.
    func interruptionBegan() {
        guard state != .shutDown else { return }
        state = .interrupted
        suppressionLogCount = 0
        logSuppressionOnce("audio session interrupted; playback suppressed")
    }

    /// `AVAudioSession.interruptionNotification` with type `.ended`.
    ///
    /// Only `.shouldResume` makes us re-activate right away. Without it the gate stays suppressed and
    /// waits for the user: the next pad press is the user asking for sound, and that press runs the
    /// same recovery through `ensureEngineRunning()`.
    @discardableResult
    func interruptionEnded(shouldResume: Bool) -> Recovery {
        guard state != .shutDown else { return .stillSuppressed }
        state = .needsRecovery
        guard shouldResume else { return .stillSuppressed }
        return attemptRecovery()
    }

    /// `AVAudioSession.mediaServicesWereResetNotification`. The audio server died and took the
    /// session configuration with it, so nothing may be played until the session has been configured
    /// again and the engine reports that it runs.
    @discardableResult
    func mediaServicesWereReset() -> Recovery {
        guard state != .shutDown else { return .stillSuppressed }
        mediaServicesResetCount += 1
        state = .needsRecovery
        suppressionLogCount = 0
        logSuppressionOnce("media services were reset; rebuilding the audio session before playing")
        return attemptRecovery()
    }

    /// `AVAudioEngineConfigurationChange`: a route change (headphones in or out) stopped the engine.
    @discardableResult
    func configurationChanged() -> Recovery {
        switch state {
        case .shutDown, .interrupted:
            return .stillSuppressed
        case .ready:
            if hooks.isEngineRunning() { return .recovered }
            state = .needsRecovery
            return attemptRecovery()
        case .needsRecovery:
            return attemptRecovery()
        }
    }

    /// The owner is tearing down. Terminal: a notification that arrives afterwards must not restart a
    /// destroyed engine.
    func shutDown() {
        state = .shutDown
    }

    // MARK: - Hot path

    /// True only when the engine is known to be rendering, so `play()` is safe to call.
    ///
    /// In the normal case this is an enum comparison plus `AVAudioEngine.isRunning`, which is what the
    /// call site paid before this gate existed.
    func ensureEngineRunning() -> Bool {
        switch state {
        case .ready:
            if hooks.isEngineRunning() { return true }
            // The engine stopped without a notification we saw.
            state = .needsRecovery
            return attemptRecovery() == .recovered
        case .interrupted:
            logSuppressionOnce("pad ignored: the audio session is interrupted")
            return false
        case .needsRecovery:
            return attemptRecovery() == .recovered
        case .shutDown:
            return false
        }
    }

    /// Called when `play()` raised anyway. The engine is not in a state we understand, so suppress and
    /// re-activate before the next pad.
    func playbackFailed(reason: String) {
        guard state != .shutDown else { return }
        state = .needsRecovery
        suppressionLogCount = 0
        logSuppressionOnce("play() failed (\(reason)); the engine will be restarted before the next pad")
    }

    // MARK: - Recovery

    private func attemptRecovery() -> Recovery {
        do {
            try hooks.activateSession()
        } catch {
            logSuppressionOnce("could not activate the audio session: \(error.localizedDescription)")
            return .stillSuppressed
        }
        if !hooks.isEngineRunning() {
            do {
                try hooks.startEngine()
            } catch {
                logSuppressionOnce("could not restart the audio engine: \(error.localizedDescription)")
                return .stillSuppressed
            }
        }
        guard hooks.isEngineRunning() else {
            logSuppressionOnce("the audio engine still does not report running")
            return .stillSuppressed
        }
        state = .ready
        suppressionLogCount = 0
        logger.info("audio engine recovered; playback resumed")
        return .recovered
    }

    private func logSuppressionOnce(_ message: String) {
        guard suppressionLogCount == 0 else { return }
        suppressionLogCount += 1
        logger.error("\(message, privacy: .public)")
    }
}
