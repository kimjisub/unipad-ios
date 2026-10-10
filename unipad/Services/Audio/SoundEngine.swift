import AVFoundation
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "SoundEngine")

/// Threads: the session, the engine's start and stop, and attaching or detaching its nodes belong
/// to `worker` (see AudioSessionWorker); the main thread never waits for them. Pads schedule and play
/// nodes on the main thread, and only while `gate` says the engine runs, which it never says while a
/// recovery of ours is still on the worker. Finite repeats are scheduled on FiniteRepeatScheduler's
/// queue.
final class SoundEngine {
    // Android's native mixer has 64 voices regardless of the pack; a pool sized to the sound
    // count gave a 5-sound pack 5 voices and the 6th overlapping note cut the first.
    static let maxStreams = 64

    private let engine = AVAudioEngine()
    private let worker = AudioSessionWorker()
    // Written by the loader on a utility queue while soundOn reads and destroy() clears it on the
    // main thread; the unguarded dictionary rehashed under the reader.
    private let buffersLock = NSLock()
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private var destroyed = false
    /// False until the worker has configured the session and started the engine, and for good when
    /// that failed.
    private var isUsable = false
    private var observerTokens: [NSObjectProtocol] = []
    private var playerNodes: [AVAudioPlayerNode] = []
    private var nextPlayerIndex = 0
    private let playerCount: Int
    // Per node: whether it holds an infinite loop, and when it was started (for stealing order).
    private var nodeIsLoop: [Bool] = []
    private var nodeStartOrder: [Int] = []
    private var startCounter = 0

    // stopID[chain][x][y] tracks a unique play ID (like Android's stream ID) for stopping
    private var stopID: [[[Int]]]
    // Maps each node index to its current play ID (0 = no active play)
    private var nodePlayID: [Int]
    private var nextPlayID = 1

    private enum Input: Hashable {
        case identified(UUID)
        // MIDI and autoplay have paired pad events, without a touch identity.
        case pad(Int, Int)
    }
    private struct StartedPlayback {
        let playID: Int
        let isInfinite: Bool
    }
    private var inputPlayback: [Input: StartedPlayback] = [:]

    private func input(x: Int, y: Int, id: UUID?) -> Input {
        id.map(Input.identified) ?? .pad(x, y)
    }

    private let unipack: UniPack
    private let chain: ChainObserver
    private var loadingListener: LoadingListener?
    /// Decides whether the engine is really rendering, so a pad never starts a node on an engine that
    /// is only nominally running. See AudioSessionGate.
    private let gate: AudioSessionGate

    /// True while an interruption or a failed restart is swallowing pads.
    var isPlaybackSuppressed: Bool { gate.isPlaybackSuppressed }

    enum Interruption: Equatable {
        /// `whileInterrupted`: the session had not been ours again since an earlier interruption began.
        case began(whileInterrupted: Bool)
        /// `shouldResume`: the system allows playback to resume and the session is ours again.
        case ended(shouldResume: Bool)
    }
    /// Told after the engine has handled an interruption, so the screen can pause what it drives.
    var onInterruption: ((Interruption) -> Void)?
    /// How many pads have reached `play()`. A test seam, and the counter a suppressed pad leaves alone.
    private(set) var playsStarted = 0
    /// Test observations for finite-loop completion and stale callback cancellation.
    private let repeatScheduler = FiniteRepeatScheduler()
    var repeatedBuffersScheduled: Int { repeatScheduler.buffersScheduled }
    var activeVoiceCount: Int { nodePlayID.filter { $0 != 0 }.count }
    var activePlayIDs: Set<Int> { Set(nodePlayID.filter { $0 != 0 }) }

    /// Tests can deliver real finite-completion callbacks at corpus checkpoints, independently
    /// of how long the simulator stalls the main queue. Normal playback leaves this nil.
    var playbackCompletionDelivery: ((Int, String?, @escaping () -> Void) -> Void)?
    /// Takes the session back when playback recovers. A test seam: a simulator always hands the
    /// session back, so tests replace this to make it refuse as another app holding it would.
    var activateSessionForRecovery: () throws -> Void {
        get { gate.hooks.activateSession }
        set { gate.hooks.activateSession = newValue }
    }

    protocol LoadingListener: AnyObject {
        func onStart(soundCount: Int)
        func onProgressTick()
        func onEnd()
        func onException(_ error: Error)
    }

