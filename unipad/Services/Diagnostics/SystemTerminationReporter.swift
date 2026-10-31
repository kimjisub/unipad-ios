import Foundation
import os

/// Exit counts from one daily MetricKit payload, as plain values. `MXMetricPayload` cannot be
/// constructed by an app, so everything after this point is tested with these values instead.
nonisolated struct SystemExitCounts: Sendable, Equatable {
    var begin: Date
    var end: Date
    /// The app version the payload names, which after an update can differ from the running one.
    var appVersion: String
    var appBuild: String?
    var includesMultipleAppVersions: Bool
    /// False when Apple had no exit data for this payload, so every count below is only a default.
    var hasExitCounts = true

    var foregroundMemoryLimit = 0
    var foregroundWatchdog = 0
    var foregroundAbnormal = 0
    var foregroundBadAccess = 0
    var foregroundIllegalInstruction = 0

    var backgroundMemoryLimit = 0
    var backgroundAbnormal = 0
    var backgroundBadAccess = 0
    var backgroundIllegalInstruction = 0
}

/// Terminations the system performs with SIGKILL, which no in-process crash reporter can see.
/// Background memory-pressure exits and normal exits are routine and are not reported.
nonisolated enum SystemTerminationReason: String, CaseIterable, Sendable {
    case foregroundMemoryLimit = "ForegroundMemoryLimit"
    case foregroundWatchdog = "ForegroundWatchdog"
    case backgroundMemoryLimit = "BackgroundMemoryLimit"

    static let errorDomainPrefix = "SystemTermination."

    var errorDomain: String { Self.errorDomainPrefix + rawValue }

    func count(in counts: SystemExitCounts) -> Int {
        switch self {
        case .foregroundMemoryLimit: counts.foregroundMemoryLimit
        case .foregroundWatchdog: counts.foregroundWatchdog
        case .backgroundMemoryLimit: counts.backgroundMemoryLimit
        }
    }
}

nonisolated extension SystemExitCounts {
    var reasons: [SystemTerminationReason] {
        SystemTerminationReason.allCases.filter { $0.count(in: self) > 0 }
    }

    /// One non-fatal per reason present, each carrying every count of the payload. Crash counts are
    /// attached only to compare with the crashes Crashlytics already records itself.
    var nonFatals: [NSError] {
        let info = userInfo
        return reasons.map { NSError(domain: $0.errorDomain, code: 1, userInfo: info) }
    }

    /// Proof that MetricKit reached this install, sent even without terminations: a device with no
    /// reason records otherwise looks the same whether nothing was terminated or nothing arrived.
    var receipt: NSError {
        NSError(domain: receiptDomain, code: 1, userInfo: userInfo)
    }

    /// One receipt per app version and build, kept apart for payloads without exit data so that one
    /// of those does not use up the receipt that proves exit counts arrive.
    var receiptKey: String {
        "\(receiptDomain)-\(appVersion)-\(appBuild ?? "")"
    }

    private var receiptDomain: String {
        SystemTerminationReason.errorDomainPrefix + (hasExitCounts ? "PayloadReceived" : "PayloadWithoutExitCounts")
    }

    private var userInfo: [String: String] {
        var info = [
            "payload_begin": begin.formatted(.iso8601),
            "payload_end": end.formatted(.iso8601),
            "payload_app_version": appVersion,
            "payload_multiple_app_versions": String(includesMultipleAppVersions),
            "foreground_memory_limit": String(foregroundMemoryLimit),
            "foreground_watchdog": String(foregroundWatchdog),
            "foreground_abnormal": String(foregroundAbnormal),
            "foreground_bad_access": String(foregroundBadAccess),
            "foreground_illegal_instruction": String(foregroundIllegalInstruction),
            "background_memory_limit": String(backgroundMemoryLimit),
            "background_abnormal": String(backgroundAbnormal),
            "background_bad_access": String(backgroundBadAccess),
            "background_illegal_instruction": String(backgroundIllegalInstruction),
        ]
        if let appBuild { info["payload_app_build"] = appBuild }
        return info
    }

    /// MetricKit can deliver several payloads for one day; begin and end identify a payload.
    var payloadKey: String {
        "\(begin.timeIntervalSince1970)-\(end.timeIntervalSince1970)"
    }
}

/// Records already sent, kept in user defaults so a payload delivered again is not sent twice.
struct ReportedPayloadLedger {
    static let payloadsKey = "SystemTerminationReportedPayloads"
    static let receiptsKey = "SystemTerminationReportedReceipts"
    static let capacity = 64

    let defaults: UserDefaults
    var defaultsKey = payloadsKey

    func contains(_ key: String) -> Bool {
        keys.contains(key)
    }

    func insert(_ key: String) {
        defaults.set(Array((keys + [key]).suffix(Self.capacity)), forKey: defaultsKey)
    }

    private var keys: [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }
}

/// Sends system terminations from MetricKit payloads to Crashlytics as non-fatals, at most once per
/// payload and reason, and one receipt per app version.
final class SystemTerminationReporter {
    private let crashlytics: any CrashlyticsServiceProtocol
    private let payloads: ReportedPayloadLedger
    private let receipts: ReportedPayloadLedger
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "SystemTermination")

    init(crashlytics: any CrashlyticsServiceProtocol, defaults: UserDefaults) {
        self.crashlytics = crashlytics
        payloads = ReportedPayloadLedger(defaults: defaults)
        receipts = ReportedPayloadLedger(defaults: defaults, defaultsKey: ReportedPayloadLedger.receiptsKey)
    }

    func report(_ payloads: [SystemExitCounts]) {
        for counts in payloads {
            reportTerminations(in: counts)
            reportReceipt(of: counts)
        }
    }

    private func reportTerminations(in counts: SystemExitCounts) {
        let nonFatals = counts.nonFatals
        guard !nonFatals.isEmpty, !payloads.contains(counts.payloadKey) else { return }
        for error in nonFatals {
            logger.info("Reporting \(error.domain, privacy: .public) for \(counts.payloadKey, privacy: .public)")
            crashlytics.record(error)
        }
        payloads.insert(counts.payloadKey)
    }

    private func reportReceipt(of counts: SystemExitCounts) {
        guard !receipts.contains(counts.receiptKey) else { return }
        logger.info("Reporting receipt \(counts.receiptKey, privacy: .public)")
        crashlytics.record(counts.receipt)
        receipts.insert(counts.receiptKey)
    }
}
