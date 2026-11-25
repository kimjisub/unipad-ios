import Foundation
import AVFoundation

protocol UniPackAutoMapperListener: AnyObject {
    func onStart()
    func onGetWorkSize(_ size: Int)
    func onProgress(_ progress: Int)
    func onDone()
    func onException(_ error: Error)
}

/// The length of a sound in milliseconds, or nil when it cannot be read.
typealias SoundLengthReader = @Sendable (URL) -> Double?

/// Rewrites a pack's autoPlay so each wait between presses lasts as long as the sound pressed
/// before it.
///
/// The pack is read on the main actor, where the screen reads it too; reading sound lengths and
/// writing the file run off it, so a big pack does not freeze the screen. Cancelling (the screen
/// is left) stops the work at the next press and before anything is written.
final class UniPackAutoMapper {
    private let unipack: UniPackFolder
    private weak var listener: UniPackAutoMapperListener?
    private let replacer: AutoPlayFileReplacer
    private let soundLength: SoundLengthReader
    private var task: Task<Void, Never>?

    init(
        unipack: UniPackFolder,
        listener: UniPackAutoMapperListener,
        replacer: AutoPlayFileReplacer = AutoPlayFileReplacer(),
        soundLength: @escaping SoundLengthReader = UniPackAutoMapper.playableLengthMs
    ) {
        self.unipack = unipack
        self.listener = listener
        self.replacer = replacer
        self.soundLength = soundLength
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
        case delay(Int, preservingSwitches: Bool)
        case press(x: Int, y: Int, sound: URL?)
    }

