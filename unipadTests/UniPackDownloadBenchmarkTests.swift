import CryptoKit
import Darwin
import Foundation
import Testing
@testable import unipad

/// Downloads one real pack from `UNIPAD_DOWNLOAD_BENCH_URL` (a local server during a measurement run)
/// and prints the download time, the peak memory while downloading, and the SHA-256 of the received
/// ZIP, so that two builds can be compared under the same conditions. Skipped when the variable is unset.
/// Run with `TEST_RUNNER_UNIPAD_DOWNLOAD_BENCH_URL=<url> TEST_RUNNER_UNIPAD_DOWNLOAD_BENCH_OUT=<existing file>
/// xcodebuild test -only-testing:unipadTests/UniPackDownloadBenchmarkTests`.
@MainActor
struct UniPackDownloadBenchmarkTests {
    private static let benchURL = ProcessInfo.processInfo.environment["UNIPAD_DOWNLOAD_BENCH_URL"]

    @Test(.enabled(if: benchURL != nil))
    func measureLargePackDownload() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "DownloadBench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sampler = FootprintSampler()
        let recorder = BenchmarkDelegate(zipURL: workspace.appending(path: "bench.zip"), sampler: sampler)
        let baseline = FootprintSampler.currentFootprint()
        sampler.start()
        let start = ContinuousClock.now
        await UniPackDownloader().download(
            title: "bench",
            url: try #require(Self.benchURL),
            workspace: workspace,
            folderName: "bench",
            delegate: recorder
        )
        let total = ContinuousClock.now - start
        sampler.stop()

        let downloadTime = start.duration(to: try #require(recorder.downloadFinishedAt))
        let mb = { (bytes: UInt64) in String(format: "%.1f", Double(bytes) / 1_048_576) }
        let line = """
            UNIPAD_BENCH download=\(downloadTime) total=\(total) \
            baselineMB=\(mb(baseline)) peakDownloadMB=\(mb(recorder.peakDuringDownload)) \
            peakTotalMB=\(mb(sampler.peak)) progressCalls=\(recorder.progressCalls) \
            lastPercent=\(recorder.lastPercent) sha256=\(recorder.zipSHA256 ?? "-") \
            installed=\(recorder.installedFolder != nil) error=\(recorder.error.map { "\($0)" } ?? "-")
            """
        print(line)
        // Console output of parallel test clones does not reach xcodebuild; a simulator can write host paths.
        if let out = ProcessInfo.processInfo.environment["UNIPAD_DOWNLOAD_BENCH_OUT"],
           let handle = FileHandle(forWritingAtPath: out) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            handle.closeFile()
        }
        #expect(recorder.error == nil)
        #expect(recorder.installedFolder != nil)
    }
}

@MainActor
private final class BenchmarkDelegate: UniPackDownloader.Delegate, @unchecked Sendable {
    private let zipURL: URL
    private let sampler: FootprintSampler
    var downloadFinishedAt: ContinuousClock.Instant?
    var peakDuringDownload: UInt64 = 0
    var progressCalls = 0
    var lastPercent = -1
    var zipSHA256: String?
    var installedFolder: URL?
    var error: Error?

    init(zipURL: URL, sampler: FootprintSampler) {
        self.zipURL = zipURL
        self.sampler = sampler
    }

    func onInstallStart() {}
    func onGetFileSize(fileSize: Int64, contentLength: Int64, preKnownFileSize: Int64) {}

    func onDownloadProgress(percent: Int, downloadedSize: Int64, fileSize: Int64) {
        progressCalls += 1
        lastPercent = percent
    }

    /// Called once the ZIP is fully on disk and before extraction starts.
    func onImportStart() {
        downloadFinishedAt = .now
        peakDuringDownload = sampler.peak
        zipSHA256 = try? Self.sha256(of: zipURL)
    }

    func onInstallComplete(folder: URL) { installedFolder = folder }
    func onError(_ error: Error) { self.error = error }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Samples the process's physical footprint (the number jetsam kills on) every 5 ms.
private final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var _peak: UInt64 = 0
    private var running = false

    var peak: UInt64 { lock.withLock { _peak } }

    func start() {
        lock.withLock { running = true; _peak = Self.currentFootprint() }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let now = Self.currentFootprint()
                lock.withLock { _peak = max(_peak, now) }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    func stop() { lock.withLock { running = false } }

    static func currentFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
