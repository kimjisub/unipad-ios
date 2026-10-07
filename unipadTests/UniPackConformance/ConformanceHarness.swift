import Foundation
@testable import unipad

/// What a platform did with a case, or why it could not be observed here.
enum ConformanceActual {
    case value(JSONValue)
    case unverified(String)
}

/// The calls under test. The self-checks replace one of them to prove a case fails without it.
struct ConformanceDeps {
    var load: (URL) -> UniPack = { root in
        let pack = UniPackFolder(rootFolder: root)
        pack.load()
        if !pack.criticalError { pack.loadDetailWithProgress { _, _, _ in } }
        return pack
    }
    var ledEventOn: @MainActor (LedRunner, Int, Int) -> Void = { runner, x, y in runner.eventOn(x: x, y: y) }
}

enum ConformanceHarness {
    // MARK: - Normalization

    static func hex8(_ color: Int) -> String {
        String(format: "%08x", UInt32(truncatingIfNeeded: color))
    }

    /// "keySound : [..] format is incorrect" -> "keySound:format".
    static func normalizeError(_ message: String) -> String {
        let section: String
        if let match = message.range(of: #"^[A-Za-z.]+"#, options: .regularExpression) {
            section = String(message[match])
        } else {
            section = "unknown"
        }
        func has(_ pattern: String) -> Bool { message.range(of: pattern, options: .regularExpression) != nil }
        let kind: String
        if has(#"format is (incorrect|not found)"#) { kind = "format" }
        else if has(#"\b(chain|x|y|loop|coordinate|delay) is incorrect\b|out of range"#) { kind = "range" }
        else if has(#"was not found|directory not found|doesn't exist"#) { kind = "missing-file" }
        else if has(#"was missing"#) { kind = "missing-field" }
        else { kind = "other(\(message))" }
        return "\(section):\(kind)"
    }

    private static func soundName(_ file: URL, root: URL) -> String {
        let base = root.resolvingSymlinksInPath().appendingPathComponent("sounds").path + "/"
        let path = file.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : file.lastPathComponent
    }

    static func parseResult(_ pack: UniPack, root: URL) -> JSONValue {
        if pack.criticalError { return ["loaded": false] }

        var info: [String: JSONValue] = [
            "title": .string(pack.title), "producerName": .string(pack.producerName),
            "buttonX": .int(pack.buttonX), "buttonY": .int(pack.buttonY), "chain": .int(pack.chain),
            "squareButton": .bool(pack.squareButton),
        ]
        if let website = pack.website, !website.isEmpty { info["website"] = .string(website) }

        var sounds: [JSONValue] = []
        var leds: [JSONValue] = []
        for c in 0..<pack.chain {
            for x in 0..<pack.buttonX {
                for y in 0..<pack.buttonY {
                    if let queue = pack.soundTable?[c][x][y], !queue.isEmpty {
                        sounds.append(["c": .int(c), "x": .int(x), "y": .int(y), "queue": .array(queue.map { sound in
                            ["file": .string(soundName(sound.file, root: root)), "loop": .int(sound.loop), "wormhole": .int(sound.wormhole)]
                        })])
                    }
                    if let queue = pack.ledAnimationTable?[c][x][y], !queue.isEmpty {
                        leds.append(["c": .int(c), "x": .int(x), "y": .int(y), "queue": .array(queue.map { animation in
                            ["loop": .int(animation.loop), "events": .array(animation.ledEvents.map(ledEvent))]
                        })])
                    }
                }
            }
        }

        var autoPlay: JSONValue = .null
        if let table = pack.autoPlayTable {
            autoPlay = .array(table.elements.map { element in
                switch element {
                case .on(let x, let y, let chain, let num): return ["on", .int(x), .int(y), .int(chain), .int(num)]
                case .off(let x, let y, let chain): return ["off", .int(x), .int(y), .int(chain)]
                case .chain(let c): return ["chain", .int(c)]
                case .delay(let delay): return ["delay", .int(delay)]
                }
            })
        }

        let errors = (pack.errorDetail?.split(separator: "\n").map(String.init) ?? []).map(normalizeError)
        return [
            "loaded": true, "info": .object(info), "sounds": .array(sounds), "keyLedExist": .bool(pack.keyLedExist),
            "leds": .array(leds), "autoPlay": autoPlay, "errors": .array(errors.map(JSONValue.string)),
        ]
    }

    private static func ledEvent(_ event: LedAnimation.LedEvent) -> JSONValue {
        switch event {
        case .on(let x, let y, let color, let velocity): return ["on", .int(x), .int(y), .string(hex8(color)), .int(velocity)]
        case .off(let x, let y): return ["off", .int(x), .int(y)]
        case .delay(let delay): return ["delay", .int(delay)]
        case .chain(let chain): return ["chain", .int(chain)]
        }
    }

    // MARK: - Running a case

    @MainActor
    static func actual(for conformanceCase: ConformanceCase, corpus: ConformanceCorpus, deps: ConformanceDeps = ConformanceDeps()) async throws -> ConformanceActual {
        if conformanceCase.layer == "palette" {
            return .value(["argb": .array(LaunchpadColor.argb.map { .string(hex8(Int($0))) })])
        }
        if let reason = conformanceCase.unobserved[ConformanceCorpus.platform] { return .unverified(reason) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unipad-conformance-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(conformanceCase.id, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write(conformanceCase.files, to: root, corpus: corpus)

        let pack = deps.load(root)
        guard conformanceCase.layer == "run", !pack.criticalError else {
            return .value(conformanceCase.layer == "run" ? ["loaded": false] : parseResult(pack, root: root))
        }
        return try await runScenario(conformanceCase, pack: pack, root: root, deps: deps)
    }

    private static func write(_ files: [ConformanceFile], to root: URL, corpus: ConformanceCorpus) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let target = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try corpus.bytes(of: file).write(to: target)
        }
    }

    /// The runners' output in the order it happened; the LED loop, the chain observer and the
    /// listeners run on different threads.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [JSONValue] = []
        var recordsChain = true

        func add(_ event: JSONValue) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func drain() -> [JSONValue] {
            lock.lock()
            defer { lock.unlock() }
            defer { events = [] }
            return events
        }
    }

    private final class LedRecorder: LedRunner.Listener {
        let log: EventLog
        init(log: EventLog) { self.log = log }

        func onLedBatch(_ events: [LedRunner.LedEvent]) {
            for event in events {
                switch event {
                case .padOn(let x, let y, let color, let velocity): log.add(["ledOn", .int(x), .int(y), .string(hex8(color)), .int(velocity)])
                case .padOff(let x, let y): log.add(["ledOff", .int(x), .int(y)])
                case .chainOn(let c, let color, let velocity): log.add(["ledOn", -1, .int(c), .string(hex8(color)), .int(velocity)])
                case .chainOff(let c): log.add(["ledOff", -1, .int(c)])
                }
            }
        }
    }

    private final class LoadListener: SoundEngine.LoadingListener {
        private(set) var finished = false
        private(set) var failure: Error?
        func onStart(soundCount: Int) {}
        func onProgressTick() {}
        func onEnd() { finished = true }
        func onException(_ error: Error) {
            failure = error
            finished = true
        }
    }

    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now: Int64 = 1000
        private var reads = 0

        func read() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            return now
        }

        var wasRead: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reads > 0
        }

        func advance(_ ms: Int64) {
            lock.lock()
            now += ms
            lock.unlock()
        }
    }

