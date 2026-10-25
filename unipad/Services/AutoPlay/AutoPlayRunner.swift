import Foundation
import QuartzCore

/// The screen owns playback state. Keeping each tick on the same actor as stop/reset avoids
/// suspending a detached task while it owns an NSLock and waits to read actor-isolated state.
@MainActor
final class AutoPlayRunner {
    static let guideLookaheadMs: Int64 = 800
    private static let guideLedUpdateIntervalMs: Int64 = 50
    private static let guideVelocities: [Int] = [1, 2, 3, 21]
    private static let stepGroupThresholdMs: Int64 = 50

    private let unipack: UniPack
    private let chain: ChainObserver
    private let loopDelay: TimeInterval
    private let clock: () -> Int64
    private let sleep: @MainActor (UInt64) async throws -> Void

    var playmode: Bool = true {
        didSet {
            guard playmode != oldValue else { return }
            if playmode {
                if let pausedAt { pendingPauseMs += clock() - pausedAt }
                pausedAt = nil
                resumeRequested = true
            } else {
                // Preserve an app suspension even if its return notification arrives after this pause.
                let skipped = suspendedTime.tick(at: clock()) + pendingSkipMs
                if waitingForChain < 0 { pendingPauseMs += skipped }
                pausedAt = clock()
                releaseHeldPads()
            }
            // The explicit pause already accounts for any app suspension inside it.
            suspendedTime.reset()
            pendingSkipMs = 0
        }
    }
    private var pausedAt: Int64?
    private var pendingPauseMs: Int64 = 0
    var beforeStartPlaying: Bool = true
    var practiceGuide: Bool = false {
        didSet { if practiceGuide { releaseHeldPads() } }
    }
    var stepMode: Bool = false
    private(set) var isSuspended = false
    private var playmodeBeforeSuspension = false

    /// Stop output without consuming a pending step or changing the selected practice mode.
    func suspend() {
        guard !isSuspended else { return }
        _pressedKeysQueue.removeAll()
        playmodeBeforeSuspension = playmode
        playmode = false
        isSuspended = true
        listener?.onInputTimeThrough(nil)
        for key in drainGuides() { turnOffGuide(key) }
        for key in _stepPendingPads { turnOffGuide(key) }
        listener?.onRemoveGuide()
    }

    func resumeFromSuspension() {
        guard isSuspended else { return }
        isSuspended = false
        playmode = playmodeBeforeSuspension
        beforeStartPlaying = true
        if stepMode && practiceGuide {
            for key in _stepPendingPads {
                listener?.onGuidePadOn(x: key / 256, y: key % 256, targetWallTimeMs: 0)
                listener?.onGuideLedUpdate(x: key / 256, y: key % 256, velocity: Self.guideVelocities.last!)
            }
            if waitingForChain >= 0 { listener?.onGuideChainOn(c: waitingForChain) }
        }
    }

    /// An explicit mode change supplies its own play/pause flags next.
    func cancelSuspension() {
        isSuspended = false
    }

    private(set) var progress: Int = 0 {
        didSet { listener?.onProgressUpdate(progress: progress) }
    }

    private var task: Task<Void, Never>?
    var active: Bool { task.map { !$0.isCancelled } ?? false }

    @MainActor
    protocol Listener: AnyObject {
        func onStart()
        func onPadTouchOn(x: Int, y: Int, inputID: UUID)
        func onPadTouchOff(x: Int, y: Int, inputIDs: [UUID])
        /// Absolute monotonic times, on the same clock as LedRunner.
        func onPadTouchOn(x: Int, y: Int, inputID: UUID, scheduledAtMs: Int64)
        func onPadTouchOff(x: Int, y: Int, inputIDs: [UUID], scheduledAtMs: Int64)
        /// nil releases scheduling when paused, stopped, or practicing without scheduled input.
        func onInputTimeThrough(_ at: Int64?)
        func onPadTouchCancel(x: Int, y: Int, inputID: UUID)
        func onChainChange(c: Int)
        func onGuidePadOn(x: Int, y: Int, targetWallTimeMs: Int64)
        func onGuidePadOff(x: Int, y: Int)
        func onGuideLedUpdate(x: Int, y: Int, velocity: Int)
        func onGuideChainOn(c: Int)
        func onRemoveGuide()
        func chainButsRefresh()
        func onProgressUpdate(progress: Int)
        func onEnd()
    }

