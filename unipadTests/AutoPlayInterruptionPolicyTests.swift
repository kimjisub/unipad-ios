import Testing
@testable import unipad

/// The rule Android's AudioFocusPolicy follows: an interruption pauses autoplay, and only an end that
/// says playback may resume continues it.
@MainActor
struct AutoPlayInterruptionPolicyTests {
    @Test func aPlayingAutoplayPausesAndResumesWhenTheEndSaysSo() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .ended(shouldResume: true), autoPlayPlaying: false) == .resume)
    }

    @Test func anEndWithoutShouldResumeLeavesAutoplayPaused() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .ended(shouldResume: false), autoPlayPlaying: false) == nil)
        // The decision is spent: a stray later end does not resume either.
        #expect(policy.action(for: .ended(shouldResume: true), autoPlayPlaying: false) == nil)
    }

    @Test func anAutoplayThatWasNotPlayingIsNotStarted() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .ended(shouldResume: true), autoPlayPlaying: false) == nil)
    }

    @Test func aSecondInterruptionKeepsTheFirstDecision() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .began(whileInterrupted: true), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .ended(shouldResume: true), autoPlayPlaying: false) == .resume)
    }

    /// An answered call never sent its end; the session came back with the app. The next
    /// interruption is a new one, and autoplay it found paused stays paused.
    @Test func anInterruptionAfterTheSessionCameBackDecidesAfresh() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .ended(shouldResume: true), autoPlayPlaying: false) == nil)
    }

    @Test func theUsersChoiceDuringTheInterruptionWins() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        policy.userTookControl()
        #expect(policy.action(for: .ended(shouldResume: true), autoPlayPlaying: false) == nil)
    }

    @Test func anAutoplayTheUserAlreadyResumedIsLeftAlone() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .ended(shouldResume: true), autoPlayPlaying: true) == nil)
    }
}