    init(
        unipack: UniPack,
        chain: ChainObserver,
        loadingListener: LoadingListener
    ) {
        self.unipack = unipack
        self.chain = chain
        self.loadingListener = loadingListener

        // The hooks capture the engine and the worker, never self: the gate is owned by this object
        // and must not keep it alive.
        let engine = self.engine
        let worker = self.worker
        self.gate = AudioSessionGate(hooks: AudioSessionGate.Hooks(
            isEngineRunning: { engine.isRunning },
            activateSession: { try Self.configureSession() },
            startEngine: { try engine.start() },
            runOffMain: { worker.run($0, then: $1) }
        ))

        let table = unipack.soundTable
        var soundCount = 0
        if let table {
            for i in 0..<unipack.chain {
                for j in 0..<unipack.buttonX {
                    for k in 0..<unipack.buttonY {
                        soundCount += table[i][j][k]?.count ?? 0
                    }
                }
            }
        }

        logger.info("SoundEngine init: soundCount=\(soundCount), chain=\(unipack.chain), buttonX=\(unipack.buttonX), buttonY=\(unipack.buttonY)")

        playerCount = Self.maxStreams
        stopID = Array(
            repeating: Array(
                repeating: Array(repeating: 0, count: unipack.buttonY),
                count: unipack.buttonX
            ),
            count: unipack.chain
        )
        nodePlayID = Array(repeating: 0, count: playerCount)
        nodeIsLoop = Array(repeating: false, count: playerCount)
        nodeStartOrder = Array(repeating: 0, count: playerCount)
        playerNodes = (0..<playerCount).map { _ in AVAudioPlayerNode() }

        let nodes = playerNodes
        worker.run({ Self.setUp(engine, nodes: nodes) }, then: { [weak self] result in
            self?.finishSetUp(result, table: table, soundCount: soundCount)
        })
    }

