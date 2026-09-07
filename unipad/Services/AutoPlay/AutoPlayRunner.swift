import Foundation
import QuartzCore

final class AutoPlayRunner {
    static let guideLookaheadMs: Int64 = 800
    private static let guideLedUpdateIntervalMs: Int64 = 50
    private static let guideVelocities: [Int] = [1, 2, 3, 21]
    private static let stepGroupThresholdMs: Int64 = 50

    private let unipack: UniPack
    private let chain: ChainObserver
    private let loopDelay: TimeInterval

    @Volatile var playmode: Bool = true
    @Volatile var beforeStartPlaying: Bool = true
    @Volatile var practiceGuide: Bool = false
    @Volatile var stepMode: Bool = false

    @Volatile private(set) var progress: Int = 0 {
        didSet { listener?.onProgressUpdate(progress: progress) }
    }

    private var task: Task<Void, Never>?
    var active: Bool { task.map { !$0.isCancelled } ?? false }

    protocol Listener: AnyObject {
        func onStart()
        func onPadTouchOn(x: Int, y: Int)
        func onPadTouchOff(x: Int, y: Int)
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

    private struct GuideEvent {
        let timeMs: Int64
        let x: Int
        let y: Int
        let chain: Int
    }

    private var guideTimeline: [GuideEvent] = []
    private var guideIndex: Int = 0
    private var waitingForChain: Int = -1
    private var waitStartTime: Int64 = 0

    // key = x*256+y, value = targetWallTimeMs
    /// Guide pads currently lit, keyed by guideKey. Written by the runner task and cleared by
    /// stop() on the main thread, so every access goes through withGuides (unipad-android #32
    /// was the same race on Android).
    private var activeGuides: [Int: Int64] = [:]
    private let guidesLock = NSLock()

    /// The run that stop() cancelled last; launch() waits for it so two runs never overlap.
    private var previousRun: Task<Void, Never>?

    @discardableResult
    private func withGuides<T>(file: String = #fileID, line: Int = #line, _ body: (inout [Int: Int64]) -> T) -> T {
        guidesLock.lockWithDeadlockDetection(file: file, line: line)
        defer { guidesLock.unlock() }
        return body(&activeGuides)
    }

    /// Empties activeGuides and returns the keys that were lit, for LED cleanup outside the lock.
    private func drainGuides(file: String = #fileID, line: Int = #line) -> [Int] {
        withGuides(file: file, line: line) { guides in
            let keys = Array(guides.keys)
            guides.removeAll()
            return keys
        }
    }
    private var lastGuideUpdateMs: Int64 = 0

    // Step mode state
    private let stepLock = NSLock()
    private var _stepPendingPads: Set<Int> = []
    private var _stepScanned = false
    private var _stepStartProgress: Int = 0
    private var _stepChainValue: Int = -1

    // Lock-free queue for pad presses from MainActor → runner thread
    private let pressedKeysLock = NSLock()
    private var _pressedKeysQueue: [Int] = []

    init(
        unipack: UniPack,
        listener: Listener,
        chain: ChainObserver,
        loopDelay: TimeInterval = 0.001
    ) {
        self.unipack = unipack
        self.listener = listener
        self.chain = chain
        self.loopDelay = loopDelay
    }