    private weak var listener: Listener?

    private struct Pad: Hashable {
        let x: Int
        let y: Int
        let chain: Int
    }
    private var heldPads: [Pad: UUID] = [:]

    private func releaseHeldPads() {
        let pads = heldPads
        heldPads.removeAll()
        for (pad, inputID) in pads {
            listener?.onPadTouchCancel(x: pad.x, y: pad.y, inputID: inputID)
        }
    }

    private struct GuideEvent {
        let timeMs: Int64
        let x: Int
        let y: Int
        let chain: Int
    }

    private var guideTimeline: [GuideEvent] = []
    private var guideIndex: Int = 0
    private var waitingForChain: Int = -1
    private var timedWaitStart: Int64?
    private var pendingWaitReset = false
    private var resumeRequested = false

    // key = x*256+y, value = targetWallTimeMs
    /// Guide pads currently lit, keyed by guideKey. Ticks and stop() run on the main actor.
    private var activeGuides: [Int: Int64] = [:]

    /// The run that stop() cancelled last; launch() waits for it so two runs never overlap.
    private var previousRun: Task<Void, Never>?

    @discardableResult
    private func withGuides<T>(_ body: (inout [Int: Int64]) -> T) -> T {
        return body(&activeGuides)
    }

    /// Empties activeGuides and returns the keys that were lit for LED cleanup.
    private func drainGuides() -> [Int] {
        withGuides { guides in
            let keys = Array(guides.keys)
            guides.removeAll()
            return keys
        }
    }
    private var lastGuideUpdateMs: Int64 = 0

    // Step mode state
    private var _stepPendingPads: Set<Int> = []
    private var _stepScanned = false
    private var _stepStartProgress: Int = 0
    private var _stepChainValue: Int = -1

    private struct PendingAutoplayStep {
        let endProgress: Int
        let pads: Set<Int>
        var needsOrigin = true
    }
    private var pendingAutoplayStep: PendingAutoplayStep?

    // Pad presses are drained by the next tick on the main actor.
    private var _pressedKeysQueue: [Int] = []

    private var suspendedTime = SuspendedTime()
    /// Found by appReturned() before the run's next tick, which skips it.
    private var pendingSkipMs: Int64 = 0
    /// progressOffset() moved the guide's place in the song; the next tick follows it.
    private var guideMoved = false

    /// Time reads and suspension can share a virtual clock in tests; app defaults remain real time.
    init(
        unipack: UniPack,
        listener: Listener,
        chain: ChainObserver,
        loopDelay: TimeInterval = 0.001,
        clock: @escaping () -> Int64 = { Int64(CACurrentMediaTime() * 1000) },
        sleep: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.unipack = unipack
        self.listener = listener
        self.chain = chain
        self.loopDelay = loopDelay
        self.clock = clock
        self.sleep = sleep
    }

    private func guideKey(x: Int, y: Int) -> Int { x * 256 + y }

    /// The time into the song at which `elements[index]` plays.
    private func timeMs(at index: Int, in autoPlay: AutoPlay) -> Int64 {
        autoPlay.elements[..<min(index, autoPlay.elements.count)].reduce(0) { sum, element in
            if case .delay(let delay) = element { sum + Int64(delay) } else { sum }
        }
    }

    /// Turns the lit guides off and shows them again from `elapsed` into the song on the next pass.
    private func restartGuide(at elapsed: Int64) {
        for key in drainGuides() {
            listener?.onGuideLedUpdate(x: key / 256, y: key % 256, velocity: 0)
        }
        listener?.onRemoveGuide()
        guideIndex = guideTimeline.firstIndex { $0.timeMs >= elapsed } ?? guideTimeline.count
    }

    private func buildGuideTimeline(autoPlay: AutoPlay) -> [GuideEvent] {
        var events: [GuideEvent] = []
        var time: Int64 = 0
        for element in autoPlay.elements {
            switch element {
            case .delay(let delay):
                time += Int64(delay)
            case .on(let x, let y, let currChain, _):
                events.append(GuideEvent(timeMs: time, x: x, y: y, chain: currChain))
            default:
                break
            }
        }
        return events
    }

    // MARK: - Lifecycle

