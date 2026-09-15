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
                }
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
