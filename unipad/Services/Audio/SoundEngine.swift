import AVFoundation
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

nonisolated private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "SoundEngine")

/// Threads: the session, the engine's start and stop, and attaching or detaching its nodes belong
/// to `AudioSessionWorker.shared`; the main thread never waits for them. One worker serves every
/// engine, so a closed pack's engine has stopped before the next pack configures the session. Pads
/// schedule and play nodes on the main thread, and only while `gate` says the engine runs, which it
/// never says while a recovery of ours is still on the worker. Finite repeats are scheduled on
/// FiniteRepeatScheduler's queue.
///
/// Stopping nodes is the exception: an interruption, a media services reset and `destroy()` stop
/// them from the main thread (through FiniteRepeatScheduler) while the worker may be starting the
/// engine. A player node's `stop()` does not need a rendering engine, and every stop runs inside
/// the Objective-C catcher, so a stop that races a start costs nothing but that voice.
final class SoundEngine {
    // Android's native mixer has 64 voices regardless of the pack; a pool sized to the sound
    // count gave a 5-sound pack 5 voices and the 6th overlapping note cut the first.
    static let maxStreams = 64

    private let engine = AVAudioEngine()
    private let worker = AudioSessionWorker.shared
    // Written by the loader on a utility queue while soundOn reads and destroy() clears it on the
    // main thread; the unguarded dictionary rehashed under the reader.
    private let buffersLock = NSLock()
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private var destroyed = false
    /// False until the worker has set the engine up, and for good when that failed. Whether the engine
    /// renders is the gate's to say.
    private var isUsable = false
    private var observerTokens: [NSObjectProtocol] = []
    private var playerNodes: [AVAudioPlayerNode] = []
    private var nextPlayerIndex = 0
    private let playerCount: Int
    // Per node: whether it holds an infinite loop, and when it was started (for stealing order).
    private var nodeIsLoop: [Bool] = []
    private var nodeStartOrder: [Int] = []
    private var startCounter = 0
    // How many times a recovery has started the engine again, and per node the count it last played
    // under. A node that ran out of buffers before the engine stopped stays silent after the restart
    // until it is stopped. Counted on the worker, read on the main thread.
    private let engineRestarts = OSAllocatedUnfairLock(initialState: 0)
    private var nodeEngineRun: [Int] = []

    // stopID[chain][x][y] tracks a unique play ID (like Android's stream ID) for stopping
    private var stopID: [[[Int]]]
    // Maps each node index to its current play ID (0 = no active play)
    private var nodePlayID: [Int]
    private var nextPlayID = 1

    private enum Input: Hashable {
        case identified(UUID)
        // MIDI has paired pad events without a touch identity.
        case pad(Int, Int)
    }
    private struct StartedPlayback {
        let playID: Int
        let isInfinite: Bool
    }
    private var inputPlayback: [Input: StartedPlayback] = [:]
    /// Wormhole chain changes still waiting out their delay, by the press that made them.
    private var pendingWormholes: [Int: Task<Void, Never>] = [:]
    private var nextWormholeID = 0

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
    /// Whether interruptions, media services resets and route changes reach the gate. A test seam.
    var isObservingSession: Bool { !observerTokens.isEmpty }

    enum Interruption: Equatable {
        /// `whileInterrupted`: the session had not been ours again since an earlier interruption began.
        case began(whileInterrupted: Bool)
        /// `shouldResume`: the system allows playback to resume. `recovered`: the session is ours again.
        /// `whileInFront`: the end came while the app was active.
        case ended(shouldResume: Bool, recovered: Bool, whileInFront: Bool)
        /// The app is in front again. `recovered`: this took back a session that was not ours.
        case appReturned(recovered: Bool)
    }
    /// Told after the engine has handled an interruption or the app's return to the front, so the
    /// screen can pause or resume what it drives.
    var onInterruption: ((Interruption) -> Void)?
    /// How many pads have reached `play()`. A test seam, and the counter a suppressed pad leaves alone.
    private(set) var playsStarted = 0
    /// Test observations for finite-loop completion and stale callback cancellation.
    private let repeatScheduler = FiniteRepeatScheduler()
    var repeatedBuffersScheduled: Int { repeatScheduler.buffersScheduled }
    var playerNodesStopped: Int { repeatScheduler.nodesStopped }
    var activeVoiceCount: Int { nodePlayID.filter { $0 != 0 }.count }
    var activePlayIDs: Set<Int> { Set(nodePlayID.filter { $0 != 0 }) }

