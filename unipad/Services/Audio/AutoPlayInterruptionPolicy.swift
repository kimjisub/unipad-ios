/// What autoplay does when another app takes the audio session, the same rule as Android's
/// `AudioFocusPolicy`: an interruption pauses a playing autoplay, and the end of the interruption
/// resumes it only when the system says playback may resume (`.shouldResume`, Android's transient
/// loss). Without that, autoplay stays paused for the user to resume. Autoplay resumes only once the
/// session is ours again, never without sound. When the end allowed resuming but came while the app
/// was not in front, where a session that does not mix with others cannot be taken back, the app's
/// next return to the front resumes autoplay if it takes the session back. Silencing the pads is
/// SoundEngine's part.
struct AutoPlayInterruptionPolicy {
    enum Action: Equatable {
        case pause
        case resume
    }

    /// What a paused autoplay waits for before it continues on its own.
    private enum Pending {
        case nothing
        case end
        case appReturn
    }

    private var pending = Pending.nothing

    mutating func action(for interruption: SoundEngine.Interruption, autoPlayPlaying: Bool) -> Action? {
        switch interruption {
        case .began(let whileInterrupted):
            // Interruptions can overlap: a second one begins before the first ended, while autoplay is
            // already paused, and the first decision stands. Once the session was ours again the
            // earlier one is over even if its end never came (an answered call), so this one decides
            // afresh.
            let carried = whileInterrupted && pending != .nothing
            pending = carried || autoPlayPlaying ? .end : .nothing
            return autoPlayPlaying ? .pause : nil
        case .ended(let shouldResume, let recovered, let whileInFront):
            guard pending != .nothing, shouldResume else {
                pending = .nothing
                return nil
            }
            if recovered {
                pending = .nothing
                return autoPlayPlaying ? nil : .resume
            }
            // In front, another app still holds the session; a later return to the front has nothing to
            // do with this interruption.
            pending = whileInFront ? .nothing : .appReturn
            return nil
        case .appReturned(let recovered):
            // Only the next return: one that found the session already ours, or failed to take it,
            // leaves autoplay to the user.
            guard pending == .appReturn else { return nil }
            pending = .nothing
            return recovered && !autoPlayPlaying ? .resume : nil
        }
    }

    /// The user played, paused or changed autoplay; the end of an interruption no longer overrides
    /// their choice.
    mutating func userTookControl() {
        pending = .nothing
    }
}
