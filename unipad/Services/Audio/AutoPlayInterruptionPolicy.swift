/// What autoplay does when another app takes the audio session, the same rule as Android's
/// `AudioFocusPolicy`: an interruption pauses a playing autoplay, and the end of the interruption
/// resumes it only when the system says playback may resume (`.shouldResume`, Android's transient
/// loss). Without that, autoplay stays paused for the user to resume. Autoplay resumes only once the
/// session is ours again, never without sound. When the end allowed resuming but the session could not
/// be taken back then (a non-mixable session cannot be activated while the app is in the background),
/// the app coming back to the front and taking it back resumes autoplay instead. Silencing the pads is
/// SoundEngine's part.
struct AutoPlayInterruptionPolicy {
    enum Action: Equatable {
        case pause
        case resume
    }

    private var resumeOnEnd = false
    private var resumeOnReturn = false

    mutating func action(for interruption: SoundEngine.Interruption, autoPlayPlaying: Bool) -> Action? {
        switch interruption {
        case .began(let whileInterrupted):
            // Interruptions can overlap: a second one begins before the first ended, while autoplay is
            // already paused, and the first decision stands. Once the session was ours again the
            // earlier one is over even if its end never came (an answered call), so this one decides
            // afresh.
            resumeOnEnd = (whileInterrupted && (resumeOnEnd || resumeOnReturn)) || autoPlayPlaying
            resumeOnReturn = false
            return autoPlayPlaying ? .pause : nil
        case .ended(let shouldResume, let recovered):
            defer { resumeOnEnd = false }
            resumeOnReturn = shouldResume && !recovered && resumeOnEnd
            return shouldResume && recovered && resumeOnEnd && !autoPlayPlaying ? .resume : nil
        case .appReturned(let recovered):
            // Only the next return: one that found the session already ours, or failed to take it,
            // leaves autoplay to the user.
            defer { resumeOnReturn = false }
            return recovered && resumeOnReturn && !autoPlayPlaying ? .resume : nil
        }
    }

    /// The user played, paused or changed autoplay; the end of an interruption no longer overrides
    /// their choice.
    mutating func userTookControl() {
        resumeOnEnd = false
        resumeOnReturn = false
    }
}