    /// Runs on the worker. Configures the session before reading the engine's format, so the nodes
    /// are connected at the session's sample rate.
    nonisolated private static func setUp(_ engine: AVAudioEngine, nodes: [AVAudioPlayerNode]) -> Result<AVAudioFormat, Error> {
        do {
            try configureSession()
            logger.info("AVAudioSession configured for playback")
        } catch {
            logger.error("Failed to configure AVAudioSession: \(error.localizedDescription)")
            return .failure(error)
        }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        logger.info("Playback format: sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
        for node in nodes {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        engine.prepare()
        do {
            try engine.start()
            logger.info("AVAudioEngine started successfully with \(nodes.count) player nodes")
        } catch {
            logger.error("Failed to start AVAudioEngine: \(error.localizedDescription)")
            return .failure(error)
        }
        return .success(format)
    }

    private func finishSetUp(_ result: Result<AVAudioFormat, Error>, table: [[[Deque<Sound>?]]]?, soundCount: Int) {
        guard !isDestroyed() else { return }
        let playbackFormat: AVAudioFormat
        switch result {
        case .success(let format):
            playbackFormat = format
        case .failure(let error):
            loadingListener?.onException(error)
            return
        }
        isUsable = true

        #if canImport(UIKit)
        // Block observers are not removed automatically; one leaked per opened pack before.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        })
        // The audio server can die and take the session configuration with it; every node is stale
        // afterwards, so playback stays suppressed until the session and the engine come back.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMediaServicesReset()
        })
        #endif
        // A route change (headphones at 44.1 kHz, unplug) stops the engine; scheduling on a node of
        // a stopped engine raised an uncatchable Objective-C exception on the next pad.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.gate.configurationChanged()
        })

        loadingListener?.onStart(soundCount: soundCount)
        load(table, as: playbackFormat)
    }

    private func load(_ table: [[[Deque<Sound>?]]]?, as playbackFormat: AVAudioFormat) {
        let unipack = self.unipack
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let table else {
                DispatchQueue.main.async { [weak self] in
                    self?.loadingListener?.onEnd()
                }
                return
            }
            // One failing file (an .ogg AVAudioFile cannot open, a 0-byte wav) used to abort the
            // whole load and kick the user out of the pack; Android's SoundPool skips it.
            var loaded = 0
            var firstError: Error?
            // One decoded buffer per file, shared by every pad that maps it (Android and web decode
            // per file); decoding per keySound line multiplied load time and memory on packs that
            // reuse a sample.
            var byFile: [URL: AVAudioPCMBuffer] = [:]
            outer: for i in 0..<unipack.chain {
                for j in 0..<unipack.buttonX {
                    for k in 0..<unipack.buttonY {
                        guard let sounds = table[i][j][k] else { continue }
                        for sound in sounds {
                            if self.isDestroyed() { break outer }
                            do {
                                let playBuffer: AVAudioPCMBuffer
                                if let cached = byFile[sound.file] {
                                    playBuffer = cached
                                } else {
                                    let rawBuffer = try Self.loadAudioBuffer(from: sound.file)
                                    playBuffer = try Self.convertIfNeeded(rawBuffer, to: playbackFormat)
                                    byFile[sound.file] = playBuffer
                                }
                                self.buffersLock.lock()
                                if !self.destroyed { self.buffers[sound.id] = playBuffer }
                                self.buffersLock.unlock()
                                loaded += 1
                            } catch {
                                logger.error("sound load failed: \(sound.file.lastPathComponent): \(error.localizedDescription)")
                                if firstError == nil { firstError = error }
                            }
                            DispatchQueue.main.async { [weak self] in
                                self?.loadingListener?.onProgressTick()
                            }
                        }
                    }
                }
            }
            if self.isDestroyed() { return }
            if loaded == 0, let firstError {
                DispatchQueue.main.async { [weak self] in
                    self?.loadingListener?.onException(firstError)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.loadingListener?.onEnd()
                }
            }
        }
    }

    private func isDestroyed() -> Bool {
        buffersLock.lock()
        defer { buffersLock.unlock() }
        return destroyed
    }

    private func buffer(for id: Int) -> AVAudioPCMBuffer? {
        buffersLock.lock()
        defer { buffersLock.unlock() }
        return buffers[id]
    }

    private static func loadAudioBuffer(from url: URL) throws -> AVAudioPCMBuffer {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SoundEngineError.bufferCreationFailed
        }
        try audioFile.read(into: buffer)
        return buffer
    }

    private static func convertIfNeeded(_ input: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if input.format.sampleRate == targetFormat.sampleRate &&
            input.format.channelCount == targetFormat.channelCount &&
            input.format.commonFormat == targetFormat.commonFormat &&
            input.format.isInterleaved == targetFormat.isInterleaved {
            return input
        }

        guard let converter = AVAudioConverter(from: input.format, to: targetFormat) else {
            throw SoundEngineError.converterCreationFailed
        }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let outCapacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw SoundEngineError.bufferCreationFailed
        }

        var consumed = false
        var convertError: NSError?
        let status = converter.convert(to: output, error: &convertError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            } else {
                consumed = true
                outStatus.pointee = .haveData
                return input
            }
        }

        if let convertError {
            throw convertError
        }

        guard status == .haveData || status == .endOfStream else {
            throw SoundEngineError.conversionFailed
        }
        return output
    }

    /// An idle node first; otherwise the oldest one-shot, never an infinite loop while a one-shot
    /// exists (Android AudioEngine's stealing policy). Plain round-robin killed the backing track
    /// after `playerCount` further pad hits.
    private func acquirePlayerNode() -> (AVAudioPlayerNode, Int) {
        var index: Int
        if let idle = nodePlayID.firstIndex(of: 0) {
            index = idle
        } else {
            var victim: Int? = nil
            for i in 0..<playerCount where !nodeIsLoop[i] {
                if victim == nil || nodeStartOrder[i] < nodeStartOrder[victim!] { victim = i }
            }
            if victim == nil {
                victim = (0..<playerCount).min { nodeStartOrder[$0] < nodeStartOrder[$1] }
            }
            index = victim ?? 0
        }
        let node = playerNodes[index]
        repeatScheduler.stop(node)
        nodePlayID[index] = 0
        return (node, index)
    }

    private func stopByPlayID(_ playID: Int) {
        guard playID > 0 else { return }
        if let idx = nodePlayID.firstIndex(of: playID) {
            repeatScheduler.stop(playerNodes[idx])
            nodePlayID[idx] = 0
        }
    }

    #if canImport(UIKit)
    /// Applies the category and the low-latency preferences and activates the session. Idempotent on
    /// purpose: recovery runs it again, and after a media services reset the configuration is gone.
    nonisolated private static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
    }
    #else
    nonisolated private static func configureSession() throws {}
    #endif

    #if canImport(UIKit)
    /// Internal rather than private so the tests can drive an interruption, which a simulator cannot
    /// raise on its own.
    func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .ended:
            let optionsValue = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            // Resuming autoplay on a session we could not take back would run it without sound.
            gate.interruptionEnded(shouldResume: shouldResume) { [weak self] recovery in
                self?.onInterruption?(.ended(shouldResume: recovery == .recovered))
            }
        default:
            // `.began`, and any type a later SDK adds: suppressing is the safe side.
            let whileInterrupted = gate.state == .interrupted
            gate.interruptionBegan()
            releaseAllVoices()
            onInterruption?(.began(whileInterrupted: whileInterrupted))
        }
    }

    func handleMediaServicesReset() {
        releaseAllVoices()
        gate.mediaServicesWereReset()
    }
    #endif

    /// The app is in front again. A call that was answered may never send the end of its
    /// interruption, so this is where the session is taken back in that case.
    func appBecameActive() {
        gate.appBecameActive()
    }

    /// Drops every voice. After an interruption or a media services reset the nodes still carry play
    /// IDs for audio that stopped rendering, and the stealing order would keep honouring them.
    private func releaseAllVoices() {
        inputPlayback.removeAll()
        let nodes = playerNodes
        _ = runCatchingObjCException {
            for node in nodes { repeatScheduler.stop(node) }
        }
        for i in nodePlayID.indices {
            nodePlayID[i] = 0
            nodeIsLoop[i] = false
        }
    }

    func soundOn(x: Int, y: Int, inputID: UUID? = nil) {
        let input = input(x: x, y: y, id: inputID)
        inputPlayback.removeValue(forKey: input)
        guard isUsable else { return }
        let c = chain.value
        guard stopID.indices.contains(c), stopID[c].indices.contains(x), stopID[c][x].indices.contains(y) else { return }
        // An engine that is not rendering makes play() raise "player did not see an IO cycle", which
        // Swift cannot catch. When the gate cannot get it running, the pad is silent instead.
        guard gate.ensureEngineRunning() else { return }

        // Stop previous sound on this pad (using unique play ID, like Android's stream ID)
        stopByPlayID(stopID[c][x][y])

        guard let sound = unipack.soundGet(c: c, x: x, y: y) else {
            logger.debug("soundOn(\(x),\(y)): no sound for chain=\(c)")
            return
        }
        guard let buffer = buffer(for: sound.id) else {
            logger.warning("soundOn(\(x),\(y)): buffer not loaded for sound id=\(sound.id)")
            return
        }

        let (node, nodeIndex) = acquirePlayerNode()
        let playID = nextPlayID
        nextPlayID += 1
        stopID[c][x][y] = playID
        nodePlayID[nodeIndex] = playID
        nodeIsLoop[nodeIndex] = sound.loop == -1
        startCounter += 1
        nodeStartOrder[nodeIndex] = startCounter
        // Frees the node for reuse when a one-shot finishes, so stealing only happens when every
        // node is really busy.
        let release: (String?) -> Void = { [weak self] failure in
            DispatchQueue.main.async {
                guard let self else { return }
                let complete = { [weak self] in
                    guard let self, self.nodePlayID.indices.contains(nodeIndex), self.nodePlayID[nodeIndex] == playID else { return }
                    self.nodePlayID[nodeIndex] = 0
                    if let failure { self.gate.playbackFailed(reason: failure) }
                }
                if let delivery = self.playbackCompletionDelivery {
                    delivery(playID, failure, complete)
                    return
                }
                complete()
            }
        }

        // The gate closes the window it can see, but the session can go away between that check and
        // these calls, and AVAudioEngine.isRunning keeps reading true when it does. AVFoundation
        // raises ("player did not see an IO cycle") rather than throwing, and Swift cannot catch it,
        // so scheduling and play() run inside the Objective-C catcher: what is left of the race costs
        // one silent pad instead of the process.
        var repeatFailure: String?
        let failure = runCatchingObjCException {
            if node.engine == nil {
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            }

            // Android SoundPool.play(loop=N) plays N+1 times total (1 initial + N repeats)
            if sound.loop == -1 {
                node.scheduleBuffer(buffer, at: nil, options: .loops)
            } else if sound.loop > 0 {
                repeatFailure = repeatScheduler.start(buffer, node: node, totalPlays: sound.loop + 1, completion: release)
            } else {
                node.scheduleBuffer(buffer, at: nil, options: []) { release(nil) }
            }
            if sound.loop <= 0 { node.play() }
        }
        if let failure = failure ?? repeatFailure {
            logger.error("play() raised: \(failure, privacy: .public)")
            repeatScheduler.stop(node)
            nodePlayID[nodeIndex] = 0
            stopID[c][x][y] = 0
            gate.playbackFailed(reason: failure)
            return
        }
        playsStarted += 1
        inputPlayback[input] = StartedPlayback(playID: playID, isInfinite: sound.loop == -1)

        unipack.soundPush(c: c, x: x, y: y)

        if sound.wormhole != Sound.noWormhole {
            let wormhole = sound.wormhole
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                chain.setValue(wormhole)
            }
        }
    }

    func soundOff(x: Int, y: Int, inputID: UUID? = nil) {
        // Consume once. Neither a new chain nor the next sound in a pad's sequence can
        // change which voice this input started; a stolen/finished play ID is harmless.
        guard let started = inputPlayback.removeValue(forKey: input(x: x, y: y, id: inputID)),
              started.isInfinite else { return }
        stopByPlayID(started.playID)
    }

    func destroy() {
        inputPlayback.removeAll()
        // Terminal: a notification that lands after this must not restart the engine we just stopped.
        gate.shutDown()
        for i in nodePlayID.indices { nodePlayID[i] = 0 }
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        for node in playerNodes { repeatScheduler.stop(node) }
        // After any set-up or recovery still on the worker, so nothing starts the engine again.
        let engine = self.engine
        let nodes = playerNodes
        worker.run {
            engine.stop()
            for node in nodes where node.engine != nil {
                engine.detach(node)
            }
        }
        playerNodes.removeAll()
        buffersLock.lock()
        destroyed = true
        buffers.removeAll()
        buffersLock.unlock()
    }

    enum SoundEngineError: Error {
        case bufferCreationFailed
        case converterCreationFailed
        case conversionFailed
    }
}

