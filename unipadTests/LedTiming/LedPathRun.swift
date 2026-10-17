import QuartzCore
import XCTest
@testable import unipad

/// Milliseconds since autoplay started, shared by the main actor and the LED loop.
nonisolated final class LedRunClock: @unchecked Sendable {
    private let lock = NSLock()
    private var start: CFTimeInterval?

    func begin() { lock.withLock { start = CACurrentMediaTime() } }

    /// When autoplay started (CACurrentMediaTime); nil before.
    var started: CFTimeInterval? { lock.withLock { start } }

    /// Nil before autoplay starts.
    func now() -> Double? {
        lock.withLock { start.map { (CACurrentMediaTime() - $0) * 1000 } }
    }
}

nonisolated struct LedPathRecording {
    /// LedRunner's changes as commands, in the order and at the time it handed them over.
    let handedOver: [LedCommand]
    /// Commands that carried an LED runner change, in the order the driver received them.
    let toDriver: [LedCommand]
    /// When each autoplay press reached the play screen, in order.
    let pressTimes: [Double]
    /// Commands a release or a chain change sent to redraw the screen's state, which no keyLED event asked for.
    let repaints: Int
    /// LED runner commands that went out with another channel's colour on top, such as the current
    /// chain's indicator; `toDriver` holds them with the LED channel's code.
    let covered: Int
    /// Everything the driver was asked to send that a Launchpad MK2 can show, repaints included, in
    /// order; empty unless the run sent MIDI to a VirtualLaunchpad.
    let toMidi: [LedCommand]
    /// Which of `toMidi` were repaints.
    let toMidiRepaints: [Bool]
    /// What arrived at the VirtualLaunchpad (T2); nil when the run sent no MIDI.
    let departed: [LedCommand]?
}

/// Plays a pack's autoplay in real time through the play screen's own LED path, from AutoPlayRunner
/// to the Launchpad driver, and records what the driver is asked to send:
///
/// AutoPlayRunner (main actor, 1 ms loop) → PlayViewModel.padTouch → LedRunner (its 4 ms loop task) →
/// LedListenerAdapter → main actor → ChannelManager → refreshPadFromChannel / refreshChainFromChannel →
/// MidiManager.shared.driver.sendPadLed / sendFunctionKeyLed.
///
/// What LedRunner hands over is recorded too, so a difference can be placed before or after it.
///
/// Every part is the app's, on the real clock, except two stand-ins: the AutoPlayRunner listener (the
/// three calls PlayViewModel's autoplay adapter makes for presses, releases and chains) and the driver,
/// which records what it is asked to send and, given a VirtualLaunchpad's arrivals file, passes it on to
/// the Launchpad MK2 driver MidiManager uses for that device, so the app's own MIDI output path runs too. The feedback
/// light and practice guide stay off, as in autoplay, so no other channel covers the pack's LEDs; Pro
/// light mode is on so that round LEDs and the logo reach the driver. No sound engine runs.
@MainActor
final class LedPathRun {
    private let pack: UniPack
    private let clock = LedRunClock()
    private let vm = PlayViewModel()
    private var driver: RecordingDriver?
    private var handover: HandoverRecorder?
    private var autoPlayListener: AutoPlayStandIn?

    private let midiArrivals: URL?

    init(pack: UniPack, midiArrivals: URL? = nil) {
        self.pack = pack
        self.midiArrivals = midiArrivals
    }

