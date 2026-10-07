import Foundation
import Testing
@testable import unipad

/// The state machine that keeps a pad from starting a node on an engine that is not rendering.
/// Everything AVFoundation would do is faked, so an interruption can be exercised without a device.
@MainActor
struct AudioSessionGateTests {
    final class FakeAudio {
        enum Failure: Error { case denied }

        var engineRunning = true
        var canActivate = true
        var canStart = true
        /// The case the crash is about: start() succeeds but the engine never renders.
        var startLeavesEngineStopped = false
        /// Seconds on the gate's clock; only moves when a test moves it.
        var clock: TimeInterval = 0
        private(set) var activateCount = 0
        private(set) var startCount = 0

        var hooks: AudioSessionGate.Hooks {
            AudioSessionGate.Hooks(
                isEngineRunning: { [unowned self] in self.engineRunning },
                activateSession: { [unowned self] in
                    self.activateCount += 1
                    guard self.canActivate else { throw Failure.denied }
                },
                startEngine: { [unowned self] in
                    self.startCount += 1
                    guard self.canStart else { throw Failure.denied }
                    if !self.startLeavesEngineStopped { self.engineRunning = true }
                },
                // Some tests drop the fake after began(); the clock then stays at 0.
                now: { [weak self] in self?.clock ?? 0 }
            )
        }
    }

    private func began() -> (FakeAudio, AudioSessionGate) {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        gate.interruptionBegan()
        // The system stops the engine when another app takes the session.
        audio.engineRunning = false
        return (audio, gate)
    }

