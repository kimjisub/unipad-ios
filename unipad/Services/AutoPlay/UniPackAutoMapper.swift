import Foundation
import AVFoundation

protocol UniPackAutoMapperListener: AnyObject {
    func onStart()
    func onGetWorkSize(_ size: Int)
    func onProgress(_ progress: Int)
    func onDone()
    func onException(_ error: Error)
}

/// Rewrites a pack's autoPlay so each pad press waits for its sound to finish.
///
/// The pack is read on the main actor, where the screen reads it too; reading sound lengths and
/// writing the file run off it, so a big pack does not freeze the screen. Cancelling (the screen
/// is left) stops the work at the next press and before anything is written.
final class UniPackAutoMapper {
    private let unipack: UniPackFolder
    private weak var listener: UniPackAutoMapperListener?
    private let replacer: AutoPlayFileReplacer
    private var task: Task<Void, Never>?

    init(unipack: UniPackFolder, listener: UniPackAutoMapperListener, replacer: AutoPlayFileReplacer = AutoPlayFileReplacer()) {
        self.unipack = unipack
        self.listener = listener
        self.replacer = replacer
    }

    /// The task keeps the mapper alive until the mapping ends or is cancelled.
    @discardableResult
    func start() -> Task<Void, Never> {
        let task = Task { await run() }
        self.task = task
        return task
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Private

    private nonisolated enum Step: Sendable {
        case chain(Int)
        case delay(Int)
        case press(x: Int, y: Int, sound: URL?)
    }

    private func run() async {
        listener?.onStart()
        do {
            guard let elements = unipack.autoPlayTable?.elements, let autoPlayFile = unipack.autoPlayFile else {
                throw AutoMapperError.noAutoPlay
            }
            let steps = steps(of: elements)
            listener?.onGetWorkSize(steps.count(where: { if case .press = $0 { return true }; return false }))

            try await Self.remap(steps, into: autoPlayFile, replacer: replacer) { progress in
                self.listener?.onProgress(progress)
            }
            // autoPlayTable is read by the view model on the main actor, so it is swapped here.
            unipack.reloadAutoPlay()
            listener?.onDone()
        } catch is CancellationError {
        } catch {
            listener?.onException(error)
        }
    }

    private func steps(of elements: [AutoPlay.Element]) -> [Step] {
        elements.compactMap { element -> Step? in
            switch element {
            case .chain(let c): .chain(c)
            case .delay(let d): .delay(d)
            case .on(let x, let y, let chain, let num): .press(x: x, y: y, sound: unipack.soundGet(c: chain, x: x, y: y, num: num)?.file)
            case .off: nil
            }
        }
    }

    @concurrent private static func remap(
        _ steps: [Step],
        into autoPlayFile: URL,
        replacer: AutoPlayFileReplacer,
        progress: @escaping @Sendable @MainActor (Int) -> Void
    ) async throws {
        var result: [String] = []
        var pendingDelay = 0
        var pressed = 0

        for step in steps {
            try Task.checkCancellation()

            switch step {
            case .chain(let c):
                result.append("c \(c + 1)")

            case .delay(let d):
                pendingDelay += d

            case .press(let x, let y, let sound):
                result += delayLines(pendingDelay)
                pendingDelay = 0

                let duration = sound.flatMap { try? audioDurationMs(url: $0) } ?? 0
                result.append("t \(x + 1) \(y + 1)")
                result += delayLines(duration)

                pressed += 1
                await progress(pressed)
            }
        }

        result += delayLines(pendingDelay)

        try Task.checkCancellation()
        try replacer.replace(autoPlayFile, with: result.joined(separator: "\n") + "\n")
    }

    /// The pack reader takes a delay only up to Int32.max, so a longer wait is written as several
    /// `d` lines adding up to it. A wait of 0 or less writes nothing.
    private nonisolated static func delayLines(_ milliseconds: Int) -> [String] {
        let longest = Int(Int32.max)
        return stride(from: 0, to: milliseconds, by: longest).map { "d \(min(longest, milliseconds - $0))" }
    }

    /// Use the same source limits as playback, so a skipped sound adds no wait.
    private nonisolated static func audioDurationMs(url: URL) throws -> Int {
        let (length, format) = try soundLength(url)
        let sampleRate = format.sampleRate
        let frameCount = try SoundFileLimits.sourceFrameCount(
            length, sampleRate: sampleRate, channels: format.channelCount)
        return Int(Double(frameCount) / sampleRate * 1000)
    }

    /// Playback opens Ogg Vorbis, which `AVAudioFile` cannot, with its own decoder; its length
    /// comes from the stream without decoding the audio.
    private nonisolated static func soundLength(_ url: URL) throws -> (frames: AVAudioFramePosition, format: AVAudioFormat) {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            return (audioFile.length, audioFile.processingFormat)
        } catch _ where OggVorbisDecoder.isOgg(url) {
            return try OggVorbisDecoder.length(of: url)
        }
    }
}

/// Replaces an autoPlay file, keeping the old one next to it as `autoPlay_<time>`. A failed
/// write leaves the folder as it was: the atomic write keeps the original, and the backup goes.
nonisolated struct AutoPlayFileReplacer: Sendable {
    var write: @Sendable (String, URL) throws -> Void = { try $0.write(to: $1, atomically: true, encoding: .utf8) }

    func replace(_ autoPlayFile: URL, with content: String) throws {
        guard FileManager.default.fileExists(atPath: autoPlayFile.path) else {
            throw AutoMapperError.noAutoPlay
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy_MM_dd-HH_mm_ss"
        let backupURL = autoPlayFile.deletingLastPathComponent()
            .appendingPathComponent("autoPlay_\(formatter.string(from: Date()))")

        try FileManager.default.copyItem(at: autoPlayFile, to: backupURL)
        do {
            try write(content, autoPlayFile)
        } catch {
            try? FileManager.default.removeItem(at: backupURL)
            throw error
        }
    }
}

nonisolated enum AutoMapperError: LocalizedError {
    case noAutoPlay

    var errorDescription: String? {
        switch self {
        case .noAutoPlay: return String(localized: "remapFail")
        }
    }
}
