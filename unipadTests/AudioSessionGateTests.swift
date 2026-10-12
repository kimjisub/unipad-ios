import Foundation
import Testing
@testable import unipad

/// The state machine that keeps a pad from starting a node on an engine that is not rendering.
/// Everything AVFoundation would do is faked, so an interruption can be exercised without a device.
/// The worker is faked too: what the gate hands it waits until a test calls `finishRecoveries()`.
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
        private var handedToWorker: [() -> Void] = []
        var pendingRecoveries: Int { handedToWorker.count }

        /// Runs, in order, what the gate handed to the worker and hands the results back.
        func finishRecoveries() {
            let work = handedToWorker
            handedToWorker.removeAll()
            work.forEach { $0() }
        }

        /// Runs the oldest thing the gate handed to the worker and hands its result back.
        func finishNextRecovery() {
            handedToWorker.removeFirst()()
        }

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
                runOffMain: { [unowned self] work, completion in
                    self.handedToWorker.append { completion(work()) }
                },
                // Some tests drop the fake after began(); the clock then stays at 0.
                now: { [weak self] in self?.clock ?? 0 }
            )
        }
    }

    /// Boxes what a notification's completion reported.
    final class Reported {
        var recovery: AudioSessionGate.Recovery?
        var record: (AudioSessionGate.Recovery) -> Void { { [unowned self] in self.recovery = $0 } }
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
        let reported = Reported()

        gate.interruptionEnded(shouldResume: true, completion: reported.record)
        #expect(gate.isPlaybackSuppressed, "playback was back before the worker restarted the engine")
        #expect(reported.recovery == nil)
        audio.finishRecoveries()

        #expect(reported.recovery == .recovered)
        #expect(gate.state == .ready)
        #expect(!gate.isPlaybackSuppressed)
        #expect(audio.activateCount == 1)
        #expect(audio.startCount == 1)
        #expect(gate.ensureEngineRunning())
    }

    @Test func interruptionEndedWithoutShouldResumeStaysSuppressed() {
        let (audio, gate) = began()
        let reported = Reported()

        gate.interruptionEnded(shouldResume: false, completion: reported.record)
        audio.finishRecoveries()
        #expect(reported.recovery == .stillSuppressed)
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

        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()
        #expect(gate.ensureEngineRunning())
        #expect(audio.activateCount == 1)
        #expect(audio.startCount == 1)
        #expect(!gate.isPlaybackSuppressed)
    }

    @Test func aSessionThatCannotBeActivatedKeepsPlaybackSuppressed() {
        let (audio, gate) = began()
        audio.canActivate = false
        let reported = Reported()

        gate.interruptionEnded(shouldResume: true, completion: reported.record)
        audio.finishRecoveries()
        #expect(reported.recovery == .stillSuppressed)
        #expect(gate.isPlaybackSuppressed)
        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()
        // The engine is never started on a session we do not hold.
        #expect(audio.startCount == 0)
    }

    @Test func anEngineThatRefusesToStartKeepsPlaybackSuppressed() {
        let (audio, gate) = began()
        audio.canStart = false

        gate.interruptionEnded(shouldResume: true)
        audio.finishRecoveries()
        #expect(gate.isPlaybackSuppressed)
        #expect(audio.startCount == 1)
    }

    /// start() returning without an error is not enough; the engine has to report that it runs.
    @Test func anEngineThatStartsButDoesNotRunKeepsPlaybackSuppressed() {
        let (audio, gate) = began()
        audio.startLeavesEngineStopped = true

        gate.interruptionEnded(shouldResume: true)
        audio.finishRecoveries()
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
        audio.finishRecoveries()
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

        gate.mediaServicesWereReset()
        audio.finishRecoveries()
        #expect(gate.mediaServicesResetCount == 1)
        #expect(gate.isPlaybackSuppressed)
        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()

        // The audio server comes back: a pad after the retry interval configures the session again
        // and restarts the engine.
        audio.clock += AudioSessionGate.interruptedRetryInterval
        audio.canActivate = true
        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()
        #expect(gate.ensureEngineRunning())
        #expect(audio.startCount == 1)
        #expect(!gate.isPlaybackSuppressed)
    }

    @Test func aConfigurationChangeRestartsAnEngineTheRouteStopped() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        audio.engineRunning = false
        let reported = Reported()

        gate.configurationChanged(completion: reported.record)
        audio.finishRecoveries()
        #expect(reported.recovery == .recovered)
        #expect(audio.startCount == 1)
        #expect(!gate.isPlaybackSuppressed)
    }

    @Test func aConfigurationChangeDuringAnInterruptionChangesNothing() {
        let (audio, gate) = began()

        let reported = Reported()

        gate.configurationChanged(completion: reported.record)
        #expect(reported.recovery == .stillSuppressed)
        #expect(audio.pendingRecoveries == 0)
        #expect(audio.activateCount == 0)
        #expect(audio.startCount == 0)
        #expect(gate.state == .interrupted)
    }

    /// The engine can stop without a notification we observe; the next pad restarts it.
    @Test func anEngineThatStoppedUnobservedIsRestartedOnTheNextPad() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        audio.engineRunning = false

        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()
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
        // The next pad has the session re-activated; the pads after it play.
        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()
        #expect(gate.ensureEngineRunning())
        #expect(audio.activateCount == 1)
    }

    /// Apple: a began interruption is not always followed by an ended one (an answered call suspends
    /// the app). Coming back to the app takes the session back.
    @Test func anInterruptionThatNeverEndsIsRecoveredWhenTheAppComesBack() {
        let (audio, gate) = began()
        let reported = Reported()

        gate.appBecameActive(completion: reported.record)
        audio.finishRecoveries()
        #expect(reported.recovery == .recovered)
        #expect(gate.state == .ready)
        #expect(audio.activateCount == 1)
        #expect(audio.startCount == 1)
        #expect(gate.ensureEngineRunning())
    }

    @Test func comingBackWhileTheCallIsStillOnStaysInterruptedAndTriesAgainNextTime() {
        let (audio, gate) = began()
        audio.canActivate = false

        gate.appBecameActive()
        audio.finishRecoveries()
        #expect(gate.state == .interrupted)
        #expect(audio.startCount == 0, "the engine was started on a session we do not hold")

        audio.canActivate = true
        gate.appBecameActive()
        audio.finishRecoveries()
        #expect(!gate.isPlaybackSuppressed)
    }

    /// A failed try on coming back counts as the latest try, so the pad pressed right after it does
    /// not call into the audio server again.
    @Test func aFailedTryOnComingBackHoldsOffThePadRightAfterIt() {
        let (audio, gate) = began()
        audio.canActivate = false
        audio.clock = AudioSessionGate.interruptedRetryInterval * 5

        gate.appBecameActive()
        audio.finishRecoveries()
        #expect(audio.activateCount == 1)
        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()
        #expect(audio.activateCount == 1, "the pad right after coming back tried again")

        audio.clock += AudioSessionGate.interruptedRetryInterval
        audio.canActivate = true
        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()
        #expect(gate.ensureEngineRunning())
        #expect(audio.activateCount == 2)
    }

    @Test func comingBackAfterAnEndWithoutShouldResumeRecovers() {
        let (audio, gate) = began()
        gate.interruptionEnded(shouldResume: false)

        gate.appBecameActive()
        audio.finishRecoveries()
        #expect(audio.activateCount == 1)
        #expect(!gate.isPlaybackSuppressed)
    }

    /// The session can be deactivated in the background without an interruption we hear of. Coming
    /// back activates it again on the worker, and the pads keep playing meanwhile.
    @Test func comingBackWithNothingInterruptedOnlyReactivatesTheSessionOffTheMainThread() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        let reported = Reported()

        gate.appBecameActive(completion: reported.record)
        #expect(reported.recovery == .recovered)
        #expect(audio.activateCount == 0, "the session was activated on the main thread")
        #expect(audio.pendingRecoveries == 1)
        #expect(gate.ensureEngineRunning(), "the pads waited for the session")

        audio.finishRecoveries()
        #expect(audio.activateCount == 1)
        #expect(audio.startCount == 0)
        #expect(gate.state == .ready)
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
        audio.finishRecoveries()
        #expect(audio.activateCount == 1)
        for _ in 0..<16 { _ = gate.ensureEngineRunning() }
        audio.finishRecoveries()
        #expect(audio.activateCount == 1, "every pad press called into the audio server")
        #expect(gate.state == .interrupted)
        #expect(gate.suppressionLogCount == 1)

        audio.clock = interval * 2
        audio.canActivate = true
        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()
        #expect(gate.ensureEngineRunning())
        #expect(audio.activateCount == 2)
        #expect(audio.startCount == 1)
        #expect(!gate.isPlaybackSuppressed)
    }

    /// After a pad's failed try to bring the engine back (a session that cannot be activated after an
    /// interruption ended, a play() that raised, a route change the engine did not survive), autoplay
    /// and fast pad presses must not call into the audio server on every pad.
    @Test func aFailedRecoveryIsRetriedAtMostOncePerInterval() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        audio.canActivate = false
        let interval = AudioSessionGate.interruptedRetryInterval
        audio.clock = 100
        gate.playbackFailed(reason: "player did not see an IO cycle")

        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()
        #expect(audio.activateCount == 1, "the first pad after the failure did not try at once")
        for _ in 0..<32 {
            audio.clock += interval / 64
            _ = gate.ensureEngineRunning()
            audio.finishRecoveries()
        }
        #expect(audio.activateCount == 1, "every pad press called into the audio server")
        #expect(gate.state == .needsRecovery)
        #expect(gate.suppressionLogCount == 1)

        audio.clock = 100 + interval
        audio.canActivate = true
        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()
        #expect(gate.ensureEngineRunning())
        #expect(audio.activateCount == 2)
        #expect(!gate.isPlaybackSuppressed)
    }

    /// The spacing only follows a failed try: once something changed (here the route), the next pad
    /// tries again at once instead of waiting out the interval.
    @Test func aNewProblemAfterAFailedRecoveryIsTriedAtOnce() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        audio.canActivate = false
        gate.playbackFailed(reason: "player did not see an IO cycle")
        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()
        #expect(audio.activateCount == 1)

        audio.canActivate = true
        audio.engineRunning = false
        gate.playbackFailed(reason: "player did not see an IO cycle")
        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()
        #expect(gate.ensureEngineRunning())
        #expect(audio.activateCount == 2)
    }

    /// A pad pressed while the engine needs a recovery hands it to the worker and returns at once;
    /// it never waits for the session to be activated. Autoplay's pads that follow add nothing while
    /// the recovery is on the worker, and once it is back the pads play again.
    @Test func aPadThatNeedsARecoveryDoesNotWaitForTheSession() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        audio.engineRunning = false

        #expect(!gate.ensureEngineRunning())
        #expect(audio.activateCount == 0, "the pad activated the session itself")
        #expect(audio.pendingRecoveries == 1)
        for _ in 0..<16 { #expect(!gate.ensureEngineRunning()) }
        #expect(audio.pendingRecoveries == 1, "every pad handed the worker another recovery")
        #expect(gate.isRecovering)

        audio.finishRecoveries()
        #expect(audio.activateCount == 1)
        #expect(!gate.isRecovering)
        #expect(gate.ensureEngineRunning())
    }

    /// Unplugging headphones mid-play: the notification only hands the restart to the worker.
    @Test func aRouteChangeDoesNotWaitForTheEngineToRestart() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        audio.engineRunning = false

        gate.configurationChanged()
        #expect(audio.activateCount == 0)
        #expect(audio.startCount == 0)
        #expect(!gate.ensureEngineRunning())
        #expect(audio.pendingRecoveries == 1)

        audio.finishRecoveries()
        #expect(gate.ensureEngineRunning())
    }

    /// The end of an interruption asked for a recovery, and another interruption began before it came
    /// back. The engine the worker restarted is not ours to play on.
    @Test func aRecoveryOvertakenByANewInterruptionChangesNothing() {
        let (audio, gate) = began()
        let reported = Reported()
        gate.interruptionEnded(shouldResume: true, completion: reported.record)

        gate.interruptionBegan()
        audio.finishRecoveries()

        #expect(reported.recovery == .abandoned)
        #expect(gate.state == .interrupted)
        #expect(!gate.ensureEngineRunning())
    }

    /// A call ends with `.shouldResume` and the app comes back right after, as it does when the call
    /// screen closes, before the worker has taken the session back. The end hears the result of the
    /// try made on coming back, so autoplay resumes.
    @Test func comingBackBeforeTheRecoveryForAResumableEndReportsTheTryOnComingBack() {
        let (audio, gate) = began()
        let ended = Reported(), returned = Reported()

        gate.interruptionEnded(shouldResume: true, completion: ended.record)
        gate.appBecameActive(completion: returned.record)
        #expect(audio.pendingRecoveries == 2, "coming back did not try again")
        audio.finishRecoveries()

        #expect(ended.recovery == .recovered)
        #expect(returned.recovery == .recovered)
        #expect(gate.state == .ready)
    }

    /// The end came while the app was in the background, where a session that does not mix with others
    /// cannot be activated, and the app came back before that try failed. Coming back tries again in
    /// front, and the end hears that try's result instead of the failure.
    @Test func comingBackWhileABackgroundTryIsFailingTriesAgainInFront() {
        let (audio, gate) = began()
        let ended = Reported(), returned = Reported()

        gate.interruptionEnded(shouldResume: true, completion: ended.record)
        gate.appBecameActive(completion: returned.record)
        audio.canActivate = false
        audio.finishNextRecovery()
        #expect(ended.recovery == nil, "the failure of the background try was reported")
        audio.canActivate = true
        audio.finishNextRecovery()

        #expect(audio.activateCount == 2)
        #expect(ended.recovery == .recovered)
        #expect(returned.recovery == .recovered)
        #expect(gate.state == .ready)
    }

    /// A route change or a raised play() after the end of an interruption hands the worker a fresh
    /// recovery; the end hears that one's result instead of being dropped.
    @Test(arguments: ["route change", "raised play"])
    func aChangeBeforeTheRecoveryForAResumableEndReportsTheFreshRecovery(_ change: String) {
        let (audio, gate) = began()
        let reported = Reported()

        gate.interruptionEnded(shouldResume: true, completion: reported.record)
        if change == "route change" {
            gate.configurationChanged()
        } else {
            gate.playbackFailed(reason: "player did not see an IO cycle")
        }
        audio.finishRecoveries()

        #expect(reported.recovery == .recovered)
        #expect(gate.state == .ready)
        #expect(audio.startCount == 1)
    }

    /// Two interruptions overlap when the second begins before the session was ours again after the
    /// first; the first one's end is abandoned and the second reports its own.
    @Test func anInterruptionStaysUnresolvedUntilPlaybackIsBack() {
        let (audio, gate) = began()
        #expect(gate.isInterruptionUnresolved)
        gate.interruptionEnded(shouldResume: true)
        #expect(gate.isInterruptionUnresolved, "resolved before the session was taken back")

        gate.interruptionBegan()
        #expect(gate.isInterruptionUnresolved)
        gate.interruptionEnded(shouldResume: true)
        audio.finishRecoveries()
        #expect(!gate.isInterruptionUnresolved)
    }

    @Test func shutDownWhileARecoveryIsOnTheWorkerStaysShutDown() {
        let (audio, gate) = began()
        let reported = Reported()
        gate.appBecameActive(completion: reported.record)

        gate.shutDown()
        #expect(reported.recovery == .abandoned)
        audio.finishRecoveries()

        #expect(reported.recovery == .abandoned)
        #expect(gate.state == .shutDown)
        #expect(!gate.ensureEngineRunning())
    }

    @Test func comingBackAfterShutDownStartsNothing() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        gate.interruptionBegan()
        gate.shutDown()
        audio.clock = AudioSessionGate.interruptedRetryInterval * 10

        gate.appBecameActive()
        #expect(!gate.ensureEngineRunning())
        audio.finishRecoveries()
        #expect(audio.activateCount == 0)
    }

    @Test func shutDownIsTerminal() {
        let audio = FakeAudio()
        let gate = AudioSessionGate(hooks: audio.hooks)
        gate.shutDown()
        let ended = Reported(), reset = Reported(), changed = Reported()

        #expect(!gate.ensureEngineRunning())
        gate.interruptionEnded(shouldResume: true, completion: ended.record)
        gate.mediaServicesWereReset(completion: reset.record)
        gate.configurationChanged(completion: changed.record)
        audio.finishRecoveries()
        #expect(ended.recovery == .stillSuppressed)
        #expect(reset.recovery == .stillSuppressed)
        #expect(changed.recovery == .stillSuppressed)
        #expect(gate.state == .shutDown)
        #expect(audio.activateCount == 0)
        #expect(audio.startCount == 0)
    }
}
