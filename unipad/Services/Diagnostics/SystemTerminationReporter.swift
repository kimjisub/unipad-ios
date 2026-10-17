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

/// Payloads already sent, kept in user defaults so a payload delivered again is not sent twice.
struct ReportedPayloadLedger {
    static let defaultsKey = "SystemTerminationReportedPayloads"
    static let capacity = 64

    let defaults: UserDefaults

    func contains(_ key: String) -> Bool {
        keys.contains(key)
    }

    func insert(_ key: String) {
        defaults.set(Array((keys + [key]).suffix(Self.capacity)), forKey: Self.defaultsKey)
    }

    private var keys: [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }
}

/// Sends system terminations from MetricKit payloads to Crashlytics as non-fatals, at most once per
/// payload and reason.
final class SystemTerminationReporter {
    private let crashlytics: any CrashlyticsServiceProtocol
    private let ledger: ReportedPayloadLedger
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "SystemTermination")

    init(crashlytics: any CrashlyticsServiceProtocol, ledger: ReportedPayloadLedger) {
        self.crashlytics = crashlytics
        self.ledger = ledger
    }

    func report(_ payloads: [SystemExitCounts]) {
        for counts in payloads {
            let nonFatals = counts.nonFatals
            guard !nonFatals.isEmpty, !ledger.contains(counts.payloadKey) else { continue }
            for error in nonFatals {
                logger.info("Reporting \(error.domain, privacy: .public) for \(counts.payloadKey, privacy: .public)")
                crashlytics.record(error)
            }
            ledger.insert(counts.payloadKey)
        }
    }
}
