import Foundation
import AVFoundation

protocol UniPackAutoMapperListener: AnyObject {
    func onStart()
    func onGetWorkSize(_ size: Int)
    func onProgress(_ progress: Int)
    func onDone()
    func onException(_ error: Error)
}

final class UniPackAutoMapper {
    private let unipack: UniPackFolder
    private weak var listener: UniPackAutoMapperListener?
    private var task: Task<Void, Never>?

    init(unipack: UniPackFolder, listener: UniPackAutoMapperListener) {
        self.unipack = unipack
        self.listener = listener
    }

    func start() {
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await self.run()
            } catch {
                await MainActor.run { self.listener?.onException(error) }
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Private

    private func run() async throws {
        await MainActor.run { listener?.onStart() }

        guard let elements = unipack.autoPlayTable?.elements else {
            throw AutoMapperError.noAutoPlay
        }

        let workSize = elements.filter { if case .on = $0 { return true }; return false }.count
        await MainActor.run { listener?.onGetWorkSize(workSize) }

        var result: [String] = []
        var pendingDelay = 0
        var progress = 0

        for element in elements {
            try Task.checkCancellation()

            switch element {
            case .chain(let c):
                result.append("c \(c + 1)")

            case .delay(let d):
                pendingDelay += d

            case .on(let x, let y, let chain, let num):
                if pendingDelay > 0 {
                    result.append("d \(pendingDelay)")
                    pendingDelay = 0
                }

                let duration: Int
                if let sound = unipack.soundGet(c: chain, x: x, y: y, num: num) {
                    duration = (try? audioDurationMs(url: sound.file)) ?? 0
                } else {
                    duration = 0
                }

                result.append("t \(x + 1) \(y + 1)")
                if duration > 0 {
                    result.append("d \(duration)")
                }

                progress += 1
                await MainActor.run { listener?.onProgress(progress) }

            case .off:
                break
            }
        }

        if pendingDelay > 0 {
            result.append("d \(pendingDelay)")
        }

        let newContent = result.joined(separator: "\n") + "\n"
        try backupAndWrite(newContent: newContent)
        unipack.reloadAutoPlay()

        await MainActor.run { listener?.onDone() }
    }

    private func audioDurationMs(url: URL) throws -> Int {
        let audioFile = try AVAudioFile(forReading: url)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate * 1000
        return Int(duration)
    }

    private func backupAndWrite(newContent: String) throws {
        guard let autoPlayFile = unipack.autoPlayFile else {
            throw AutoMapperError.noAutoPlay
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy_MM_dd-HH_mm_ss"
        let timestamp = formatter.string(from: Date())
        let backupURL = autoPlayFile.deletingLastPathComponent()
            .appendingPathComponent("autoPlay_\(timestamp)")

        try FileManager.default.copyItem(at: autoPlayFile, to: backupURL)
        try newContent.write(to: autoPlayFile, atomically: true, encoding: .utf8)
    }
}

enum AutoMapperError: LocalizedError {
    case noAutoPlay

    var errorDescription: String? {
        switch self {
        case .noAutoPlay: return "AutoPlay file not found"
        }
    }
}