    @Test func aRunningEngineCostsNothingButTheCheck() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)

        #expect(gate.ensureEngineRunning())
        #expect(!gate.isPlaybackSuppressed)
        #expect(audio.activateCount == 0)
        #expect(audio.startCount == 0)
    }

    @Test func interruptionBeganSuppressesPlayback() {
        let (audio, gate) = began()

        #expect(gate.state == .interrupted)
        #expect(gate.isPlaybackSuppressed)
        #expect(!gate.ensureEngineRunning())
        // Nothing is attempted while another app owns the session: it could not succeed.
        #expect(audio.activateCount == 0)
        #expect(audio.startCount == 0)
    }

    @Test func interruptionEndedWithShouldResumeRestartsAndClearsTheFlag() {
        let (audio, gate) = began()

        #expect(gate.interruptionEnded(shouldResume: true) == .recovered)
        #expect(gate.state == .ready)
        #expect(!gate.isPlaybackSuppressed)
        #expect(audio.activateCount == 1)
        #expect(audio.startCount == 1)
        #expect(gate.ensureEngineRunning())
    }

    @Test func interruptionEndedWithoutShouldResumeStaysSuppressed() {
        let (audio, gate) = began()

        #expect(gate.interruptionEnded(shouldResume: false) == .stillSuppressed)
        #expect(gate.isPlaybackSuppressed)
        #expect(gate.state == .needsRecovery)
        // The notification itself resumes nothing.
        #expect(audio.activateCount == 0)
        #expect(audio.startCount == 0)
    }

    /// Deliberate: without `.shouldResume` we wait for the user, and the next pad press is the user
    /// asking for sound. Otherwise a call that ends without the flag would leave the app mute.
    @Test func aPadPressAfterEndedWithoutShouldResumeRecovers() {
        let (audio, gate) = began()
        gate.interruptionEnded(shouldResume: false)

        #expect(gate.ensureEngineRunning())
        #expect(audio.activateCount == 1)
        #expect(audio.startCount == 1)
        #expect(!gate.isPlaybackSuppressed)
    }

    @Test func aSessionThatCannotBeActivatedKeepsPlaybackSuppressed() {
        let (audio, gate) = began()
        audio.canActivate = false

        #expect(gate.interruptionEnded(shouldResume: true) == .stillSuppressed)
        #expect(gate.isPlaybackSuppressed)
        #expect(!gate.ensureEngineRunning())
        // The engine is never started on a session we do not hold.
        #expect(audio.startCount == 0)
    }

    @Test func anEngineThatRefusesToStartKeepsPlaybackSuppressed() {
        let (audio, gate) = began()
        audio.canStart = false

        #expect(gate.interruptionEnded(shouldResume: true) == .stillSuppressed)
        #expect(gate.isPlaybackSuppressed)
        #expect(audio.startCount == 1)
    }

    /// start() returning without an error is not enough; the engine has to report that it runs.
    @Test func anEngineThatStartsButDoesNotRunKeepsPlaybackSuppressed() {
        let (audio, gate) = began()
        audio.startLeavesEngineStopped = true

        #expect(gate.interruptionEnded(shouldResume: true) == .stillSuppressed)
        #expect(gate.isPlaybackSuppressed)
        #expect(!gate.ensureEngineRunning())
    }

    @Test func aStuckSessionIsLoggedOnceNotOncePerPad() {
        let (_, gate) = began()

        for _ in 0..<32 { _ = gate.ensureEngineRunning() }

        #expect(gate.suppressionLogCount == 1)
    }

    @Test func recoveryLetsTheNextProblemBeLoggedAgain() {
        let (audio, gate) = began()
        _ = gate.ensureEngineRunning()
        #expect(gate.suppressionLogCount == 1)

        gate.interruptionEnded(shouldResume: true)
        #expect(gate.suppressionLogCount == 0)

        audio.engineRunning = false
        audio.canActivate = false
        gate.interruptionBegan()
        #expect(gate.suppressionLogCount == 1)
    }

    @Test func mediaServicesResetSuppressesPlaybackUntilTheSessionIsBackAndTheEngineRuns() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        audio.engineRunning = false
        audio.canActivate = false

        #expect(gate.mediaServicesWereReset() == .stillSuppressed)
        #expect(gate.mediaServicesResetCount == 1)
        #expect(gate.isPlaybackSuppressed)
        #expect(!gate.ensureEngineRunning())

        // The audio server comes back: the session is configured again and the engine restarted.
        audio.canActivate = true
        #expect(gate.ensureEngineRunning())
        #expect(audio.startCount == 1)
        #expect(!gate.isPlaybackSuppressed)
    }

    @Test func aConfigurationChangeRestartsAnEngineTheRouteStopped() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        audio.engineRunning = false

        #expect(gate.configurationChanged() == .recovered)
        #expect(audio.startCount == 1)
        #expect(!gate.isPlaybackSuppressed)
    }

    @Test func aConfigurationChangeDuringAnInterruptionChangesNothing() {
        let (audio, gate) = began()

        #expect(gate.configurationChanged() == .stillSuppressed)
        #expect(audio.activateCount == 0)
        #expect(audio.startCount == 0)
        #expect(gate.state == .interrupted)
    }

    /// The engine can stop without a notification we observe; the next pad restarts it.
    @Test func anEngineThatStoppedUnobservedIsRestartedOnTheNextPad() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        audio.engineRunning = false

        #expect(gate.ensureEngineRunning())
        #expect(audio.activateCount == 1)
        #expect(audio.startCount == 1)
    }

    @Test func aRaisedPlayCallSuppressesThePadsAfterIt() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        gate.playbackFailed(reason: "player did not see an IO cycle")

        #expect(gate.isPlaybackSuppressed)
        #expect(gate.state == .needsRecovery)
        // The next pad re-activates the session before it plays.
        #expect(gate.ensureEngineRunning())
        #expect(audio.activateCount == 1)
    }

    /// Apple: a began interruption is not always followed by an ended one (an answered call suspends
    /// the app). Coming back to the app takes the session back.
    @Test func anInterruptionThatNeverEndsIsRecoveredWhenTheAppComesBack() {
        let (audio, gate) = began()

        #expect(gate.appBecameActive() == .recovered)
        #expect(gate.state == .ready)
        #expect(audio.activateCount == 1)
        #expect(audio.startCount == 1)
        #expect(gate.ensureEngineRunning())
    }

    @Test func comingBackWhileTheCallIsStillOnStaysInterruptedAndTriesAgainNextTime() {
        let (audio, gate) = began()
        audio.canActivate = false

        #expect(gate.appBecameActive() == .stillSuppressed)
        #expect(gate.state == .interrupted)
        #expect(audio.startCount == 0, "the engine was started on a session we do not hold")

        audio.canActivate = true
        #expect(gate.appBecameActive() == .recovered)
        #expect(!gate.isPlaybackSuppressed)
    }

    @Test func comingBackAfterAnEndWithoutShouldResumeRecovers() {
        let (audio, gate) = began()
        gate.interruptionEnded(shouldResume: false)

        #expect(gate.appBecameActive() == .recovered)
        #expect(audio.activateCount == 1)
        #expect(!gate.isPlaybackSuppressed)
    }

    @Test func comingBackWithNothingInterruptedTouchesNothing() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)

        #expect(gate.appBecameActive() == .recovered)
        #expect(audio.activateCount == 0)
        #expect(audio.startCount == 0)
    }

    /// A pad is the user asking for sound, so it also tries to take an interrupted session back, but
    /// at most once per interval: activation is a synchronous call that fails while a call is on.
    @Test func aPadTriesToTakeAnInterruptedSessionBackAtMostOncePerInterval() {
        let (audio, gate) = began()
        audio.canActivate = false
        let interval = AudioSessionGate.interruptedRetryInterval

        audio.clock = interval / 2
        #expect(!gate.ensureEngineRunning())
        #expect(audio.activateCount == 0)

        audio.clock = interval
        #expect(!gate.ensureEngineRunning())
        #expect(audio.activateCount == 1)
        for _ in 0..<16 { _ = gate.ensureEngineRunning() }
        #expect(audio.activateCount == 1, "every pad press called into the audio server")
        #expect(gate.state == .interrupted)
        #expect(gate.suppressionLogCount == 1)

        audio.clock = interval * 2
        audio.canActivate = true
        #expect(gate.ensureEngineRunning())
        #expect(audio.activateCount == 2)
        #expect(audio.startCount == 1)
        #expect(!gate.isPlaybackSuppressed)
    }

    @Test func comingBackAfterShutDownStartsNothing() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        gate.interruptionBegan()
        gate.shutDown()
        audio.clock = AudioSessionGate.interruptedRetryInterval * 10

        #expect(gate.appBecameActive() == .stillSuppressed)
        #expect(!gate.ensureEngineRunning())
        #expect(audio.activateCount == 0)
    }

    @Test func shutDownIsTerminal() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        gate.shutDown()

        #expect(!gate.ensureEngineRunning())
        #expect(gate.interruptionEnded(shouldResume: true) == .stillSuppressed)
        #expect(gate.mediaServicesWereReset() == .stillSuppressed)
        #expect(gate.configurationChanged() == .stillSuppressed)
        #expect(gate.state == .shutDown)
        #expect(audio.activateCount == 0)
        #expect(audio.startCount == 0)
    }
}