/// AVFoundation completion handlers only enqueue work and return. The serial queue owns finite
/// repeat scheduling and stopping, so stop() cannot wait for a callback that waits for our queue.
/// A bounded lookahead shares the decoded buffer; even an enormous loop count cannot flood memory
/// or hold the screen while all repeats are scheduled. Supply does not depend on the main actor.
/// `voices`, `scheduled` and each voice's `remaining` are only touched on `queue`.
nonisolated final class FiniteRepeatScheduler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "UniPad.finiteRepeats", qos: .userInteractive)
    private var voices: [ObjectIdentifier: Voice] = [:]
    private var scheduled = 0
    var buffersScheduled: Int { queue.sync { scheduled } }

    private final class Voice: @unchecked Sendable {
        let node: AVAudioPlayerNode
        let buffer: AVAudioPCMBuffer
        var remaining: Int
        let completion: (String?) -> Void

        init(node: AVAudioPlayerNode, buffer: AVAudioPCMBuffer, totalPlays: Int, completion: @escaping (String?) -> Void) {
            self.node = node
            self.buffer = buffer
            remaining = totalPlays
            self.completion = completion
        }
    }

    func start(_ buffer: AVAudioPCMBuffer, node: AVAudioPlayerNode, totalPlays: Int, completion: @escaping (String?) -> Void) -> String? {
        queue.sync {
            let voice = Voice(node: node, buffer: buffer, totalPlays: totalPlays, completion: completion)
            let key = ObjectIdentifier(node)
            voices[key] = voice
            let seconds = Double(max(1, buffer.frameLength)) / buffer.format.sampleRate
            let lookahead = min(128, max(2, Int(ceil(0.1 / seconds))))
            let failure = runCatchingObjCException {
                for _ in 0..<min(totalPlays, lookahead) { schedule(voice) }
                node.play()
            }
            if failure != nil { voices.removeValue(forKey: key) }
            return failure
        }
    }

    func stop(_ node: AVAudioPlayerNode) {
        queue.sync {
            // Invalidate before stop triggers completion handlers. Already enqueued handlers also
            // check identity, so they cannot schedule or release a replacement voice on this node.
            voices.removeValue(forKey: ObjectIdentifier(node))
            _ = runCatchingObjCException { node.stop() }
        }
    }

    private func schedule(_ voice: Voice) {
        voice.remaining -= 1
        let final = voice.remaining == 0
        scheduled += 1
        voice.node.scheduleBuffer(voice.buffer, at: nil, options: [], completionCallbackType: final ? .dataPlayedBack : .dataConsumed) { [weak self, weak voice] _ in
            self?.queue.async { [weak self, weak voice] in
                guard let self, let voice else { return }
                let key = ObjectIdentifier(voice.node)
                guard self.voices[key] === voice else { return }
                if final {
                    self.voices.removeValue(forKey: key)
                    voice.completion(nil)
                } else if voice.remaining > 0 {
                    if let failure = runCatchingObjCException({ self.schedule(voice) }) {
                        self.voices.removeValue(forKey: key)
                        _ = runCatchingObjCException { voice.node.stop() }
                        voice.completion(failure)
                    }
                }
            }
        }
    }
}