    /// How long a scenario's sounds are given to end before the engine is destroyed. destroy() called
    /// while a repeated sound (keySound loop above 1) is still cycling does not return in the simulator:
    /// AVAudioPlayerNode.stop() and the completion handler SoundEngine.soundOn schedules wait for each
    /// other. The corpus sounds last 10 ms and repeat at most twice, so this outlasts them; it keeps the
    /// hang out of the cases, it does not fix it. Input, stacks and retries: unipad.io
    /// meta/unipack-conformance/RESULTS.md, "iOS: destroy() while a repeated sound is cycling", and
    /// `destroyWhileARepeatedSoundIsCycling` in the tests.
    static let soundSettleNanoseconds: UInt64 = 300_000_000

    /// The sound engine is the real AVAudioEngine-backed one: it has no seam to observe which sound it
    /// started, so a started sound is the queue head the engine reads (`soundGet`) at a press that
    /// bumped `playsStarted`, and the queue rotation and wormhole switch are the engine's own.
    @MainActor
    private static func runScenario(_ conformanceCase: ConformanceCase, pack: UniPack, root: URL, deps: ConformanceDeps) async throws -> ConformanceActual {
        let log = EventLog()
        let chain = ChainObserver()
        chain.range = 0...max(pack.chain - 1, 0)
        chain.addObserver { current, _ in
            if log.recordsChain { log.add(["chain", .int(current)]) }
        }

        let clock = ManualClock()
        // LedRunner keeps its listener weakly, so the recorder must be held here.
        let recorder = LedRecorder(log: log)
        let led = LedRunner(unipack: pack, listener: recorder, chain: chain, loopDelay: 3600, clock: { clock.read() })
        led.launch()
        let deadline = Date().addingTimeInterval(5)
        while !clock.wasRead {
            guard Date() < deadline else { throw ConformanceError.harness("the LED loop task never ran its first tick") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let loading = LoadListener()
        let engine = SoundEngine(unipack: pack, chain: chain, loadingListener: loading)
        var engineDestroyed = false
        /// Leaves the scenario: the LED loop is cancelled and the engine destroyed once its sounds ended.
        func shutDown() async {
            led.stop()
            guard !engineDestroyed else { return }
            engineDestroyed = true
            try? await Task.sleep(nanoseconds: soundSettleNanoseconds)
            engine.destroy()
        }

        func play() async throws -> ConformanceActual {
            let loadDeadline = Date().addingTimeInterval(20)
            while !loading.finished, Date() < loadDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
            if let failure = loading.failure { return .unverified("the audio engine is not usable here: \(failure.localizedDescription)") }
            guard loading.finished else { throw ConformanceError.harness("sounds did not finish loading within 20 s") }

            let hasWormhole = (0..<pack.chain).contains { c in
                (0..<pack.buttonX).contains { x in (0..<pack.buttonY).contains { y in pack.soundTable?[c][x][y]?.contains { $0.wormhole != Sound.noWormhole } == true } }
            }

            var checkpoints: [JSONValue] = []
            for step in conformanceCase.scenario {
                let x = step["x"]?.int ?? 0
                let y = step["y"]?.int ?? 0
                switch step["do"]?.string {
                case "press":
                    let playing = chain.value
                    let head = pack.soundGet(c: playing, x: x, y: y)
                    let before = engine.playsStarted
                    engine.soundOn(x: x, y: y)
                    if engine.playsStarted > before, let head {
                        log.add(["sound", .int(playing), .int(x), .int(y), .string(soundName(head.file, root: root)), .int(head.loop)])
                    }
                    deps.ledEventOn(led, x, y)
                case "release":
                    engine.soundOff(x: x, y: y)
                    led.eventOff(x: x, y: y)
                case "chain":
                    log.recordsChain = false
                    chain.setValue(step["c"]?.int ?? 0)
                    log.recordsChain = true
                case "advance":
                    let total = step["ms"]?.int ?? 0
                    if hasWormhole { try await Task.sleep(nanoseconds: UInt64(total) * 1_000_000) }
                    var remaining = total
                    while remaining > 0 {
                        let tick = min(4, remaining)
                        clock.advance(Int64(tick))
                        if led.active { led.loop() }
                        await Task.yield()
                        await Task.yield()
                        remaining -= tick
                    }
                case "observe":
                    await Task.yield()
                    checkpoints.append(.array(log.drain()))
                case "stop":
                    await shutDown()
                default:
                    throw ConformanceError.harness("\(conformanceCase.id): unknown scenario step \(step["do"]?.string ?? "?")")
                }
            }
            return .value(["checkpoints": .array(checkpoints)])
        }

        let result: Result<ConformanceActual, Error>
        do { result = .success(try await play()) } catch { result = .failure(error) }
        await shutDown()
        return try withExtendedLifetime(recorder) { try result.get() }
    }

    // MARK: - Reproduction aid

    /// Ends the process when it is not disarmed in time. A main thread stuck inside destroy() cannot
    /// fail a test, so without this a reproduced hang would be a run that never ends.
    private final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = true

        init(seconds: Double, message: String) {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                lock.lock()
                let stuck = armed
                lock.unlock()
                if stuck { fatalError(message) }
            }
        }

        func disarm() {
            lock.lock()
            armed = false
            lock.unlock()
        }
    }