    /// Tests can deliver real finite-completion callbacks at corpus checkpoints, independently
    /// of how long the simulator stalls the main queue. Normal playback leaves this nil.
    var playbackCompletionDelivery: ((Int, String?, @escaping () -> Void) -> Void)?
    /// Waits out the time between a sound with a wormhole and its chain change. A test seam: tests
    /// hold it open to act inside that window.
    var wormholeDelay: () async -> Void = { try? await Task.sleep(nanoseconds: 100_000_000) }
    /// Takes the session back when playback recovers. A test seam: a simulator always hands the
    /// session back, so tests replace this to make it refuse as another app holding it would.
    var activateSessionForRecovery: () throws -> Void {
        get { gate.hooks.activateSession }
        set { gate.hooks.activateSession = newValue }
    }
    #if canImport(UIKit)
    /// Whether the app is active. A test seam: the test host stays active, and an interruption can end
    /// while the app is still in the background.
    var isAppInFront: () -> Bool = { UIApplication.shared.applicationState == .active }
    #endif

    /// Optional observations let tests distinguish queue waits from decoding and callback delivery.
    nonisolated enum LoadingEvent: String {
        case setupQueued, setupStarted, setupFinished, setupDelivered
        case loadQueued, loadStarted, soundStarted, soundFinished
        case completionQueued, completionDelivered
    }
    private let packBudget: SoundFileLimits.PackBudget
    private let observeLoading: (LoadingEvent) -> Void

    protocol LoadingListener: AnyObject {
        func onStart(soundCount: Int)
        func onProgressTick()
        func onEnd()
        func onException(_ error: Error)
    }

