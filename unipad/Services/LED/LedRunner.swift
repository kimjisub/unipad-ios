import Foundation
import QuartzCore
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "LedRunner")

final class LedRunner {
    static let circularLedCount = 36

    private let unipack: UniPack
    private let chain: ChainObserver
    private let loopDelay: TimeInterval

    private var btnLed: [[Led?]]
    private var cirLed: [Led?]
    private var ledAnimationStates: [LedAnimationState] = []
    private var ledAnimationStatesAdd: [LedAnimationState] = []

    private let queue = DispatchQueue(label: "com.unipad.ledrunner", qos: .userInteractive)
    private let lock = NSLock()

    var active: Bool { loopTask != nil }

    enum LedEvent {
        case padOn(x: Int, y: Int, color: Int, velocity: Int)
        case padOff(x: Int, y: Int)
        case chainOn(c: Int, color: Int, velocity: Int)
        case chainOff(c: Int)
    }

    protocol Listener: AnyObject {
        func onLedBatch(_ events: [LedEvent])
    }

    private weak var listener: Listener?

    init(
        unipack: UniPack,
        listener: Listener,
        chain: ChainObserver,
        loopDelay: TimeInterval = 0.004
    ) {
        self.unipack = unipack
        self.listener = listener
        self.chain = chain
        self.loopDelay = loopDelay

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

        loopTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let intervalNs = UInt64(self.loopDelay * 1_000_000_000)

            while !Task.isCancelled {
                let start = ContinuousClock.now
                self.queue.sync { self.loop() }
                let elapsed = ContinuousClock.now - start
                let elapsedNs = UInt64(elapsed.components.attoseconds / 1_000_000_000)
                let remaining = elapsedNs < intervalNs ? intervalNs - elapsedNs : 0
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: remaining)
                }
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: - Main Loop

