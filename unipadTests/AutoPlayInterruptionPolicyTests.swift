import Testing
@testable import unipad

/// The rule Android's AudioFocusPolicy follows: an interruption pauses autoplay, and only an end that
/// says playback may resume continues it, once the session is ours again.
@MainActor
struct AutoPlayInterruptionPolicyTests {
    @Test func aPlayingAutoplayPausesAndResumesWhenTheEndSaysSo() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .ended(shouldResume: true, recovered: true, whileInFront: true), autoPlayPlaying: false) == .resume)
    }

    @Test func anEndWithoutShouldResumeLeavesAutoplayPaused() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .ended(shouldResume: false, recovered: false, whileInFront: false), autoPlayPlaying: false) == nil)
        // The decision is spent: a stray later end does not resume either.
        #expect(policy.action(for: .ended(shouldResume: true, recovered: true, whileInFront: true), autoPlayPlaying: false) == nil)
    }

    @Test func anAutoplayThatWasNotPlayingIsNotStarted() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .ended(shouldResume: true, recovered: true, whileInFront: true), autoPlayPlaying: false) == nil)
    }

    @Test func aSecondInterruptionKeepsTheFirstDecision() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .began(whileInterrupted: true), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .ended(shouldResume: true, recovered: true, whileInFront: true), autoPlayPlaying: false) == .resume)
    }

    /// An answered call never sent its end; the session came back with the app. The next
    /// interruption is a new one, and autoplay it found paused stays paused.
    @Test func anInterruptionAfterTheSessionCameBackDecidesAfresh() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .ended(shouldResume: true, recovered: true, whileInFront: true), autoPlayPlaying: false) == nil)
    }

    @Test func theUsersChoiceDuringTheInterruptionWins() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        policy.userTookControl()
        #expect(policy.action(for: .ended(shouldResume: true, recovered: true, whileInFront: true), autoPlayPlaying: false) == nil)
    }

    @Test func anAutoplayTheUserAlreadyResumedIsLeftAlone() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .ended(shouldResume: true, recovered: true, whileInFront: true), autoPlayPlaying: true) == nil)
    }

    /// The end came while the app was in the background, where the session cannot be taken back; the
    /// app coming back takes it back.
    @Test func aResumableEndWithoutTheSessionResumesWhenTheAppReturnsWithIt() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .ended(shouldResume: true, recovered: false, whileInFront: false), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .appReturned(recovered: true), autoPlayPlaying: false) == .resume)
    }

    @Test func onlyTheNextReturnResumes() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .ended(shouldResume: true, recovered: false, whileInFront: false), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .appReturned(recovered: false), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .appReturned(recovered: true), autoPlayPlaying: false) == nil)
    }

    @Test func anEndWithoutShouldResumeIsNotResumedByTheReturn() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .ended(shouldResume: false, recovered: false, whileInFront: false), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .appReturned(recovered: true), autoPlayPlaying: false) == nil)
    }

    @Test func theUsersChoiceBeforeTheReturnWins() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .ended(shouldResume: true, recovered: false, whileInFront: false), autoPlayPlaying: false) == nil)
        policy.userTookControl()
        #expect(policy.action(for: .appReturned(recovered: true), autoPlayPlaying: false) == nil)
    }

    /// Another interruption began before the session came back; its end decides for the first one too.
    @Test func anInterruptionBeforeTheReturnCarriesTheResume() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .ended(shouldResume: true, recovered: false, whileInFront: false), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .began(whileInterrupted: true), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .appReturned(recovered: true), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .ended(shouldResume: true, recovered: true, whileInFront: true), autoPlayPlaying: false) == .resume)
    }

    /// The app was already in front when the end came and another app still held the session. A later
    /// return to the front (Control Center pulled down and back) has nothing to do with the call.
    @Test func aResumableEndThatFailedInFrontIsNotResumedByALaterReturn() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .began(whileInterrupted: false), autoPlayPlaying: true) == .pause)
        #expect(policy.action(for: .appReturned(recovered: false), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .ended(shouldResume: true, recovered: false, whileInFront: true), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .appReturned(recovered: true), autoPlayPlaying: false) == nil)
    }

    @Test func aReturnWithoutAnInterruptionChangesNothing() {
        var policy = AutoPlayInterruptionPolicy()

        #expect(policy.action(for: .appReturned(recovered: true), autoPlayPlaying: false) == nil)
        #expect(policy.action(for: .appReturned(recovered: false), autoPlayPlaying: true) == nil)
    }
}
