/// What autoplay does when another app takes the audio session, the same rule as Android's
/// `AudioFocusPolicy`: an interruption pauses a playing autoplay, and the end of the interruption
/// resumes it only when the system says playback may resume (`.shouldResume`, Android's transient
/// loss). Without that, autoplay stays paused for the user to resume. Silencing the pads is
/// SoundEngine's part.
struct AutoPlayInterruptionPolicy {
    enum Action: Equatable {
        case pause
        case resume
    }

    private var resumeOnEnd = false

    mutating func action(for interruption: SoundEngine.Interruption, autoPlayPlaying: Bool) -> Action? {
        switch interruption {
        case .began:
            // A second interruption can begin while autoplay is already paused; keep the first decision.
            resumeOnEnd = resumeOnEnd || autoPlayPlaying
            return autoPlayPlaying ? .pause : nil
        case .ended(let shouldResume):
            defer { resumeOnEnd = false }
            return shouldResume && resumeOnEnd && !autoPlayPlaying ? .resume : nil
        }
    }
}
