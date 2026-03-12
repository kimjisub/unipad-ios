import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "SoundEngine")

final class SoundEngine {
    static let maxStreams = 30

    private let engine = AVAudioEngine()
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private let playbackFormat: AVAudioFormat
    private var playerNodes: [AVAudioPlayerNode] = []
    private var nextPlayerIndex = 0
    private let playerCount: Int

    // stopID[chain][x][y] tracks a unique play ID (like Android's stream ID) for stopping
    private var stopID: [[[Int]]]
    // Maps each node index to its current play ID (0 = no active play)
    private var nodePlayID: [Int]
    private var nextPlayID = 1

    private let unipack: UniPack
    private let chain: ChainObserver
    private var loadingListener: LoadingListener?

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

        // Configure AVAudioSession BEFORE reading engine format
        #if canImport(UIKit)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
            logger.info("AVAudioSession configured for playback")
        } catch {
            logger.error("Failed to configure AVAudioSession: \(error.localizedDescription)")
            self.playbackFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            self.playerCount = 1
            self.stopID = []
            self.nodePlayID = []
            loadingListener.onException(error)
            return
        }
        #endif

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

        playerCount = min(max(soundCount, 1), Self.maxStreams)
        stopID = Array(
            repeating: Array(
                repeating: Array(repeating: 0, count: unipack.buttonY),
                count: unipack.buttonX
            ),
            count: unipack.chain
        )
        nodePlayID = Array(repeating: 0, count: playerCount)

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
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        #endif

        loadingListener.onStart(soundCount: soundCount)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                guard let table else {
                    DispatchQueue.main.async { [weak self] in
                        self?.loadingListener?.onEnd()
                    }
                    return
                }
                for i in 0..<unipack.chain {
                    for j in 0..<unipack.buttonX {
                        for k in 0..<unipack.buttonY {
                            guard let sounds = table[i][j][k] else { continue }
                            for sound in sounds {
                                let rawBuffer = try Self.loadAudioBuffer(from: sound.file)
                                let playBuffer = try Self.convertIfNeeded(rawBuffer, to: self.playbackFormat)
                                self.buffers[sound.id] = playBuffer
                                DispatchQueue.main.async { [weak self] in
                                    self?.loadingListener?.onProgressTick()
                                }
                            }
                        }
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.loadingListener?.onEnd()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.loadingListener?.onException(error)
                }
            }
        }
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

    private func acquirePlayerNode() -> (AVAudioPlayerNode, Int) {
        let index = nextPlayerIndex % playerCount
        nextPlayerIndex += 1
        let node = playerNodes[index]
        node.stop()
        return (node, index)
    }

    private func stopByPlayID(_ playID: Int) {
        guard playID > 0 else { return }
        if let idx = nodePlayID.firstIndex(of: playID) {
            playerNodes[idx].stop()
            nodePlayID[idx] = 0
        }
    }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            logger.info("AVAudioEngine restarted")
        } catch {
            logger.error("Failed to restart AVAudioEngine: \(error.localizedDescription)")
        }
    }

    #if canImport(UIKit)
    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        if type == .ended {
            let optionsValue = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                ensureEngineRunning()
            }
        }
    }
    #endif

    func soundOn(x: Int, y: Int) {
        let c = chain.value
        ensureEngineRunning()

        // Stop previous sound on this pad (using unique play ID, like Android's stream ID)
        stopByPlayID(stopID[c][x][y])

        guard let sound = unipack.soundGet(c: c, x: x, y: y) else {
            logger.debug("soundOn(\(x),\(y)): no sound for chain=\(c)")
            return
        }
        guard let buffer = buffers[sound.id] else {
            logger.warning("soundOn(\(x),\(y)): buffer not loaded for sound id=\(sound.id)")
            return
        }

        let (node, nodeIndex) = acquirePlayerNode()
        let playID = nextPlayID
        nextPlayID += 1
        stopID[c][x][y] = playID
        nodePlayID[nodeIndex] = playID

        if node.engine == nil {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        }

        // Android SoundPool.play(loop=N) plays N+1 times total (1 initial + N repeats)
        if sound.loop == -1 {
            node.scheduleBuffer(buffer, at: nil, options: .loops)
        } else if sound.loop > 0 {
            func scheduleRemaining(_ remaining: Int) {
                guard remaining > 0 else { return }
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
            node.scheduleBuffer(buffer, at: nil, options: [])
        }
        node.play()

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
        let c = chain.value
        guard let sound = unipack.soundGet(c: c, x: x, y: y) else { return }
        if sound.loop == -1 {
            stopByPlayID(stopID[c][x][y])
        }
    }

    func destroy() {
        engine.stop()
        for node in playerNodes {
            node.stop()
            engine.detach(node)
        }
        playerNodes.removeAll()
        buffers.removeAll()
    }

    enum SoundEngineError: Error {
        case bufferCreationFailed
        case converterCreationFailed
        case conversionFailed
    }
}