    func launch() {
        guard task == nil || task?.isCancelled == true else { return }

        let previousRun = self.previousRun
        self.previousRun = nil
        task = Task(priority: .userInitiated) { [weak self] in
            // A run that stop() cancelled may still be inside its last iteration; let it finish
            // so two runs never touch guideTimeline / guideIndex at the same time.
            _ = await previousRun?.value
            guard let self, !Task.isCancelled else { return }

            // A completed step run can leave its final pads pending; every new run starts fresh.
            self.resetStepState()
            self.progress = 0
            self.listener?.onStart()

            guard let autoPlay = self.unipack.autoPlayTable else {
                // onStart already put the UI in the playing state; without this it never leaves it.
                self.task = nil
                self.listener?.onEnd()
                return
            }

            if self.practiceGuide {
                self.guideTimeline = self.buildGuideTimeline(autoPlay: autoPlay)
                self.guideIndex = 0
                self.waitingForChain = -1
                self.withGuides { $0.removeAll() }
            }

            // Close the LED timeline before sampling the new autoplay origin.
            self.listener?.onInputTimeThrough(self.playmode && !self.practiceGuide && !self.stepMode ? .min : nil)
            var delayAccum: Int64 = 0
            var startTime = self.clock()
            self.pausedAt = self.playmode ? nil : startTime
            self.pendingPauseMs = 0
            var rebaseSeekOnResume = false
            self.waitingForChain = -1
            self.timedWaitStart = nil
            self.pendingWaitReset = false
            self.resumeRequested = false

            // Step chain hints have no timed wait. Every exit from a timed guide wait
            // excludes only its playing time; explicit pauses are accounted for separately.
            @MainActor func finishChainWait(at now: Int64) {
                if let began = self.timedWaitStart {
                    startTime += max(0, (self.pausedAt ?? now) - began)
                }
                self.timedWaitStart = nil
                self.waitingForChain = -1
            }

            var prevPracticeGuide = self.practiceGuide
            self.suspendedTime.reset()
            self.pendingSkipMs = 0
            self.guideMoved = false

            while !Task.isCancelled {
                if self.isSuspended {
                    try? await self.sleep(UInt64(self.loopDelay * 1_000_000_000))
                    continue
                }
                let currTime = self.clock()

                let paused = self.pendingPauseMs
                self.pendingPauseMs = 0
                if paused > 0 {
                    startTime += paused
                    if let began = self.timedWaitStart { self.timedWaitStart = began + paused }
                }

                // Paused or waiting for a chain, the loop below already owes nothing for time passing.
                let skipped = self.suspendedTime.tick(at: currTime) + self.pendingSkipMs
                self.pendingSkipMs = 0
                if skipped > 0 && self.playmode && self.waitingForChain < 0 {
                    startTime += skipped
                    if self.practiceGuide { self.restartGuide(at: currTime - startTime) }
                }

                let resuming = self.playmode && self.resumeRequested
                if resuming {
                    self.resumeRequested = false
                    finishChainWait(at: currTime)
                    if self.practiceGuide { self.restartGuide(at: currTime - startTime) }
                }

                if self.guideMoved || (resuming && rebaseSeekOnResume) {
                    self.guideMoved = false
                    finishChainWait(at: currTime)
                    rebaseSeekOnResume = !self.playmode
                    if self.playmode {
                        delayAccum = self.timeMs(at: self.progress, in: autoPlay)
                        startTime = currTime - delayAccum
                        if self.practiceGuide { self.restartGuide(at: delayAccum) }
                    }
                }

                if self.pendingWaitReset {
                    self.pendingWaitReset = false
                    finishChainWait(at: currTime)
                }

                // The guide already waited for this group. Start its remaining notes now,
                // after settling any chain wait, even if paused before this tick.
                if self.playmode && !self.practiceGuide && self.pendingAutoplayStep?.needsOrigin == true {
                    startTime = currTime
                    delayAccum = 0
                    self.pendingAutoplayStep?.needsOrigin = false
                }

                // Detect mid-run practice mode toggle
                if self.practiceGuide != prevPracticeGuide {
                    finishChainWait(at: currTime)
                    if self.practiceGuide {
                        self.guideTimeline = self.buildGuideTimeline(autoPlay: autoPlay)
                        let elapsed = currTime - startTime
                        let idx = self.guideTimeline.firstIndex { $0.timeMs > elapsed - Self.guideLookaheadMs }
                        self.guideIndex = idx ?? self.guideTimeline.count
                        self.withGuides { $0.removeAll() }
                    } else {
                        for key in self.drainGuides() {
                            self.listener?.onGuideLedUpdate(x: key / 256, y: key % 256, velocity: 0)
                        }
                        self.guideTimeline = []
                        self.listener?.onRemoveGuide()
                    }
                    prevPracticeGuide = self.practiceGuide
                }

                if self.playmode {
                    // Practice mode: waiting for chain change
                    if self.practiceGuide && self.waitingForChain >= 0 {
                        if self.chain.value == self.waitingForChain {
                            finishChainWait(at: currTime)
                            self.listener?.onRemoveGuide()
                        }
                    } else {
                        self.handleBeforeStartPlaying()

                        // Guide lookahead
                        if self.practiceGuide {
                            let elapsed = currTime - startTime
                            while self.guideIndex < self.guideTimeline.count {
                                let event = self.guideTimeline[self.guideIndex]
                                guard event.timeMs <= elapsed + Self.guideLookaheadMs else { break }

                                if event.chain != self.chain.value {
                                    self.waitingForChain = event.chain
                                    self.timedWaitStart = currTime
                                    for key in self.drainGuides() {
                                        self.listener?.onGuideLedUpdate(x: key / 256, y: key % 256, velocity: 0)
                                    }
                                    self.listener?.onRemoveGuide()
                                    self.listener?.onGuideChainOn(c: event.chain)
                                    break
                                }

                                let targetWallTimeMs = startTime + event.timeMs
                                let key = self.guideKey(x: event.x, y: event.y)
                                self.withGuides { $0[key] = targetWallTimeMs }
                                self.listener?.onGuidePadOn(x: event.x, y: event.y, targetWallTimeMs: targetWallTimeMs)
                                self.guideIndex += 1
                            }

                            // Decide guide expiration and LED brightness in one pass before notifying.
                            let throttle = currTime - self.lastGuideUpdateMs >= Self.guideLedUpdateIntervalMs
                            var expired: [Int] = []
                            var ledUpdates: [(key: Int, velocity: Int)] = []
                            self.withGuides { guides in
                                guard !guides.isEmpty else { return }
                                for (key, targetMs) in guides {
                                    if currTime >= targetMs {
                                        expired.append(key)
                                    } else if throttle {
                                        let remaining = targetMs - currTime
                                        let p = min(max(1.0 - Float(remaining) / Float(Self.guideLookaheadMs), 0), 1)
                                        let idx = min(Int(p * Float(Self.guideVelocities.count)), Self.guideVelocities.count - 1)
                                        ledUpdates.append((key: key, velocity: Self.guideVelocities[idx]))
                                    }
                                }
                                for key in expired { guides.removeValue(forKey: key) }
                                if throttle { self.lastGuideUpdateMs = currTime }
                            }
                            for key in expired { self.turnOffGuide(key) }
                            for update in ledUpdates {
                                self.listener?.onGuideLedUpdate(x: update.key / 256, y: update.key % 256, velocity: update.velocity)
                            }
                        }

                        while self.waitingForChain < 0
                                && delayAccum <= currTime - startTime
                                && self.progress < autoPlay.elements.count {
                            let element = autoPlay.elements[self.progress]
                            switch element {
                            case .on(let x, let y, let currChain, let num):
                                let unplayed = self.pendingAutoplayStep?.pads.contains(self.guideKey(x: x, y: y)) ?? true
                                if !self.practiceGuide && unplayed {
                                    if self.chain.value != currChain {
                                        self.listener?.onChainChange(c: currChain)
                                    }
                                    self.unipack.soundPush(c: currChain, x: x, y: y, num: num)
                                    self.unipack.ledPush(c: currChain, x: x, y: y, num: num)
                                    let pad = Pad(x: x, y: y, chain: self.chain.value)
                                    let inputID = self.heldPads[pad] ?? UUID()
                                    self.heldPads[pad] = inputID
                                    self.listener?.onPadTouchOn(x: x, y: y, inputID: inputID, scheduledAtMs: startTime + delayAccum)
                                }

                            case .off(let x, let y, let currChain):
                                if !self.practiceGuide {
                                    if self.chain.value != currChain {
                                        self.listener?.onChainChange(c: currChain)
                                    }
                                    // Off names a physical pad, even after a wormhole or chain command.
                                    // The runner owns press identities; the screen never rebuilds them
                                    // from its current (possibly clamped) chain.
                                    let inputs = self.heldPads.filter { $0.key.x == x && $0.key.y == y }
                                    for pad in inputs.keys { self.heldPads.removeValue(forKey: pad) }
                                    self.listener?.onPadTouchOff(x: x, y: y, inputIDs: Array(inputs.values), scheduledAtMs: startTime + delayAccum)
                                }

                            case .delay(let delay):
                                delayAccum += Int64(delay)

                            case .chain(let c):
                                if !self.practiceGuide {
                                    self.listener?.onChainChange(c: c)
                                }
                            }
                            self.progress += 1
                            if let pending = self.pendingAutoplayStep, self.progress >= pending.endProgress {
                                self.pendingAutoplayStep = nil
                            }
                        }
                    }
                } else {
                    self.beforeStartPlaying = true

                    if self.stepMode && self.practiceGuide {
                        self.drainPressedKeys()

                        let currentChain = self.chain.value

                        // A chain change rewinds the current step for another scan.
                        let chainChanged = currentChain != self._stepChainValue && self._stepChainValue >= 0
                        var rewindTo: Int? = nil
                        if chainChanged && self._stepScanned {
                            rewindTo = self._stepStartProgress
                            self._stepPendingPads.removeAll()
                            self._stepScanned = false
                        }
                        self._stepChainValue = currentChain
                        if let rewindTo { self.progress = rewindTo }
                        if chainChanged { finishChainWait(at: currTime) }

                        var needsScan = false

                        if self.waitingForChain >= 0 {
                            if currentChain == self.waitingForChain {
                                finishChainWait(at: currTime)
                                needsScan = true
                            }
                        } else {
                            let scanned = self._stepScanned
                            let isEmpty = self._stepPendingPads.isEmpty

                            if !scanned || isEmpty {
                                needsScan = true
                            }
                        }

                        if needsScan {
                            self.listener?.onRemoveGuide()
                            self._stepStartProgress = self.progress
                            self.stepScanNext(autoPlay: autoPlay)
                            self._stepScanned = !self._stepPendingPads.isEmpty || self.waitingForChain >= 0
                        }
                    }
                }

                self.listener?.onInputTimeThrough(self.playmode && !self.practiceGuide && !self.stepMode ? currTime : nil)
                // Reading the final delay advances progress before that delay has elapsed.
                // A paused run still owns its remaining wait, even at the end of the table.
                if self.progress >= autoPlay.elements.count && !self.awaitsLastStep {
                    let songTime = (self.pausedAt ?? currTime) - startTime
                    if delayAccum <= songTime { break }
                    if !self.playmode && self.stepMode && self.practiceGuide { break }
                }
                try? await self.sleep(UInt64(self.loopDelay * 1_000_000_000))
            }

            // stop() already reset the UI; a cancelled run must not post another onEnd after it.
            guard !Task.isCancelled else { return }
            self.releaseHeldPads()
            self.listener?.onInputTimeThrough(nil)
            self.turnOffRemainingGuides()
            self.task = nil
            self.listener?.onEnd()
        }
    }