    /// Presses pad (0, 0) of a pack whose keySound is `keySound`, destroys the engine `delayNanoseconds`
    /// later and returns how many milliseconds destroy() took; nil when no sound started.
    @MainActor
    static func destroyDuration(keySound: String, delayNanoseconds: UInt64, corpus: ConformanceCorpus, limitSeconds: Double = 20) async throws -> Double? {
        guard let template = corpus.cases.first(where: { $0.id == "KS-001" }) else { throw ConformanceError.harness("KS-001 is not in the corpus") }
        let files = template.files.map { $0.path == "keySound" ? ConformanceFile(path: $0.path, text: keySound, base64: nil, asset: nil) : $0 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unipad-conformance-destroy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try write(files, to: root, corpus: corpus)

        let pack = ConformanceDeps().load(root)
        let chain = ChainObserver()
        chain.range = 0...max(pack.chain - 1, 0)
        let loading = LoadListener()
        let engine = SoundEngine(unipack: pack, chain: chain, loadingListener: loading)
        let loadDeadline = Date().addingTimeInterval(20)
        while !loading.finished, Date() < loadDeadline { try await Task.sleep(nanoseconds: 10_000_000) }

        let before = engine.playsStarted
        if loading.finished, loading.failure == nil { engine.soundOn(x: 0, y: 0) }
        let started = engine.playsStarted > before
        if started { try await Task.sleep(nanoseconds: delayNanoseconds) }

        let watchdog = Watchdog(seconds: limitSeconds, message: "UNIPACK-CONFORMANCE-REPRO-DESTROY destroy() did not return within \(limitSeconds) s (keySound \(keySound), \(delayNanoseconds / 1_000_000) ms after the press)")
        let start = DispatchTime.now().uptimeNanoseconds
        engine.destroy()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        watchdog.disarm()
        return started ? elapsed : nil
    }

    enum ConformanceError: Error, CustomStringConvertible {
        case harness(String)
        var description: String {
            switch self { case .harness(let reason): return reason }
        }
    }
}