    private var loopLogCount = 0
    private func loop() {
        var pendingLedEvents: [LedEvent] = []
        var pendingChainSets: [Int] = []

        lock.lockWithDeadlockDetection()

        let currTime = Self.currentTimeMillis()

        if !ledAnimationStates.isEmpty || !ledAnimationStatesAdd.isEmpty {
            loopLogCount += 1
            if loopLogCount <= 3 {
                logger.debug("loop: states=\(self.ledAnimationStates.count), add=\(self.ledAnimationStatesAdd.count), listener=\(self.listener != nil)")
            }
        }

        for state in ledAnimationStates {
            if state.isPlaying && !state.isShutdown {
                if state.delay == 0 { state.delay = currTime }

                while true {
                    guard let ledAnimation = state.ledAnimation else { break }
                    let ledEvents = ledAnimation.ledEvents
                    if state.index >= ledEvents.count {
                        state.loopProgress += 1
                        state.index = 0
                        if state.delay <= currTime {
                            break
                        }
                    }

                    if ledAnimation.loop != 0 && ledAnimation.loop <= state.loopProgress {
                        state.isPlaying = false
                        break
                    }

                    guard state.delay <= currTime else { break }

                    let event = ledEvents[state.index]
                    switch event {
                    case .on(let x, let y, let color, let velocity):
                        if x != -1 {
                            guard isValidPadIndex(x: x, y: y) else {
                                state.index += 1
                                continue
                            }
                            if loopLogCount <= 5 {
                                logger.debug("LED ON: x=\(x) y=\(y) color=\(color) vel=\(velocity) listener=\(self.listener != nil)")
                                loopLogCount += 1
                            }
                            pendingLedEvents.append(.padOn(x: x, y: y, color: color, velocity: velocity))
                            btnLed[x][y] = Led(buttonX: state.buttonX, buttonY: state.buttonY)
                        } else {
                            guard isValidCircularIndex(y) else {
                                state.index += 1
                                continue
                            }
                            pendingLedEvents.append(.chainOn(c: y, color: color, velocity: velocity))
                            cirLed[y] = Led(buttonX: state.buttonX, buttonY: state.buttonY)
                        }

                    case .off(let x, let y):
                        if x != -1 {
                            guard isValidPadIndex(x: x, y: y) else {
                                state.index += 1
                                continue
                            }
                            if btnLed[x][y]?.isEqual(bx: state.buttonX, by: state.buttonY) == true {
                                pendingLedEvents.append(.padOff(x: x, y: y))
                                btnLed[x][y] = nil
                            }
                        } else {
                            guard isValidCircularIndex(y) else {
                                state.index += 1
                                continue
                            }
                            if cirLed[y]?.isEqual(bx: state.buttonX, by: state.buttonY) == true {
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
                }

            } else if state.isShutdown {
                for x in 0..<unipack.buttonX {
                    for y in 0..<unipack.buttonY {
                        if btnLed[x][y]?.isEqual(bx: state.buttonX, by: state.buttonY) == true {
                            pendingLedEvents.append(.padOff(x: x, y: y))
                            btnLed[x][y] = nil
                        }
                    }
                }
                for y in 0..<cirLed.count {
                    if cirLed[y]?.isEqual(bx: state.buttonX, by: state.buttonY) == true {
                        pendingLedEvents.append(.chainOff(c: y))
                        cirLed[y] = nil
                    }
                }
                state.remove = true
            } else {
                state.remove = true
            }
        }

        ledAnimationStates.append(contentsOf: ledAnimationStatesAdd)
        ledAnimationStatesAdd.removeAll()
        ledAnimationStates.removeAll { $0.remove }

        lock.unlock()

        for c in pendingChainSets {
            chain.setValue(c)
        }

        if !pendingLedEvents.isEmpty {
            listener?.onLedBatch(pendingLedEvents)
        }
    }

    // MARK: - Event Control

    func isEventExist(x: Int, y: Int) -> Bool {
        lock.lockWithDeadlockDetection()
        defer { lock.unlock() }
        return ledAnimationStates.contains { $0.isEqual(bx: x, by: y) }
    }

    func eventOn(x: Int, y: Int) {
        guard active else {
            logger.debug("eventOn(\(x),\(y)): not active")
            return
        }
        lock.lockWithDeadlockDetection()
        defer { lock.unlock() }

        if let existing = ledAnimationStates.first(where: { $0.isEqual(bx: x, by: y) }) {
            existing.isShutdown = true
        }

        let state = LedAnimationState(
            buttonX: x,
            buttonY: y,
            unipack: unipack,
            chain: chain
        )
        if state.noError {
            ledAnimationStatesAdd.append(state)
            logger.debug("eventOn(\(x),\(y)): queued, events=\(state.ledAnimation?.ledEvents.count ?? 0)")
        } else {
            logger.debug("eventOn(\(x),\(y)): no animation found for chain=\(self.chain.value)")
        }
    }

    func eventOff(x: Int, y: Int) {
        guard active else { return }
        lock.lockWithDeadlockDetection()
        defer { lock.unlock() }

        if let state = ledAnimationStates.first(where: { $0.isEqual(bx: x, by: y) }),
           state.ledAnimation?.loop == 0 {
            state.isShutdown = true
        }
    }

    // MARK: - Helper Types

    private struct Led {
        let buttonX: Int
        let buttonY: Int

        func isEqual(bx: Int, by: Int) -> Bool {
            buttonX == bx && buttonY == by
        }
    }

    private class LedAnimationState {
        let buttonX: Int
        let buttonY: Int
        var index: Int = 0
        var delay: Int64 = 0
        var isPlaying: Bool = true
        var isShutdown: Bool = false
        var remove: Bool = false
        var loopProgress: Int = 0
        let ledAnimation: LedAnimation?

        var noError: Bool { ledAnimation != nil }

        func isEqual(bx: Int, by: Int) -> Bool {
            buttonX == bx && buttonY == by
        }

        init(buttonX: Int, buttonY: Int, unipack: UniPack, chain: ChainObserver) {
            self.buttonX = buttonX
            self.buttonY = buttonY
            self.ledAnimation = unipack.ledGet(c: chain.value, x: buttonX, y: buttonY)
            unipack.ledPush(c: chain.value, x: buttonX, y: buttonY)
        }
    }

    private static func currentTimeMillis() -> Int64 {
        Int64(CACurrentMediaTime() * 1000)
    }

    private func isValidPadIndex(x: Int, y: Int) -> Bool {
        x >= 0 && x < btnLed.count && y >= 0 && y < btnLed[x].count
    }

    private func isValidCircularIndex(_ y: Int) -> Bool {
        y >= 0 && y < cirLed.count
    }
}