    /// `activateSession` applies the category and activates the session, on the worker. A test seam: a
    /// simulator always grants the session, and a test makes it refuse as a call in progress would.
    init(
        unipack: UniPack,
        chain: ChainObserver,
        loadingListener: LoadingListener,
        activateSession: @escaping () throws -> Void = SoundEngine.configureSession,
        packBudget: SoundFileLimits.PackBudget = .init(),
        observeLoading: @escaping (LoadingEvent) -> Void = { _ in }
    ) {
        self.packBudget = packBudget
        self.observeLoading = observeLoading
        self.unipack = unipack
        self.chain = chain
        self.loadingListener = loadingListener

        // The hooks capture the engine and the worker, never self: the gate is owned by this object
        // and must not keep it alive.
        let engine = self.engine
        let worker = self.worker
        let engineRestarts = self.engineRestarts
        self.gate = AudioSessionGate(hooks: AudioSessionGate.Hooks(
            isEngineRunning: { engine.isRunning },
            activateSession: activateSession,
            startEngine: {
                engineRestarts.withLock { $0 += 1 }
                try engine.start()
            },
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
        nodeEngineRun = Array(repeating: 0, count: playerCount)
        playerNodes = (0..<playerCount).map { _ in AVAudioPlayerNode() }

        // Before the set-up is handed over: a call or a route change while the worker configures the
        // session must reach the gate, or it would allow pads on an engine that is not rendering.
        observeSession()

        let nodes = playerNodes
        observeLoading(.setupQueued)
        worker.run({
            observeLoading(.setupStarted)
            defer { observeLoading(.setupFinished) }
            return Self.setUp(engine, nodes: nodes, activateSession: activateSession)
        }, then: { [weak self] result in
            observeLoading(.setupDelivered)
            self?.finishSetUp(result, table: table, soundCount: soundCount)
        })
    }

    private func observeSession() {
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
    }

    nonisolated private struct SetUp {
        let format: AVAudioFormat
        /// False when another app held the session (a call in progress): the engine was not started.
        let hasSession: Bool
    }

    /// Runs on the worker. Configures the session before reading the engine's format, so the nodes
    /// are connected at the session's sample rate. A session that cannot be activated says nothing
    /// about the pack or the device: the nodes are connected anyway and the engine starts when the
    /// session is taken back, as after an interruption.
    nonisolated private static func setUp(
        _ engine: AVAudioEngine, nodes: [AVAudioPlayerNode], activateSession: () throws -> Void
    ) -> Result<SetUp, Error> {
        var hasSession = true
        do {
            try activateSession()
            logger.info("AVAudioSession configured for playback")
        } catch {
            logger.error("Failed to configure AVAudioSession: \(error.localizedDescription)")
            hasSession = false
        }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        logger.info("Playback format: sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
        for node in nodes {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        engine.prepare()
        guard hasSession else { return .success(SetUp(format: format, hasSession: false)) }
        do {
            try engine.start()
            logger.info("AVAudioEngine started successfully with \(nodes.count) player nodes")
        } catch {
            logger.error("Failed to start AVAudioEngine: \(error.localizedDescription)")
            return .failure(error)
        }
        return .success(SetUp(format: format, hasSession: true))
    }

    private func finishSetUp(_ result: Result<SetUp, Error>, table: [[[Deque<Sound>?]]]?, soundCount: Int) {
        guard !isDestroyed() else { return }
        let playbackFormat: AVAudioFormat
        switch result {
        case .success(let setUp):
            playbackFormat = setUp.format
            if !setUp.hasSession { gate.startedWithoutSession() }
        case .failure(let error):
            // Nothing will play on this engine; a later notification must not start it.
            gate.shutDown()
            loadingListener?.onException(error)
            return
        }
        isUsable = true
        loadingListener?.onStart(soundCount: soundCount)
        load(table, as: playbackFormat)
    }

    private func load(_ table: [[[Deque<Sound>?]]]?, as playbackFormat: AVAudioFormat) {
        let unipack = self.unipack
        observeLoading(.loadQueued)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.observeLoading(.loadStarted)
            guard let table else {
                self.observeLoading(.completionQueued)
                DispatchQueue.main.async { [weak self] in
                    self?.loadingListener?.onEnd()
                    self?.observeLoading(.completionDelivered)
                }
                return
            }
            // One failing file (a damaged .ogg, a 0-byte wav) used to abort the
            // whole load and kick the user out of the pack; Android's SoundPool skips it.
            var loaded = 0
            var firstError: Error?
            // One decoded buffer per file, shared by every pad that maps it (Android and web decode
            // per file); decoding per keySound line multiplied load time and memory on packs that
            // reuse a sample.
            var byFile: [URL: AVAudioPCMBuffer] = [:]
            // A file that failed fails again for every line that maps it; decoding it again could
            // cost a whole sound's memory and time each time before the same error.
            var failedFiles: [URL: Error] = [:]
            var budget = self.packBudget
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
                                } else if let failure = failedFiles[sound.file] {
                                    throw failure
                                } else {
                                    do {
                                        self.observeLoading(.soundStarted)
                                        defer { self.observeLoading(.soundFinished) }
                                        playBuffer = try Self.decode(sound.file, as: playbackFormat, within: &budget)
                                    } catch {
                                        failedFiles[sound.file] = error
                                        throw error
                                    }
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
            self.observeLoading(.completionQueued)
            if loaded == 0, let firstError {
                DispatchQueue.main.async { [weak self] in
                    self?.loadingListener?.onException(firstError)
                    self?.observeLoading(.completionDelivered)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.loadingListener?.onEnd()
                    self?.observeLoading(.completionDelivered)
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

    /// Decodes `url` in `playbackFormat`. A sound that would take the pack past `budget` is refused
    /// before each buffer for it is allocated, by the length its header claims.
    static func decode(_ url: URL, as playbackFormat: AVAudioFormat, within budget: inout SoundFileLimits.PackBudget) throws -> AVAudioPCMBuffer {
        let spent = budget
        let source = try decodeAudioBuffer(from: url) { format, frames in
            let claimed = try SoundFileLimits.resampledFrameCount(
                frames, from: format.sampleRate, to: playbackFormat.sampleRate, channels: playbackFormat.channelCount)
            try spent.check(claimed, channels: playbackFormat.channelCount)
        }
        let converted = try convertIfNeeded(source, to: playbackFormat)
        // A converted buffer is already sized by the frames the source holds.
        let playBuffer = converted === source ? try fitted(source) : converted
        // The allocated capacity, not the frames it holds, is what the buffer keeps in memory.
        try budget.spend(playBuffer.frameCapacity, channels: playBuffer.format.channelCount)
        return playBuffer
    }

    /// The decoded sound in a buffer no larger than the frames it holds. `admit` sees the format and
    /// each frame capacity before it is allocated.
    static func loadAudioBuffer(
        from url: URL,
        admitting admit: (AVAudioFormat, AVAudioFrameCount) throws -> Void = { _, _ in }
    ) throws -> AVAudioPCMBuffer {
        try fitted(decodeAudioBuffer(from: url, admitting: admit))
    }

    /// The decoded sound in a buffer sized by the length the file claims, which can be far more than
    /// it holds.
    private static func decodeAudioBuffer(
        from url: URL,
        admitting admit: (AVAudioFormat, AVAudioFrameCount) throws -> Void
    ) throws -> AVAudioPCMBuffer {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch _ where OggVorbisDecoder.isOgg(url) {
            return try OggVorbisDecoder.decode(url, admitting: admit)
        }
        let format = audioFile.processingFormat
        let frameCount = try SoundFileLimits.sourceFrameCount(
            audioFile.length, sampleRate: format.sampleRate, channels: format.channelCount)
        try admit(format, frameCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SoundEngineError.bufferCreationFailed
        }
        try audioFile.read(into: buffer)
        return buffer
    }

    /// A copy of `buffer` no larger than the frames it holds. A compressed file's header can claim far
    /// more than it holds (MP3s cut from a song can keep the whole song's length), and the buffer
    /// sized by that claim is released once the copy is made.
    private static func fitted(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard buffer.frameLength < buffer.frameCapacity else { return buffer }
        guard let fitted = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: max(buffer.frameLength, 1)) else {
            throw SoundEngineError.bufferCreationFailed
        }
        fitted.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(fitted.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            if let destination = to.mData, let origin = from.mData {
                memcpy(destination, origin, Int(min(from.mDataByteSize, to.mDataByteSize)))
            }
        }
        return fitted
    }

    private static func convertIfNeeded(_ input: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if input.format.sampleRate == targetFormat.sampleRate &&
            input.format.channelCount == targetFormat.channelCount &&
            input.format.commonFormat == targetFormat.commonFormat &&
            input.format.isInterleaved == targetFormat.isInterleaved {
            return input
        }

        let outCapacity = try SoundFileLimits.resampledFrameCount(
            input.frameLength, from: input.format.sampleRate, to: targetFormat.sampleRate, channels: targetFormat.channelCount)
        guard let converter = AVAudioConverter(from: input.format, to: targetFormat) else {
            throw SoundEngineError.converterCreationFailed
        }
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
    ///
    /// An idle node is taken as it is: it was stopped when its play ID was cleared, or it has run out
    /// of buffers, so the next buffer plays at once. Stopping it again would make every pad wait for
    /// the node on the screen's thread. Only a busy node, or an idle one from before an engine
    /// restart, is stopped.
    private func acquirePlayerNode() -> (AVAudioPlayerNode, Int) {
        let run = engineRestarts.withLock { $0 }
        let index = nodePlayID.firstIndex(of: 0) ?? oldestStealableNode()
        if nodePlayID[index] != 0 || nodeEngineRun[index] != run {
            repeatScheduler.stop(playerNodes[index])
            nodePlayID[index] = 0
        }
        nodeEngineRun[index] = run
        return (playerNodes[index], index)
    }

    private func oldestStealableNode() -> Int {
        var victim: Int? = nil
        for i in 0..<playerCount where !nodeIsLoop[i] {
            if victim == nil || nodeStartOrder[i] < nodeStartOrder[victim!] { victim = i }
        }
        if victim == nil {
            victim = (0..<playerCount).min { nodeStartOrder[$0] < nodeStartOrder[$1] }
        }
        return victim ?? 0
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
    nonisolated static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
    }
    #else
    nonisolated static func configureSession() throws {}
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
            let whileInFront = isAppInFront()
            // Resuming autoplay on a session we could not take back would run it without sound.
            gate.interruptionEnded(shouldResume: shouldResume) { [weak self] recovery in
                // A new interruption overtook this end and reports its own; or the screen is gone.
                guard recovery != .abandoned else { return }
                self?.onInterruption?(.ended(
                    shouldResume: shouldResume, recovered: recovery == .recovered, whileInFront: whileInFront))
            }
        default:
            // `.began`, and any type a later SDK adds: suppressing is the safe side.
            let whileInterrupted = gate.isInterruptionUnresolved
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
        guard gate.isPlaybackSuppressed else {
            gate.appBecameActive()
            onInterruption?(.appReturned(recovered: false))
            return
        }
        gate.appBecameActive { [weak self] recovery in
            // A new interruption overtook the return and reports its own; or the screen is gone.
            guard recovery != .abandoned else { return }
            self?.onInterruption?(.appReturned(recovered: recovery == .recovered))
        }
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
            // A sound that could not be decoded is silent where it stands; the pad still moves on
            // to its next line and the sound's wormhole still applies.
            logger.warning("soundOn(\(x),\(y)): buffer not loaded for sound id=\(sound.id)")
            advance(past: sound, c: c, x: x, y: y)
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

        advance(past: sound, c: c, x: x, y: y)
    }

    /// Moves the pad to its next keySound line and follows `sound`'s wormhole.
    private func advance(past sound: Sound, c: Int, x: Int, y: Int) {
        unipack.soundPush(c: c, x: x, y: y)

        if sound.wormhole != Sound.noWormhole {
            let wormhole = sound.wormhole
            let delay = wormholeDelay
            let id = nextWormholeID
            nextWormholeID += 1
            pendingWormholes[id] = Task { @MainActor [weak self] in
                await delay()
                guard let self, self.pendingWormholes.removeValue(forKey: id) != nil else { return }
                self.chain.setValue(wormhole)
            }
        }
    }

    /// Drops the wormhole chain changes still waiting out their delay: a chain the player picks
    /// after a press is the one that stays.
    func cancelPendingWormholes() {
        for task in pendingWormholes.values { task.cancel() }
        pendingWormholes.removeAll()
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
        cancelPendingWormholes()
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
    private var stopped = 0
    var buffersScheduled: Int { queue.sync { scheduled } }
    var nodesStopped: Int { queue.sync { stopped } }

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
            stopped += 1
            _ = runCatchingObjCException { node.stop() }
        }
    }

    private func schedule(_ voice: Voice) {
        voice.remaining -= 1
        let final = voice.remaining == 0
        scheduled += 1
        // Not .dataPlayedBack: that arms a player-node timer, and every later stop() of the node
        // (from the screen's thread when a pad takes it back) waits on a semaphore for the timer's
        // default-QoS thread.
        voice.node.scheduleBuffer(voice.buffer, at: nil, options: [], completionCallbackType: final ? .dataRendered : .dataConsumed) { [weak self, weak voice] _ in
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
