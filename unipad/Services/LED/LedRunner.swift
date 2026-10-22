import Foundation
import QuartzCore
import os

nonisolated private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "LedRunner")

/// The LED tables are touched under `lock` from the main actor and from the loop task; `loopTask`
/// is only started and stopped on the main actor.
nonisolated final class LedRunner: @unchecked Sendable {
    static let circularLedCount = 36

    private let unipack: UniPack
    private let chain: ChainObserver
    private let loopDelay: TimeInterval
    private let clock: () -> Int64

    private var btnLed: [[Led?]]
    private var cirLed: [Led?]
    private var ledAnimationStates: [LedAnimationState] = []
    private var ledAnimationStatesAdd: [LedAnimationState] = []

    private var requests: Int64 = 0
    private var pausedAt: Int64?
    private var inputTimeThrough: Int64?
    // Autoplay input can reach the runner after an animation's last event.
    private static let latePressMs: Int64 = 1_000

    private let lock = NSLock()

    var active: Bool { loopTask != nil }

    enum LedEvent {
        case padOn(x: Int, y: Int, color: Int, velocity: Int)
        case padOff(x: Int, y: Int)
        case chainOn(c: Int, color: Int, velocity: Int)
        case chainOff(c: Int)
    }

    /// Called on the loop task.
    protocol Listener: AnyObject {
        func onLedBatch(_ events: [LedEvent])
    }

    private weak var listener: Listener?

    init(
        unipack: UniPack,
        listener: Listener,
        chain: ChainObserver,
        loopDelay: TimeInterval = 0.004,
        clock: @escaping () -> Int64 = { Int64(CACurrentMediaTime() * 1000) }
    ) {
        self.unipack = unipack
        self.listener = listener
        self.chain = chain
        self.loopDelay = loopDelay
        self.clock = clock

        btnLed = Array(
            repeating: Array(repeating: nil as Led?, count: unipack.buttonY),
            count: unipack.buttonX
        )
        cirLed = Array(repeating: nil, count: Self.circularLedCount)
    }

    // MARK: - Timer Lifecycle

    private var loopTask: Task<Void, Never>?

    func launch() {
        guard loopTask == nil else { return }
        lock.lockWithDeadlockDetection()
        if let pausedAt {
            let pausedFor = clock() - pausedAt
            for state in ledAnimationStates + ledAnimationStatesAdd {
                state.resume(pausedSince: pausedAt, pausedFor: pausedFor)
            }
        }
        pausedAt = nil
        lock.unlock()

        loopTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let intervalNs = UInt64(self.loopDelay * 1_000_000_000)

            while !Task.isCancelled {
                let start = ContinuousClock.now
                // loop() takes `lock`; the extra queue.sync only parked a cooperative-pool thread
                // for the whole locked body every 4 ms.
                self.loop()
                let elapsed = ContinuousClock.now - start
                // components.seconds counted too: a loop over 1 s used to wrap to its sub-second part
                let elapsedNs = UInt64(clamping: elapsed.components.seconds) * 1_000_000_000
                    + UInt64(elapsed.components.attoseconds / 1_000_000_000)
                let remaining = elapsedNs < intervalNs ? intervalNs - elapsedNs : 0
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: remaining)
                }
            }
        }
    }

    func stop() {
        lock.lockWithDeadlockDetection()
        if active { pausedAt = clock() }
        loopTask?.cancel()
        loopTask = nil
        lock.unlock()
    }

    // MARK: - Main Loop

    /// One tick. Internal so tests can drive it with a manual `clock`.
    func loop() {
        var pendingLedEvents: [LedEvent] = []
        var pendingChainSets: [Int] = []
        lock.lockWithDeadlockDetection()
        // Autoplay can be a millisecond behind this task. Do not render a later
        // step until its earlier scheduled inputs have reached the runner.
        let currTime = min(clock(), inputTimeThrough ?? .max)
        ledAnimationStates.append(contentsOf: ledAnimationStatesAdd)
        ledAnimationStatesAdd.removeAll(keepingCapacity: true)

        // Merge each animation's next step by intended time before applying LED ownership.
        // Sorting the output afterwards would already have lost or added owner-dependent offs.
        var due = StepQueue()
        for state in ledAnimationStates {
            state.processed = 0
            if let step = state.nextStep(currTime) { due.push(step) }
        }
        while let step = due.pop() {
            if step.rank == Step.shutdown {
                shutDown(step.state, pendingLedEvents: &pendingLedEvents)
            } else {
                playEvent(step.state, at: step.at, pendingLedEvents: &pendingLedEvents, pendingChainSets: &pendingChainSets)
            }
            if let next = step.state.nextStep(currTime) { due.push(next) }
        }
        ledAnimationStates.removeAll { $0.remove }
        lock.unlock()

        // Chain observers mutate UI state and rotate pack tables on the main actor.
        if !pendingChainSets.isEmpty {
            let chain = self.chain
            let chainSets = pendingChainSets
            Task { @MainActor in
                for c in chainSets { chain.setValue(c) }
            }
        }
        if !pendingLedEvents.isEmpty { listener?.onLedBatch(pendingLedEvents) }
    }

    private func playEvent(_ state: LedAnimationState, at: Int64,
                           pendingLedEvents: inout [LedEvent], pendingChainSets: inout [Int]) {
        guard let animation = state.ledAnimation else { return }
        if state.index == 0 { state.loopStartTime = state.delay }
        let event = animation.ledEvents[state.index]
        state.processed += 1
        switch event {
        case .on(let x, let y, let color, let velocity):
            if x != -1 {
                guard isValidPadIndex(x: x, y: y) else {
                    break
                }
                pendingLedEvents.append(.padOn(x: x, y: y, color: color, velocity: velocity))
                btnLed[x][y] = Led(buttonX: state.buttonX, buttonY: state.buttonY, chain: state.chainAtCreation)
            } else {
                guard isValidCircularIndex(y) else {
                    break
                }
                pendingLedEvents.append(.chainOn(c: y, color: color, velocity: velocity))
                cirLed[y] = Led(buttonX: state.buttonX, buttonY: state.buttonY, chain: state.chainAtCreation)
            }

        case .off(let x, let y):
            if x != -1 {
                guard isValidPadIndex(x: x, y: y) else {
                    break
                }
                if btnLed[x][y]?.isEqual(bx: state.buttonX, by: state.buttonY, chain: state.chainAtCreation) == true {
                    pendingLedEvents.append(.padOff(x: x, y: y))
                    btnLed[x][y] = nil
                }
            } else {
                guard isValidCircularIndex(y) else {
                    break
                }
                if cirLed[y]?.isEqual(bx: state.buttonX, by: state.buttonY, chain: state.chainAtCreation) == true {
                    pendingLedEvents.append(.chainOff(c: y))
                    cirLed[y] = nil
                }
            }

        case .delay(let delay):
            state.delay += Int64(delay)

        case .chain(let chainValue):
            pendingChainSets.append(chainValue)
        }
        state.index += 1
        state.finishIfDone(at: at)
    }

    private func shutDown(_ state: LedAnimationState, pendingLedEvents: inout [LedEvent]) {
        for x in 0..<unipack.buttonX {
            for y in 0..<unipack.buttonY {
                if btnLed[x][y]?.isEqual(bx: state.buttonX, by: state.buttonY, chain: state.chainAtCreation) == true {
                    pendingLedEvents.append(.padOff(x: x, y: y))
                    btnLed[x][y] = nil
                }
            }
        }
        for y in 0..<cirLed.count {
            if cirLed[y]?.isEqual(bx: state.buttonX, by: state.buttonY, chain: state.chainAtCreation) == true {
                pendingLedEvents.append(.chainOff(c: y))
                cirLed[y] = nil
            }
        }
        state.remove = true
    }

    /// Autoplay has delivered every scheduled input through this time; nil releases the bound.
    /// A new run uses .min until its first input batch has been delivered.
    func setInputTimeThrough(_ at: Int64?) {
        lock.lockWithDeadlockDetection()
        inputTimeThrough = at
        lock.unlock()
    }

    // MARK: - Event Control

    func isEventExist(x: Int, y: Int, chain: Int) -> Bool {
        lock.lockWithDeadlockDetection()
        defer { lock.unlock() }
        return (ledAnimationStates + ledAnimationStatesAdd).contains { $0.isPlaying && $0.isEqual(bx: x, by: y, chain: chain) }
    }

    /// Any chain: ledInit must find animations started on a previous chain too.
    func isEventExist(x: Int, y: Int) -> Bool {
        lock.lockWithDeadlockDetection()
        defer { lock.unlock() }
        return (ledAnimationStates + ledAnimationStatesAdd).contains { $0.isPlaying && $0.buttonX == x && $0.buttonY == y }
    }

    @MainActor
    func eventOn(x: Int, y: Int, pressedAt: Int64? = nil) {
        guard active else {
            logger.debug("eventOn(\(x),\(y)): not active")
            return
        }
        lock.lockWithDeadlockDetection()
        defer { lock.unlock() }

        let at = pressedAt ?? clock()
        requests += 1
        for existing in ledAnimationStates + ledAnimationStatesAdd where existing.isEqual(bx: x, by: y, chain: chain.value) {
            existing.shutDownAt(at, order: requests)
        }

        let state = LedAnimationState(
            buttonX: x,
            buttonY: y,
            unipack: unipack,
            chain: chain.value,
            startedAt: at,
            order: requests
        )
        if state.noError {
            ledAnimationStatesAdd.append(state)
            logger.debug("eventOn(\(x),\(y)): queued, events=\(state.ledAnimation?.ledEvents.count ?? 0)")
        } else {
            logger.debug("eventOn(\(x),\(y)): no animation found for chain=\(self.chain.value)")
        }
    }

    @MainActor
    func eventOff(x: Int, y: Int, releasedAt: Int64? = nil) {
        guard active else { return }
        lock.lockWithDeadlockDetection()
        defer { lock.unlock() }

        let at = releasedAt ?? clock()
        requests += 1
        for state in ledAnimationStates + ledAnimationStatesAdd where state.isEqual(bx: x, by: y, chain: chain.value) {
            if state.ledAnimation?.loop == 0 { state.shutDownAt(at, order: requests) }
        }
    }

    /// Shuts down every infinite animation on the pad, on any chain, and without the `active`
    /// guard: ledInit calls this after stop(), where eventOff returned early and the stale
    /// animations resumed in a burst when LED was re-enabled (Android LedRunner.eventOffAll).
    func eventOffAll(x: Int, y: Int) {
        lock.lockWithDeadlockDetection()
        defer { lock.unlock() }

        for state in ledAnimationStates + ledAnimationStatesAdd where state.buttonX == x && state.buttonY == y {
            if state.ledAnimation?.loop == 0 { state.shutDownAt(.min, order: 0) }
        }
    }

    // MARK: - Helper Types

    private struct Led {
        let buttonX: Int
        let buttonY: Int
        let chain: Int

        func isEqual(bx: Int, by: Int, chain: Int) -> Bool {
            buttonX == bx && buttonY == by && self.chain == chain
        }
    }

    /// At the same millisecond: running events, input shutdowns, then new animations.
    private struct Step {
        static let running = 0
        static let shutdown = 1
        static let starting = 2
        let state: LedAnimationState
        let at: Int64
        let rank: Int
        let order: Int64

        func precedes(_ other: Step) -> Bool { (at, rank, order) < (other.at, other.rank, other.order) }
    }

    /// Only one pending step per animation, so ordering does not copy a whole overdue animation.
    private struct StepQueue {
        private var heap: [Step] = []

        mutating func push(_ step: Step) {
            heap.append(step)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard heap[child].precedes(heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> Step? {
            guard !heap.isEmpty else { return nil }
            if heap.count == 1 { return heap.removeLast() }
            let first = heap[0]
            heap[0] = heap.removeLast()
            var parent = 0
            while parent * 2 + 1 < heap.count {
                var child = parent * 2 + 1
                if child + 1 < heap.count, heap[child + 1].precedes(heap[child]) { child += 1 }
                guard heap[child].precedes(heap[parent]) else { break }
                heap.swapAt(child, parent)
                parent = child
            }
            return first
        }
    }

    private class LedAnimationState {
        // This storage has no UI cleanup; avoid actor-isolated cleanup on older runtimes.
        nonisolated deinit {}

        let buttonX: Int
        let buttonY: Int
        let chainAtCreation: Int
        private var startedAt: Int64
        private let order: Int64
        var index = 0
        var delay: Int64
        var loopStartTime: Int64?
        var isPlaying = true
        private var shutdownAt: Int64?
        private var shutdownOrder: Int64 = 0
        private var finishedAt: Int64?
        var remove = false
        var loopProgress = 0
        var processed = 0
        let ledAnimation: LedAnimation?

        var noError: Bool { ledAnimation != nil }

        func isEqual(bx: Int, by: Int, chain: Int) -> Bool {
            buttonX == bx && buttonY == by && chainAtCreation == chain
        }

        init(buttonX: Int, buttonY: Int, unipack: UniPack, chain: Int, startedAt: Int64, order: Int64) {
            self.buttonX = buttonX
            self.buttonY = buttonY
            self.chainAtCreation = chain
            self.startedAt = startedAt
            self.delay = startedAt
            self.order = order
            self.ledAnimation = unipack.ledGet(c: chain, x: buttonX, y: buttonY)
            unipack.ledPush(c: chain, x: buttonX, y: buttonY)
            if ledAnimation?.ledEvents.isEmpty != false { isPlaying = false }
        }

        func shutDownAt(_ at: Int64, order: Int64) {
            if let shutdownAt, at >= shutdownAt { return }
            shutdownAt = at
            shutdownOrder = order
        }

        func resume(pausedSince: Int64, pausedFor: Int64) {
            startedAt += pausedFor
            delay += pausedFor
            loopStartTime = loopStartTime.map { $0 + pausedFor }
            finishedAt = finishedAt.map { $0 + pausedFor }
            shutdownAt = shutdownAt.map { min($0, pausedSince) + pausedFor }
        }

        func nextStep(_ now: Int64) -> Step? {
            guard !remove, let animation = ledAnimation else {
                remove = true
                return nil
            }
            let shutdown = shutdownAt.map { Step(state: self, at: $0, rank: Step.shutdown, order: shutdownOrder) }
            if !isPlaying {
                // Keep the last state briefly for a press timestamped before its final event.
                if let shutdown, let finishedAt, shutdown.at < finishedAt, shutdown.at <= now { return shutdown }
                if let finishedAt {
                    remove = now > finishedAt && now - finishedAt > LedRunner.latePressMs
                } else {
                    remove = true
                }
                return nil
            }
            var event: Step? = Step(state: self, at: delay,
                                    rank: delay == startedAt ? Step.starting : Step.running, order: order)
            // Endless strobes yield after one pass plus one event and drop their backlog.
            // Finite passes with no elapsed time are collapsed by finishIfDone instead.
            if animation.loop == 0 && delay <= now && processed > animation.ledEvents.count {
                delay = now
                event = nil
            }
            let next: Step?
            if let event {
                if let shutdown, shutdown.precedes(event) { next = shutdown } else { next = event }
            } else {
                next = shutdown
            }
            return next.flatMap { $0.at <= now ? $0 : nil }
        }

        func finishIfDone(at: Int64) {
            guard let animation = ledAnimation, index >= animation.ledEvents.count else { return }
            loopProgress += 1
            index = 0
            if animation.loop > 0 && (loopProgress >= animation.loop || loopStartTime.map { delay <= $0 } == true) {
                isPlaying = false
                finishedAt = at
            }
        }
    }

    private func isValidPadIndex(x: Int, y: Int) -> Bool {
        x >= 0 && x < btnLed.count && y >= 0 && y < btnLed[x].count
    }

    private func isValidCircularIndex(_ y: Int) -> Bool {
        y >= 0 && y < cirLed.count
    }
}