    /// The app left the front (`willResignActive`); it may be suspended before it comes back.
    func appWentAway() {
        // Foreground time since the last tick still belongs to the song.
        pendingSkipMs += suspendedTime.tick(at: clock())
        suspendedTime.appWentAway()
    }

    /// The app is in front again (`didBecomeActive`). The time it spent suspended is not played at once.
    func appReturned() {
        pendingSkipMs += suspendedTime.appReturned(at: clock())
    }

    func stop() {
        // A second stop() used to overwrite previousRun with nil and lose the handle the next
        // launch() waits on, letting two runs overlap.
        if let task { previousRun = task }
        task?.cancel()
        task = nil
        isSuspended = false
        releaseHeldPads()
        listener?.onInputTimeThrough(nil)
        withGuides { $0.removeAll() }
        resetStepState()
    }

    /// The scan of the last step group reaches the end of the table before the user plays it.
    private var awaitsLastStep: Bool {
        !playmode && stepMode && practiceGuide && !_stepPendingPads.isEmpty
    }

    private func turnOffGuide(_ key: Int) {
        listener?.onGuideLedUpdate(x: key / 256, y: key % 256, velocity: 0)
        listener?.onGuidePadOff(x: key / 256, y: key % 256)
    }

    /// A run that ends on its own leaves no guide lit, on screen or on the launchpad.
    private func turnOffRemainingGuides() {
        let keys = drainGuides() + _stepPendingPads
        _stepPendingPads.removeAll()
        for key in keys { turnOffGuide(key) }
    }