    /// Plays the autoplay, releases every pad at `releaseAllAtMs` as PlayViewModel.padInit does (ending
    /// endless animations), waits until no animation runs or `giveUpAtMs` passes, and returns what the
    /// driver received. Times count from AutoPlayRunner's start.
    func run(releaseAllAtMs: Int64, giveUpAtMs: Int64) async throws -> LedPathRecording {
        vm.unipack = pack
        vm.initState()
        vm.proLightMode(true)
        XCTAssertFalse(vm.scbFeedbackLight.checked, "the feedback light would cover the pack's LEDs")

        let manager = MidiManager.shared
        // A connected device would receive the run, and its connecting or leaving replaces the driver.
        guard midiArrivals != nil || !manager.isConnected else {
            throw LedPathRunError("a MIDI device (\(manager.connectedDeviceName ?? "?")) is connected; disconnect it or run in MIDI mode")
        }
        let launchpad: VirtualLaunchpad? = if let midiArrivals { try await VirtualLaunchpad.connect(arrivalsFile: midiArrivals) } else { nil }
        defer { launchpad?.disconnect() }
        let previousDriver = manager.driver
        let driver = RecordingDriver(clock: clock, channels: try XCTUnwrap(vm.channelManager))
        self.driver = driver
        // Bracket the app's chain observer, including changes made by keyLED's `c` command.
        // ChainObserver notifies in registration order. Depth keeps autoplay's outer repaint intact.
        vm.chain.addObserver { [weak driver] _, _ in driver?.beginRepaint() }
        vm.setupChainObserver()
        vm.chain.addObserver { [weak driver] _, _ in driver?.endRepaint() }
        manager.overrideDriver(driver)
        defer { manager.overrideDriver(previousDriver) }
        if launchpad != nil {
            // Overriding the driver gave the recording driver MidiManager's send listener; the MK2
            // driver it replaced sends through that one now.
            previousDriver.sendSignalListener = driver.sendSignalListener
            driver.forward = previousDriver
            // The setup's own messages, and the redraw the app makes for a new connection, must arrive
            // before autoplay starts the clock.
            try await Task.sleep(for: .milliseconds(1500))
        }

        let handover = HandoverRecorder(clock: clock, giveUpAtMs: giveUpAtMs, next: LedListenerAdapter(viewModel: vm))
        self.handover = handover
        let ledRunner = LedRunner(unipack: pack, listener: handover, chain: vm.chain)
        vm.ledRunner = ledRunner
        ledRunner.launch()

        let listener = AutoPlayStandIn(vm: vm, clock: clock, driver: driver)
        autoPlayListener = listener
        let autoPlay = AutoPlayRunner(unipack: pack, listener: listener, chain: vm.chain)
        defer {
            autoPlay.stop()
            vm.cleanup()
        }
        autoPlay.launch()

        let endBy = Date().addingTimeInterval(Double(giveUpAtMs) / 1000 + 60)
        while !listener.ended {
            guard Date() < endBy else { throw LedPathRunError("autoplay did not end") }
            try await Task.sleep(for: .milliseconds(10))
        }

        try await sleep(untilMs: Double(releaseAllAtMs))
        driver.repainting { vm.padInit() }
        while (clock.now() ?? 0) < Double(giveUpAtMs) && animating(ledRunner) {
            try await Task.sleep(for: .milliseconds(20))
        }
        ledRunner.stop()
        // Drain batches accepted before the cutoff. HandoverRecorder rejects later ticks even if
        // this task resumes late, but accepted batches still reach the real main-actor adapter.
        try await Task.sleep(for: .milliseconds(50))
        // MIDI sends leave by way of the main actor and MidiManager's send queue.
        if launchpad != nil { try await Task.sleep(for: .milliseconds(500)) }
        let departed = clock.started.flatMap { start in launchpad?.arrivals(since: start) }
        guard manager.driver === driver else {
            throw LedPathRunError("MidiManager replaced the recording driver during the run (a MIDI device connected or left)")
        }

        return LedPathRecording(
            handedOver: handover.commands,
            toDriver: driver.sent,
            pressTimes: listener.presses,
            repaints: driver.repaints,
            covered: driver.covered,
            toMidi: driver.toMidi.map(\.command),
            toMidiRepaints: driver.toMidi.map(\.repaint),
            departed: departed
        )
    }

    private func animating(_ ledRunner: LedRunner) -> Bool {
        (0..<pack.buttonX).contains { x in (0..<pack.buttonY).contains { y in ledRunner.isEventExist(x: x, y: y) } }
    }

    private func sleep(untilMs ms: Double) async throws {
        let wait = ms - (clock.now() ?? 0)
        if wait > 0 { try await Task.sleep(for: .milliseconds(wait)) }
    }
}

private struct LedPathRunError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Records what the play screen asks the Launchpad driver to send.
@MainActor
private final class RecordingDriver: BaseMidiDriver {
    private let clock: LedRunClock
    private let channels: ChannelManager
    private var repaintDepth = 0
    private var inRepaint: Bool { repaintDepth > 0 }
    /// The driver the commands also go to, when the run sends MIDI.
    var forward: MidiDriver?
    private(set) var sent: [LedCommand] = []
    private(set) var toMidi: [(command: LedCommand, repaint: Bool)] = []
    private(set) var repaints = 0
    private(set) var covered = 0

    init(clock: LedRunClock, channels: ChannelManager) {
        self.clock = clock
        self.channels = channels
    }