    private func run() async {
        listener?.onStart()
        do {
            guard let autoPlay = unipack.autoPlayTable, let autoPlayFile = unipack.autoPlayFile else {
                throw AutoMapperError.noAutoPlay
            }
            // Keep waits before pending sound switches so rereading the rewritten file selects
            // the same page and queue. Derived switches must not become explicit chain commands.
            let steps = steps(of: autoPlay.sourceElements ?? autoPlay.elements)
            listener?.onGetWorkSize(steps.count(where: { if case .press = $0 { return true }; return false }))

            try await Self.remap(steps, into: autoPlayFile, replacer: replacer, soundLength: soundLength) { progress in
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
        var result: [Step] = []
        var songTime: Int64 = 0
        // Keeping time through the last pending move also keeps every earlier move in place.
        var pendingUntil: Int64?
        for element in elements {
            if let deadline = pendingUntil, deadline <= songTime { pendingUntil = nil }
            switch element {
            case .chain(let c):
                pendingUntil = nil
                result.append(.chain(c))
            case .delay(let d):
                let end = songTime + Int64(d)
                if let deadline = pendingUntil {
                    let keptEnd = min(deadline, end)
                    if keptEnd > songTime {
                        result.append(.delay(Int(keptEnd - songTime), preservingSwitches: true))
                        songTime = keptEnd
                    }
                    if deadline <= end { pendingUntil = nil }
                }
                if songTime != end || d == 0 {
                    result.append(.delay(Int(end - songTime), preservingSwitches: pendingUntil != nil))
                }
                songTime = end
            case .on(let x, let y, let chain, let num):
                let sound = unipack.soundGet(c: chain, x: x, y: y, num: num)
                result.append(.press(x: x, y: y, sound: sound?.file))
                if let sound, sound.wormhole != Sound.noWormhole {
                    pendingUntil = max(pendingUntil ?? songTime, songTime + 100)
                }
            case .off: break
            }
        }
        return result
    }

    @concurrent private static func remap(
        _ steps: [Step],
        into autoPlayFile: URL,
        replacer: AutoPlayFileReplacer,
        soundLength: SoundLengthReader,
        progress: @escaping @Sendable @MainActor (Int) -> Void
    ) async throws {
        var writer = AutoPlayWriter()
        var pressed = 0

        for step in steps {
            try Task.checkCancellation()

            switch step {
            case .chain(let c):
                writer.chain(c)

            case .delay(let d, let preservingSwitches):
                writer.wait(d, preservingSwitches: preservingSwitches)

            case .press(let x, let y, let sound):
                writer.press(x: x, y: y, lengthMs: sound.flatMap(soundLength).flatMap(wholeMilliseconds))
                pressed += 1
                await progress(pressed)
            }
        }

        try Task.checkCancellation()
        try replacer.replace(autoPlayFile, with: writer.finished())
    }

    /// An exact half rounds up. A length that is not a real length counts as unknown.
    private nonisolated static func wholeMilliseconds(_ milliseconds: Double) -> Int? {
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < Double(Int.max) else { return nil }
        return Int(milliseconds.rounded(.toNearestOrAwayFromZero))
    }

    /// Use the same source limits as playback, so a sound playback skips has no length.
    nonisolated static let playableLengthMs: SoundLengthReader = { url in
        guard let (length, format) = try? soundLength(url),
              let frameCount = try? SoundFileLimits.sourceFrameCount(length, sampleRate: format.sampleRate, channels: format.channelCount)
        else { return nil }
        return Double(frameCount) * 1000 / format.sampleRate
    }

    /// Playback opens Ogg Vorbis and Opus on systems without native support; their length
    /// comes from the stream without decoding the audio.
    private nonisolated static func soundLength(_ url: URL) throws -> (frames: AVAudioFramePosition, format: AVAudioFormat) {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            return (audioFile.length, audioFile.processingFormat)
        } catch _ where OggVorbisDecoder.isOgg(url) {
            return try OggAudioDecoder.length(of: url)
        }
    }
}

/// Builds the mapped autoPlay text from the pack's commands in order.
///
/// Everything between two presses is held until the next press shows there is one: a wait after
/// the last press is dropped. Those waits count as one, replaced by the length of the sound pressed
/// before them and written where the first of them stood, so a chain change after it still moves
/// at the end of the wait. When that length is unknown the waits stay as they were, each on its
/// side of any chain change. The first press is always preceded by `firstWaitMs`, after any chain
/// change that comes before it. Presses with no wait between them stay at the same time.
/// Waits while sound switches are pending keep their original length. Only the remainder after
/// those switches can be replaced, subtracting the time already kept since the previous press.
nonisolated struct AutoPlayWriter {
    static let firstWaitMs = 1000

    private enum Held {
        case chain(Int)
        case wait(Int, preservingSwitches: Bool)
    }

    private var lines: [String] = []
    private var held: [Held] = []
    private var pressed = false
    private var lastLengthMs: Int?
    mutating func chain(_ c: Int) {
        held.append(.chain(c))
    }

    mutating func wait(_ milliseconds: Int, preservingSwitches: Bool = false) {
        held.append(.wait(milliseconds, preservingSwitches: preservingSwitches))
    }

    mutating func press(x: Int, y: Int, lengthMs: Int?) {
        lines += pressed ? heldLinesBeforePress() : leadIn()
        held = []
        lines.append("t \(x + 1) \(y + 1)")
        pressed = true
        lastLengthMs = lengthMs
    }

    func finished() -> String {
        let trailingChains = held.compactMap { item -> String? in
            if case .chain(let c) = item { return Self.chainLine(c) }
            return nil
        }
        return (lines + trailingChains).map { $0 + "\n" }.joined()
    }

    private func leadIn() -> [String] {
        held.compactMap { item -> String? in
            if case .chain(let c) = item { return Self.chainLine(c) }
            return nil
        } + Self.delayLines(Self.firstWaitMs)
    }

    private func heldLinesBeforePress() -> [String] {
        var result: [String] = []
        var waitOfThisStretch: Int?
        var replaced = false
        var keptSincePress = 0
        func flushWait() {
            if let waitOfThisStretch { result += Self.delayLines(waitOfThisStretch) }
            waitOfThisStretch = nil
        }
        for item in held {
            switch item {
            case .chain(let c):
                flushWait()
                result.append(Self.chainLine(c))
            case .wait(let milliseconds, let preservingSwitches):
                if preservingSwitches {
                    flushWait()
                    result += Self.delayLines(milliseconds)
                    keptSincePress += milliseconds
                } else if let lastLengthMs {
                    if !replaced { result += Self.delayLines(max(0, lastLengthMs - keptSincePress)) }
                    replaced = true
                } else {
                    waitOfThisStretch = (waitOfThisStretch ?? 0) + milliseconds
                }
            }
        }
        flushWait()
        return result
    }

    private static func chainLine(_ c: Int) -> String { "c \(c + 1)" }

    /// The pack reader takes a delay only up to Int32.max, so a longer wait is written as several
    /// `d` lines adding up to it. A wait of 0 or less writes nothing.
    private static func delayLines(_ milliseconds: Int) -> [String] {
        let longest = Int(Int32.max)
        return stride(from: 0, to: milliseconds, by: longest).map { "d \(min(longest, milliseconds - $0))" }
    }
}

/// Keeps a pack's autoPlay and its single previous version next to it as `<name>_previous`, the
/// name the other apps use, and changes the two in one step: at every moment the file a press plays
/// from is whole, and it is either the old version or the new one.
///
/// A new version is flushed to disk beside them and moved into the backup's place, then the two
/// names swap, which is the single step that replaces the autoPlay and makes the old one the backup.
/// Restoring is that swap alone, so it needs no disk space and can be repeated. A failure puts the
/// backup back; an app killed before the swap keeps the autoPlay, with the new version as the backup.
nonisolated struct AutoPlayFileReplacer: Sendable {
    var write: @Sendable (String, URL) throws -> Void = { content, url in
        let created = FileManager.default.createFile(atPath: url.path, contents: nil)
        guard created else { throw CocoaError(.fileWriteUnknown) }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.write(contentsOf: Data(content.utf8))
        // Not every file system takes the full flush; those that refuse it still take a plain one.
        if fcntl(file.fileDescriptor, F_FULLFSYNC) != 0 { try file.synchronize() }
    }
    var exchange: @Sendable (URL, URL) throws -> Void = swapNames

    static let swapNames: @Sendable (URL, URL) throws -> Void = { first, second in
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func backupFile(of autoPlayFile: URL) -> URL {
        autoPlayFile.deletingLastPathComponent().appendingPathComponent(autoPlayFile.lastPathComponent + "_previous")
    }

    private static func stagedFile(of autoPlayFile: URL) -> URL {
        autoPlayFile.deletingLastPathComponent().appendingPathComponent(".\(autoPlayFile.lastPathComponent).next")
    }

    static func hasBackup(of autoPlayFile: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: backupFile(of: autoPlayFile).path, isDirectory: &isFolder) && !isFolder.boolValue
    }

    func replace(_ autoPlayFile: URL, with content: String) throws {
        guard FileManager.default.fileExists(atPath: autoPlayFile.path) else {
            throw AutoMapperError.noAutoPlay
        }
        let backup = Self.backupFile(of: autoPlayFile)
        let staged = Self.stagedFile(of: autoPlayFile)
        defer { try? FileManager.default.removeItem(at: staged) }
        try write(content, staged)

        let hadBackup = Self.hasBackup(of: autoPlayFile)
        if hadBackup {
            try exchange(staged, backup)
        } else {
            try FileManager.default.moveItem(at: staged, to: backup)
        }
        do {
            try exchange(autoPlayFile, backup)
        } catch {
            if hadBackup {
                try? exchange(staged, backup)
            } else {
                try? FileManager.default.removeItem(at: backup)
            }
            throw error
        }
    }

    /// Swaps the autoPlay and its backup, so restoring again brings back what was just replaced.
    func restore(_ autoPlayFile: URL) throws {
        try exchange(autoPlayFile, Self.backupFile(of: autoPlayFile))
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
