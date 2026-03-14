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
    var active: Bool { task != nil && !task!.isCancelled }

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
    private var activeGuides: [Int: Int64] = [:]
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
        guard task == nil || task!.isCancelled else { return }

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            self.progress = 0
            self.listener?.onStart()

            guard let autoPlay = self.unipack.autoPlayTable else { return }

            if self.practiceGuide {
                self.guideTimeline = self.buildGuideTimeline(autoPlay: autoPlay)
                self.guideIndex = 0
                self.waitingForChain = -1
                self.activeGuides.removeAll()
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
                        self.activeGuides.removeAll()
                    } else {
                        for (key, _) in self.activeGuides {
                            self.listener?.onGuideLedUpdate(x: key / 256, y: key % 256, velocity: 0)
                        }
                        self.activeGuides.removeAll()
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
                                    for (key, _) in self.activeGuides {
                                        self.listener?.onGuideLedUpdate(x: key / 256, y: key % 256, velocity: 0)
                                    }
                                    self.activeGuides.removeAll()
                                    self.listener?.onRemoveGuide()
                                    self.listener?.onGuideChainOn(c: event.chain)
                                    break
                                }

                                let targetWallTimeMs = startTime + event.timeMs
                                self.activeGuides[self.guideKey(x: event.x, y: event.y)] = targetWallTimeMs
                                self.listener?.onGuidePadOn(x: event.x, y: event.y, targetWallTimeMs: targetWallTimeMs)
                                self.guideIndex += 1
                            }

                            // Guide expiration + LED brightness update
                            if !self.activeGuides.isEmpty {
                                let throttle = currTime - self.lastGuideUpdateMs >= Self.guideLedUpdateIntervalMs
                                var keysToRemove: [Int] = []
                                for (key, targetMs) in self.activeGuides {
                                    let gx = key / 256
                                    let gy = key % 256
                                    if currTime >= targetMs {
                                        keysToRemove.append(key)
                                        self.listener?.onGuideLedUpdate(x: gx, y: gy, velocity: 0)
                                        self.listener?.onGuidePadOff(x: gx, y: gy)
                                    } else if throttle {
                                        let remaining = targetMs - currTime
                                        let p = min(max(1.0 - Float(remaining) / Float(Self.guideLookaheadMs), 0), 1)
                                        let idx = min(Int(p * Float(Self.guideVelocities.count)), Self.guideVelocities.count - 1)
                                        self.listener?.onGuideLedUpdate(x: gx, y: gy, velocity: Self.guideVelocities[idx])
                                    }
                                }
                                for key in keysToRemove {
                                    self.activeGuides.removeValue(forKey: key)
                                }
                                if throttle { self.lastGuideUpdateMs = currTime }
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

                        // 체인이 바뀌면 현재 스텝을 되돌리고 재스캔
                        if currentChain != self._stepChainValue && self._stepChainValue >= 0 {
                            self.stepLock.lockWithDeadlockDetection()
                            if self._stepScanned {
                                self.progress = self._stepStartProgress
                                self._stepPendingPads.removeAll()
                                self._stepScanned = false
                            }
                            self.stepLock.unlock()
                            self.waitingForChain = -1
                        }
                        self._stepChainValue = currentChain

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
                            self._stepStartProgress = self.progress
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

            self.listener?.onEnd()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        activeGuides.removeAll()
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
        progress = max(0, min(target, Int.max))
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

// Property wrapper for thread-safe volatile-like access
@propertyWrapper
struct Volatile<Value: Sendable> {
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