    override func sendPadLed(x: Int, y: Int, velocity: Int) {
        record(LedTarget(x: x, y: y), velocity)
        forward?.sendPadLed(x: x, y: y, velocity: velocity)
    }

    override func sendFunctionKeyLed(f: Int, velocity: Int) {
        record(LedTarget(x: -1, y: f), velocity)
        forward?.sendFunctionKeyLed(f: f, velocity: velocity)
    }
    override func sendChainLed(c: Int, velocity: Int) {}
    override func sendClearLed() {}

    /// Commands sent inside `body` redraw the screen's state rather than carry an LED runner change.
    func repainting(_ body: () -> Void) {
        beginRepaint()
        defer { endRepaint() }
        body()
    }

    func beginRepaint() { repaintDepth += 1 }
    func endRepaint() { repaintDepth -= 1 }

    private func record(_ target: LedTarget, _ code: Int) {
        guard let at = clock.now() else { return }
        if forward != nil, VirtualLaunchpad.addresses(target) {
            let byte = Int(BaseMidiDriver.midiDataByte(code))
            toMidi.append((LedCommand(ms: at, target: target, code: byte), inRepaint))
        }
        if inRepaint {
            repaints += 1
            return
        }
        var ledCode = code
        if let channel = channels.get(x: target.x, y: target.y)?.channel, channel != .led {
            covered += 1
            ledCode = channels.get(x: target.x, y: target.y, channel: .led)?.code ?? 0
        }
        sent.append(LedCommand(ms: at, target: target, code: ledCode))
    }
}

/// The play screen's LED listener, recording each tick's changes before passing them on.
nonisolated private final class HandoverRecorder: LedRunner.Listener, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: LedRunClock
    private let next: LedRunner.Listener
    private let giveUpAtMs: Int64
    private var recorded: [LedCommand] = []

    init(clock: LedRunClock, giveUpAtMs: Int64, next: LedRunner.Listener) {
        self.clock = clock
        self.giveUpAtMs = giveUpAtMs
        self.next = next
    }

    var commands: [LedCommand] { lock.withLock { recorded } }

    func onLedBatch(_ events: [LedRunner.LedEvent]) {
        // The intended timeline ends here too. Do not pass shutdown or late ticks on as pack LEDs.
        guard let at = clock.now(), at < Double(giveUpAtMs) else { return }
        lock.withLock {
            for event in events {
                switch event {
                case .padOn(let x, let y, _, let velocity): recorded.append(LedCommand(ms: at, target: LedTarget(x: x, y: y), code: velocity))
                case .padOff(let x, let y): recorded.append(LedCommand(ms: at, target: LedTarget(x: x, y: y), code: 0))
                case .chainOn(let c, _, let velocity): recorded.append(LedCommand(ms: at, target: LedTarget(x: -1, y: c), code: velocity))
                case .chainOff(let c): recorded.append(LedCommand(ms: at, target: LedTarget(x: -1, y: c), code: 0))
                }
            }
        }
        next.onLedBatch(events)
    }
}

/// The calls PlayViewModel's autoplay adapter makes for presses, releases and chain changes.
@MainActor
private final class AutoPlayStandIn: AutoPlayRunner.Listener {
    private let vm: PlayViewModel
    private let clock: LedRunClock
    private let driver: RecordingDriver
    private(set) var presses: [Double] = []
    private(set) var ended = false

    init(vm: PlayViewModel, clock: LedRunClock, driver: RecordingDriver) {
        self.vm = vm
        self.clock = clock
        self.driver = driver
    }

    func onStart() { clock.begin() }

    func onPadTouchOn(x: Int, y: Int) {
        presses.append(clock.now() ?? 0)
        driver.repainting { vm.padTouch(x: x, y: y, isDown: true, trigger: .autoplay) }
    }

    func onPadTouchOff(x: Int, y: Int) {
        driver.repainting { vm.padTouch(x: x, y: y, isDown: false, trigger: .autoplay) }
    }

    func onChainChange(c: Int) {
        driver.repainting { vm.chain.setValue(c) }
    }

    func onEnd() { ended = true }
    func onGuidePadOn(x: Int, y: Int, targetWallTimeMs: Int64) {}
    func onGuidePadOff(x: Int, y: Int) {}
    func onGuideLedUpdate(x: Int, y: Int, velocity: Int) {}
    func onGuideChainOn(c: Int) {}
    func onRemoveGuide() {}
    func chainButsRefresh() {}
    func onProgressUpdate(progress: Int) {}
}