    private func guideKey(x: Int, y: Int) -> Int { x * 256 + y }

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
        task = Task.detached(priority: .userInitiated) { [weak self] in
            // A run that stop() cancelled may still be inside its last iteration; let it finish
            // so two runs never touch guideTimeline / guideIndex at the same time.
            _ = await previousRun?.value
            guard let self else { return }

            self.progress = 0
            self.listener?.onStart()

            guard let autoPlay = self.unipack.autoPlayTable else {
                // onStart already put the UI in the playing state; without this it never leaves it.
                self.listener?.onEnd()
                return
            }

            if self.practiceGuide {
                self.guideTimeline = self.buildGuideTimeline(autoPlay: autoPlay)
                self.guideIndex = 0
                self.waitingForChain = -1
                self.withGuides { $0.removeAll() }
            }

            var delayAccum: Int64 = 0
            var startTime = Self.currentTimeMillis()
            var prevPracticeGuide = self.practiceGuide

            while self.progress < autoPlay.elements.count && !Task.isCancelled {
                let currTime = Self.currentTimeMillis()

                // Detect mid-run practice mode toggle
                if self.practiceGuide != prevPracticeGuide {
                    if self.practiceGuide {
                        self.guideTimeline = self.buildGuideTimeline(autoPlay: autoPlay)
                        let elapsed = currTime - startTime
                        let idx = self.guideTimeline.firstIndex { $0.timeMs > elapsed - Self.guideLookaheadMs }
                        self.guideIndex = idx ?? self.guideTimeline.count
                        self.waitingForChain = -1
                        self.withGuides { $0.removeAll() }
                    } else {
                        for key in self.drainGuides() {
                            self.listener?.onGuideLedUpdate(x: key / 256, y: key % 256, velocity: 0)
                        }
                        self.guideTimeline = []
                        self.waitingForChain = -1
                        self.listener?.onRemoveGuide()
                    }
                    prevPracticeGuide = self.practiceGuide
                }

                if self.playmode {
                    // Practice mode: waiting for chain change
                    if self.practiceGuide && self.waitingForChain >= 0 {
                        if self.chain.value == self.waitingForChain {
                            startTime += currTime - self.waitStartTime
                            self.waitingForChain = -1
                            self.listener?.onRemoveGuide()
                        } else {
                            if delayAccum <= currTime - startTime {
                                delayAccum = currTime - startTime
                            }
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
                                    self.waitStartTime = currTime
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

                            // Guide expiration + LED brightness update: decide under the lock in one
                            // pass, emit the listener calls after it is released
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
                            for key in expired {
                                self.listener?.onGuideLedUpdate(x: key / 256, y: key % 256, velocity: 0)
                                self.listener?.onGuidePadOff(x: key / 256, y: key % 256)
                            }
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
                                if !self.practiceGuide {
                                    if self.chain.value != currChain {
                                        self.listener?.onChainChange(c: currChain)
                                    }
                                    self.unipack.soundPush(c: currChain, x: x, y: y, num: num)
                                    self.unipack.ledPush(c: currChain, x: x, y: y, num: num)
                                    self.listener?.onPadTouchOn(x: x, y: y)
                                }

                            case .off(let x, let y, let currChain):
                                if !self.practiceGuide {
                                    if self.chain.value != currChain {
                                        self.listener?.onChainChange(c: currChain)
                                    }
                                    self.listener?.onPadTouchOff(x: x, y: y)
                                }

                            case .delay(let delay):
                                delayAccum += Int64(delay)

                            case .chain(let c):
                                if !self.practiceGuide {
                                    self.listener?.onChainChange(c: c)
                                }
                            }
                            self.progress += 1
                        }
                    }
                } else {
                    self.beforeStartPlaying = true

                    if self.stepMode && self.practiceGuide {
                        self.drainPressedKeys()

                        let currentChain = self.chain.value

                        // 체인이 바뀌면 현재 스텝을 되돌리고 재스캔. resetStepState() writes the same
                        // fields from the main thread, so they are only touched under stepLock.
                        self.stepLock.lockWithDeadlockDetection()
                        let chainChanged = currentChain != self._stepChainValue && self._stepChainValue >= 0
                        var rewindTo: Int? = nil
                        if chainChanged && self._stepScanned {
                            rewindTo = self._stepStartProgress
                            self._stepPendingPads.removeAll()
                            self._stepScanned = false
                        }
                        self._stepChainValue = currentChain
                        self.stepLock.unlock()
                        if let rewindTo { self.progress = rewindTo }
                        if chainChanged { self.waitingForChain = -1 }

                        var needsScan = false

                        if self.waitingForChain >= 0 {
                            if currentChain == self.waitingForChain {
                                self.waitingForChain = -1
                                needsScan = true
                            }
                        } else {
                            self.stepLock.lockWithDeadlockDetection()
                            let scanned = self._stepScanned
                            let isEmpty = self._stepPendingPads.isEmpty
                            self.stepLock.unlock()

                            if !scanned || isEmpty {
                                needsScan = true
                            }
                        }

                        if needsScan {
                            self.listener?.onRemoveGuide()
                            self.stepLock.lockWithDeadlockDetection()
                            self._stepStartProgress = self.progress
                            self.stepLock.unlock()
                            self.stepScanNext(autoPlay: autoPlay)
                            self.stepLock.lockWithDeadlockDetection()
                            self._stepScanned = !self._stepPendingPads.isEmpty || self.waitingForChain >= 0
                            self.stepLock.unlock()
                        }
                    }

                    if delayAccum <= currTime - startTime {
                        delayAccum = currTime - startTime
                    }
                }

                try? await Task.sleep(nanoseconds: UInt64(self.loopDelay * 1_000_000_000))
            }

