import Foundation

/// Core usage events shared by the pack import, pack load and play flows.
///
/// Only categorical values leave the device: pack titles, file names, paths, URLs, store codes,
/// raw error text and identifiers are never passed as parameters.
enum UsageEvent {
    static let packImport = "pack_import"
    static let packLoad = "pack_load"
    static let playStart = "play_start"
    static let playEnd = "play_end"
}

enum UsageParam {
    static let result = "result"
    static let importSource = "import_source"
    static let errorType = "error_type"
    static let durationBucket = "duration_bucket"
    static let trigger = "trigger"

    static let allowed: Set<String> = [result, importSource, errorType, durationBucket, trigger]
}

enum UsageResult: String {
    case success
    case failure
    case cancelled
}

enum PackImportSource: String {
    /// Picked with the in-app file importer.
    case file
    /// Opened from another app ("Open in UniPad").
    case openIn = "open_in"
    case store
    /// Downloaded by UniShare code.
    case code
}

enum PlayTrigger: String {
    case pad
    case autoplay
}

enum UsageErrorType: String {
    case invalidPack = "invalid_pack"
    case corruptArchive = "corrupt_archive"
    case fileAccess = "file_access"
    case storage
    case notFound = "not_found"
    case server
    case network
    case soundEngine = "sound_engine"
    case unknown

    static func classify(_ error: Error) -> UsageErrorType {
        switch error {
        case let error as UniPackImporter.ImportError:
            switch error {
            case .criticalError: return .invalidPack
            case .emptyZip, .extractionFailed: return .corruptArchive
            }
        case let error as UniPackDownloader.DownloadError:
            switch error {
            case .criticalError: return .invalidPack
            case .httpError(let status): return status == 404 ? .notFound : .server
            case .writeFailed: return .storage
            case .emptyResponse, .cancelled: return .network
            }
        case let error as APIError:
            switch error {
            case .httpError(let status): return status == 404 ? .notFound : .server
            case .invalidResponse, .decodingFailed: return .server
            case .invalidURL, .networkError: return .network
            }
        case is URLError:
            return .network
        case let error as CocoaError:
            return error.code == .fileWriteOutOfSpace ? .storage : .fileAccess
        default:
            return .unknown
        }
    }
}

extension Error {
    /// User or system cancellation, which is reported as `cancelled` rather than as a failure.
    var isUsageCancellation: Bool {
        if self is CancellationError { return true }
        if let error = self as? URLError, error.code == .cancelled { return true }
        if case .cancelled? = self as? UniPackDownloader.DownloadError { return true }
        return false
    }
}

/// Coarse duration ranges, so that timings are comparable without sending exact values.
enum DurationBucket {
    private static let bounds: [(upperBound: TimeInterval, label: String)] = [
        (1, "lt_1s"),
        (3, "1s_3s"),
        (10, "3s_10s"),
        (30, "10s_30s"),
        (120, "30s_2m"),
        (600, "2m_10m"),
        (1800, "10m_30m"),
    ]

    static func label(for seconds: TimeInterval) -> String {
        bounds.first { seconds < $0.upperBound }?.label ?? "30m_plus"
    }
}

/// Sends the core usage events through the analytics service.
final class UsageAnalytics {
    static let shared = UsageAnalytics(sink: FirebaseManager.shared.analytics)

    private let sink: AnalyticsServiceProtocol

    init(sink: AnalyticsServiceProtocol) {
        self.sink = sink
    }

    func packImportSucceeded(source: PackImportSource) {
        log(UsageEvent.packImport, [
            UsageParam.result: UsageResult.success.rawValue,
            UsageParam.importSource: source.rawValue,
        ])
    }

    func packImportFailed(source: PackImportSource, error: Error) {
        if error.isUsageCancellation {
            log(UsageEvent.packImport, [
                UsageParam.result: UsageResult.cancelled.rawValue,
                UsageParam.importSource: source.rawValue,
            ])
            return
        }
        log(UsageEvent.packImport, [
            UsageParam.result: UsageResult.failure.rawValue,
            UsageParam.importSource: source.rawValue,
            UsageParam.errorType: UsageErrorType.classify(error).rawValue,
        ])
    }

    func makePlaySession(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> PlaySessionTracker {
        PlaySessionTracker(now: now, log: { name, parameters in
            self.log(name, parameters)
        })
    }

    private func log(_ name: String, _ parameters: [String: String]) {
        assert(Set(parameters.keys).isSubset(of: UsageParam.allowed), "Unexpected analytics parameter")
        sink.logEvent(name: name, parameters: parameters)
    }
}