    private func handleBeforeStartPlaying() {
        if beforeStartPlaying {
            beforeStartPlaying = false
            listener?.onRemoveGuide()
        }
    }

    func progressOffset(_ offset: Int) {
        releaseHeldPads()
        pendingAutoplayStep = nil
        let target = progress + offset
        let count = unipack.autoPlayTable?.elements.count ?? 0
        progress = max(0, min(target, count))
        guideMoved = true
        if stepMode {
            resetStepState()
            listener?.onRemoveGuide()
        }
    }

    /// Preserve only the step prepared for sounding autoplay; silent guidance keeps its old cursor.
    func prepareStepForAutoplay() {
        guard practiceGuide && stepMode else { return }
        drainPressedKeys()
        guard waitingForChain < 0, _stepScanned, !_stepPendingPads.isEmpty,
              let autoPlay = unipack.autoPlayTable else { return }
        let firstPending = (_stepStartProgress..<progress).first { index in
            guard case .on(let x, let y, _, _) = autoPlay.elements[index] else { return false }
            return _stepPendingPads.contains(guideKey(x: x, y: y))
        }
        guard let firstPending else { return }
        pendingAutoplayStep = PendingAutoplayStep(endProgress: progress, pads: _stepPendingPads)
        progress = firstPending
    }