            // stop() already reset the UI; a cancelled run must not post another onEnd after it.
            guard !Task.isCancelled else { return }
            self.listener?.onEnd()
        }
    }

    func stop() {
        // A second stop() used to overwrite previousRun with nil and lose the handle the next
        // launch() waits on, letting two runs overlap.
        if let task { previousRun = task }
        task?.cancel()
        task = nil
        withGuides { $0.removeAll() }
        resetStepState()
    }

    private func handleBeforeStartPlaying() {
        if beforeStartPlaying {
            beforeStartPlaying = false
            listener?.onRemoveGuide()
        }
    }

    func progressOffset(_ offset: Int) {
        let target = progress + offset
        let count = unipack.autoPlayTable?.elements.count ?? 0
        progress = max(0, min(target, count))
        if stepMode {
            resetStepState()
            listener?.onRemoveGuide()
        }
    }

    func resetStepState() {
        pressedKeysLock.lockWithDeadlockDetection()
        _pressedKeysQueue.removeAll()
        pressedKeysLock.unlock()

        stepLock.lockWithDeadlockDetection()
        _stepPendingPads.removeAll()
        _stepScanned = false
        _stepStartProgress = 0
        _stepChainValue = -1
        stepLock.unlock()
    }

    func stepPadPressed(x: Int, y: Int) {
        let key = guideKey(x: x, y: y)
        pressedKeysLock.lockWithDeadlockDetection()
        _pressedKeysQueue.append(key)
        pressedKeysLock.unlock()
    }

    private func drainPressedKeys() {
        pressedKeysLock.lockWithDeadlockDetection()
        let keys = _pressedKeysQueue
        _pressedKeysQueue.removeAll()
        pressedKeysLock.unlock()

        stepLock.lockWithDeadlockDetection()
        var removedKeys: [Int] = []
        for key in keys {
            if _stepPendingPads.remove(key) != nil {
                removedKeys.append(key)
            }
        }
        stepLock.unlock()

        for key in removedKeys {
            listener?.onGuideLedUpdate(x: key / 256, y: key % 256, velocity: 0)
            listener?.onGuidePadOff(x: key / 256, y: key % 256)
        }
    }

    private func stepScanNext(autoPlay: AutoPlay) {
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

        stepLock.lockWithDeadlockDetection()
        _stepPendingPads = newPending
        stepLock.unlock()
    }

    private static func currentTimeMillis() -> Int64 {
        Int64(CACurrentMediaTime() * 1000)
    }
}

// Property wrapper for thread-safe volatile-like access.
// A class, not a struct: a struct wrapper's setter is `mutating`, so a write held a *modify*
// access on the enclosing stored property for the whole locked call while the runner thread
// read it, and Swift's runtime exclusivity check trapped ("Simultaneous accesses") when play
// mode was switched or the seek control dragged during playback. The NSLock never covered that.
@propertyWrapper
final class Volatile<Value: Sendable>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()

    init(wrappedValue: Value) {
        _value = wrappedValue
    }

    var wrappedValue: Value {
        get {
            lock.lockWithDeadlockDetection()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lockWithDeadlockDetection()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}
