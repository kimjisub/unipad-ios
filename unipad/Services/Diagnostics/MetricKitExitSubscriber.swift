import Foundation
import MetricKit

/// Receives the daily MetricKit payloads and hands their exit counts to `SystemTerminationReporter`.
///
/// Uses `MXMetricManager`, which Apple marks to be deprecated in favour of `MetricManager`; the
/// replacement exists only from iOS 27, and this one covers every supported version from iOS 17.
/// MetricKit delivers nothing on the simulator.
nonisolated final class MetricKitExitSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    @MainActor private static var active: MetricKitExitSubscriber?

    private let reporter: SystemTerminationReporter

    private init(reporter: SystemTerminationReporter) {
        self.reporter = reporter
    }

    /// Subscribes once per process, off the main thread so app launch does not wait for MetricKit.
    @MainActor
    static func start(reportingTo crashlytics: any CrashlyticsServiceProtocol) {
        guard active == nil else { return }
        let subscriber = MetricKitExitSubscriber(
            reporter: SystemTerminationReporter(crashlytics: crashlytics, defaults: .standard)
        )
        active = subscriber
        DispatchQueue.global(qos: .utility).async {
            MXMetricManager.shared.add(subscriber)
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let counts = payloads.map(SystemExitCounts.init)
        guard !counts.isEmpty else { return }
        Task { @MainActor [reporter] in
            reporter.report(counts)
        }
    }
}

nonisolated extension SystemExitCounts {
    init(_ payload: MXMetricPayload) {
        let exits = payload.applicationExitMetrics
        self.init(
            begin: payload.timeStampBegin,
            end: payload.timeStampEnd,
            appVersion: payload.latestApplicationVersion,
            appBuild: payload.metaData?.applicationBuildVersion,
            includesMultipleAppVersions: payload.includesMultipleApplicationVersions,
            hasExitCounts: exits != nil
        )
        guard let exits else { return }
        let foreground = exits.foregroundExitData
        let background = exits.backgroundExitData
        foregroundMemoryLimit = foreground.cumulativeMemoryResourceLimitExitCount
        foregroundWatchdog = foreground.cumulativeAppWatchdogExitCount
        foregroundAbnormal = foreground.cumulativeAbnormalExitCount
        foregroundBadAccess = foreground.cumulativeBadAccessExitCount
        foregroundIllegalInstruction = foreground.cumulativeIllegalInstructionExitCount
        backgroundMemoryLimit = background.cumulativeMemoryResourceLimitExitCount
        backgroundAbnormal = background.cumulativeAbnormalExitCount
        backgroundBadAccess = background.cumulativeBadAccessExitCount
        backgroundIllegalInstruction = background.cumulativeIllegalInstructionExitCount
    }
}