    func resetStepState(preservingPendingAutoplay: Bool = false) {
        if !preservingPendingAutoplay { pendingAutoplayStep = nil }
        _pressedKeysQueue.removeAll()

        _stepPendingPads.removeAll()
        _stepScanned = false
        _stepStartProgress = 0
        _stepChainValue = -1
        // The loop owns the song clock and settles any timed wait before clearing it.
        pendingWaitReset = true
    }

    func stepPadPressed(x: Int, y: Int) {
        guard !isSuspended else { return }
        let key = guideKey(x: x, y: y)
        _pressedKeysQueue.append(key)
    }

    private func drainPressedKeys() {
        let keys = _pressedKeysQueue
        _pressedKeysQueue.removeAll()

        var removedKeys: [Int] = []
        for key in keys {
            if _stepPendingPads.remove(key) != nil {
                removedKeys.append(key)
            }
        }

        for key in removedKeys { turnOffGuide(key) }
    }

    private func stepScanNext(autoPlay: AutoPlay) {
        // A fresh practice scan replaces any unconsumed autoplay preparation.
        pendingAutoplayStep = nil
        var newPending: Set<Int> = []
        var totalDelayMs: Int64 = 0

        scanLoop: while progress < autoPlay.elements.count {
            let element = autoPlay.elements[progress]
            switch element {
            case .on(let x, let y, let currChain, _):
                if chain.value != currChain {
                    if newPending.isEmpty {
                        waitingForChain = currChain
                        listener?.onGuideChainOn(c: currChain)
                    }
                    break scanLoop
                }
                let key = guideKey(x: x, y: y)
                newPending.insert(key)
                listener?.onGuidePadOn(x: x, y: y, targetWallTimeMs: 0)
                listener?.onGuideLedUpdate(x: x, y: y, velocity: Self.guideVelocities.last!)
                progress += 1

            case .off:
                progress += 1

            case .delay(let delay):
                totalDelayMs += Int64(delay)
                if !newPending.isEmpty && totalDelayMs >= Self.stepGroupThresholdMs {
                    break scanLoop
                }
                progress += 1

            case .chain:
                progress += 1
            }
        }

        _stepPendingPads = newPending
    }

}

extension AutoPlayRunner.Listener {
    func onInputTimeThrough(_ at: Int64?) {}

    func onPadTouchOn(x: Int, y: Int, inputID: UUID, scheduledAtMs: Int64) {
        onPadTouchOn(x: x, y: y, inputID: inputID)
    }

    func onPadTouchOff(x: Int, y: Int, inputIDs: [UUID], scheduledAtMs: Int64) {
        onPadTouchOff(x: x, y: y, inputIDs: inputIDs)
    }

    func onPadTouchCancel(x: Int, y: Int, inputID: UUID) {
        onPadTouchOff(x: x, y: y, inputIDs: [inputID])
    }
}
