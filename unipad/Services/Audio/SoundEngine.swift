import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "SoundEngine")

final class SoundEngine {
    // Android's native mixer has 64 voices regardless of the pack; a pool sized to the sound
    // count gave a 5-sound pack 5 voices and the 6th overlapping note cut the first.
    static let maxStreams = 64

    private let engine = AVAudioEngine()
    // Written by the loader on a utility queue while soundOn reads and destroy() clears it on the
    // main thread; the unguarded dictionary rehashed under the reader.
    private let buffersLock = NSLock()
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private var destroyed = false
    /// false when the audio session could not be configured: the tables below are empty then.
    private let isUsable: Bool
    private var observerTokens: [NSObjectProtocol] = []
    private let playbackFormat: AVAudioFormat
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

    private let unipack: UniPack
    private let chain: ChainObserver
    private var loadingListener: LoadingListener?
    /// Decides whether the engine is really rendering, so a pad never starts a node on an engine that
    /// is only nominally running. See AudioSessionGate.
    private let gate: AudioSessionGate

    /// True while an interruption or a failed restart is swallowing pads.
    var isPlaybackSuppressed: Bool { gate.isPlaybackSuppressed }
    /// How many pads have reached `play()`. A test seam, and the counter a suppressed pad leaves alone.
    private(set) var playsStarted = 0

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

        // The hooks capture the engine, never self: the gate is owned by this object and must not
        // keep it alive.
        let engine = self.engine
        self.gate = AudioSessionGate(hooks: AudioSessionGate.Hooks(
            isEngineRunning: { engine.isRunning },
            activateSession: { try Self.configureSession() },
            startEngine: { try engine.start() }
        ))

        // Configure AVAudioSession BEFORE reading engine format
        #if canImport(UIKit)
        do {
            try Self.configureSession()
            logger.info("AVAudioSession configured for playback")
        } catch {
            logger.error("Failed to configure AVAudioSession: \(error.localizedDescription)")
            self.playbackFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            self.playerCount = 1
            self.stopID = []
            self.nodePlayID = []
            self.isUsable = false
            loadingListener.onException(error)
            return
        }
        #endif

        self.isUsable = true
        self.playbackFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        logger.info("Playback format: sampleRate=\(self.playbackFormat.sampleRate), channels=\(self.playbackFormat.channelCount)")

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

        for _ in 0..<playerCount {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: playbackFormat)
            playerNodes.append(node)
        }

        engine.prepare()
        do {
            try engine.start()
            logger.info("AVAudioEngine started successfully with \(self.playerCount) player nodes")
        } catch {
            logger.error("Failed to start AVAudioEngine: \(error.localizedDescription)")
            loadingListener.onException(error)
            return
        }

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

        loadingListener.onStart(soundCount: soundCount)

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
                                    playBuffer = try Self.convertIfNeeded(rawBuffer, to: self.playbackFormat)
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
        node.stop()
        nodePlayID[index] = 0
        return (node, index)
    }

    private func stopByPlayID(_ playID: Int) {
        guard playID > 0 else { return }
        if let idx = nodePlayID.firstIndex(of: playID) {
            playerNodes[idx].stop()
            nodePlayID[idx] = 0
        }
    }

    #if canImport(UIKit)
    /// Applies the category and the low-latency preferences and activates the session. Idempotent on
    /// purpose: recovery runs it again, and after a media services reset the configuration is gone.
    private static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
    }
    #else
    private static func configureSession() throws {}
    #endif

    #if canImport(UIKit)
    /// Internal rather than private so the tests can drive an interruption, which a simulator cannot
    /// raise on its own.
    func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            gate.interruptionBegan()
            releaseAllVoices()
        case .ended:
            let optionsValue = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            gate.interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            gate.interruptionBegan()
            releaseAllVoices()
        }
    }

    func handleMediaServicesReset() {
        releaseAllVoices()
        gate.mediaServicesWereReset()
    }
    #endif

    /// Drops every voice. After an interruption or a media services reset the nodes still carry play
    /// IDs for audio that stopped rendering, and the stealing order would keep honouring them.
    private func releaseAllVoices() {
        let nodes = playerNodes
        _ = runCatchingObjCException {
            for node in nodes { node.stop() }
        }
        for i in nodePlayID.indices {
            nodePlayID[i] = 0
            nodeIsLoop[i] = false
        }
    }

    func soundOn(x: Int, y: Int) {
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
        let release: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.nodePlayID.indices.contains(nodeIndex), self.nodePlayID[nodeIndex] == playID else { return }
                self.nodePlayID[nodeIndex] = 0
            }
        }

        // The gate closes the window it can see, but the session can go away between that check and
        // these calls, and AVAudioEngine.isRunning keeps reading true when it does. AVFoundation
        // raises ("player did not see an IO cycle") rather than throwing, and Swift cannot catch it,
        // so scheduling and play() run inside the Objective-C catcher: what is left of the race costs
        // one silent pad instead of the process.
        let failure = runCatchingObjCException {
            if node.engine == nil {
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            }

            // Android SoundPool.play(loop=N) plays N+1 times total (1 initial + N repeats)
            if sound.loop == -1 {
                node.scheduleBuffer(buffer, at: nil, options: .loops)
            } else if sound.loop > 0 {
                func scheduleRemaining(_ remaining: Int) {
                    guard remaining > 0 else { release(); return }
                    node.scheduleBuffer(buffer, at: nil, options: []) { [weak node] in
                        guard let node, node.isPlaying else { return }
                        scheduleRemaining(remaining - 1)
                    }
                }
                node.scheduleBuffer(buffer, at: nil, options: []) { [weak node] in
                    guard let node, node.isPlaying else { return }
                    scheduleRemaining(sound.loop)
                }
            } else {
                node.scheduleBuffer(buffer, at: nil, options: []) { release() }
            }
            node.play()
        }
        if let failure {
            logger.error("play() raised: \(failure, privacy: .public)")
            _ = runCatchingObjCException { node.stop() }
            nodePlayID[nodeIndex] = 0
            stopID[c][x][y] = 0
            gate.playbackFailed(reason: failure)
            return
        }
        playsStarted += 1

        unipack.soundPush(c: c, x: x, y: y)

        if sound.wormhole != Sound.noWormhole {
            let wormhole = sound.wormhole
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                chain.setValue(wormhole)
            }
        }
    }

    func soundOff(x: Int, y: Int) {
        guard isUsable else { return }
        let c = chain.value
        guard stopID.indices.contains(c), stopID[c].indices.contains(x), stopID[c][x].indices.contains(y) else { return }
        guard let sound = unipack.soundGet(c: c, x: x, y: y) else { return }
        if sound.loop == -1 {
            stopByPlayID(stopID[c][x][y])
        }
    }

    func destroy() {
        // Terminal: a notification that lands after this must not restart the engine we just stopped.
        gate.shutDown()
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        engine.stop()
        for node in playerNodes {
            node.stop()
            engine.detach(node)
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
