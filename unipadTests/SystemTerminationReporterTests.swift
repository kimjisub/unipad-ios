import Foundation
import Testing
@testable import unipad

private final class RecordingCrashlytics: CrashlyticsServiceProtocol, @unchecked Sendable {
    private(set) var recorded: [NSError] = []

    func setCrashlyticsCollectionEnabled(_ enabled: Bool) {}
    func log(_ message: String) {}

    func record(_ error: Error) {
        recorded.append(error as NSError)
    }
}

@MainActor
struct SystemTerminationReporterTests {
    private let defaults: UserDefaults
    private let crashlytics = RecordingCrashlytics()
    private let reporter: SystemTerminationReporter

    init() {
        defaults = UserDefaults(suiteName: "SystemTerminationReporterTests-\(UUID().uuidString)")!
        reporter = SystemTerminationReporter(crashlytics: crashlytics, ledger: ReportedPayloadLedger(defaults: defaults))
    }

    private func day(_ offset: Int, configure: (inout SystemExitCounts) -> Void = { _ in }) -> SystemExitCounts {
        let begin = Date(timeIntervalSince1970: 1_792_000_000 + TimeInterval(offset) * 86_400)
        var counts = SystemExitCounts(
            begin: begin,
            end: begin.addingTimeInterval(86_400),
            appVersion: "4.3.0",
            appBuild: "14",
            includesMultipleAppVersions: false
        )
        configure(&counts)
        return counts
    }

    @Test func eachSystemTerminationReasonIsReportedUnderItsOwnName() {
        reporter.report([
            day(0) { $0.foregroundMemoryLimit = 2 },
            day(1) { $0.foregroundWatchdog = 1 },
            day(2) { $0.backgroundMemoryLimit = 3 },
        ])

        #expect(crashlytics.recorded.map(\.domain) == [
            "SystemTermination.ForegroundMemoryLimit",
            "SystemTermination.ForegroundWatchdog",
            "SystemTermination.BackgroundMemoryLimit",
        ])
    }

    @Test func aPayloadWithSeveralTerminationsIsOneRecordPerReasonWithTheCounts() throws {
        reporter.report([day(0) {
            $0.foregroundMemoryLimit = 5
            $0.foregroundWatchdog = 2
            $0.foregroundBadAccess = 1
        }])

        #expect(crashlytics.recorded.map(\.domain) == [
            "SystemTermination.ForegroundMemoryLimit",
            "SystemTermination.ForegroundWatchdog",
        ])
        let info = try #require(crashlytics.recorded.first?.userInfo as? [String: String])
        #expect(info["foreground_memory_limit"] == "5")
        #expect(info["foreground_watchdog"] == "2")
        #expect(info["foreground_bad_access"] == "1")
        #expect(info["background_memory_limit"] == "0")
    }

    @Test func routineAndCrashExitsAloneRecordNothing() {
        reporter.report([day(0) {
            $0.foregroundAbnormal = 1
            $0.foregroundBadAccess = 2
            $0.foregroundIllegalInstruction = 3
            $0.backgroundAbnormal = 1
            $0.backgroundBadAccess = 1
            $0.backgroundIllegalInstruction = 1
        }, day(1)])

        #expect(crashlytics.recorded.isEmpty)
    }

    @Test func aPayloadDeliveredAgainIsNotSentTwice() {
        let payload = day(0) { $0.foregroundMemoryLimit = 1 }

        reporter.report([payload, payload])
        reporter.report([payload])
        SystemTerminationReporter(crashlytics: crashlytics, ledger: ReportedPayloadLedger(defaults: defaults))
            .report([payload])

        #expect(crashlytics.recorded.count == 1)
    }

    @Test func anotherPayloadForTheSameDayIsStillSent() {
        let morning = day(0) { $0.foregroundWatchdog = 1 }
        var evening = morning
        evening.begin = morning.begin.addingTimeInterval(3_600)

        reporter.report([morning, evening])

        #expect(crashlytics.recorded.count == 2)
    }

    @Test func aPayloadWithoutTerminationsDoesNotHideALaterOneForTheSameRange() {
        let empty = day(0)
        var withExit = empty
        withExit.foregroundMemoryLimit = 1

        reporter.report([empty])
        reporter.report([withExit])

        #expect(crashlytics.recorded.count == 1)
    }

    @Test func theRecordCarriesThePayloadsVersionAndRange() throws {
        let payload = day(0) {
            $0.appVersion = "4.2.2"
            $0.appBuild = "13"
            $0.includesMultipleAppVersions = true
            $0.backgroundMemoryLimit = 1
        }

        reporter.report([payload])

        let info = try #require(crashlytics.recorded.first?.userInfo as? [String: String])
        #expect(info["payload_app_version"] == "4.2.2")
        #expect(info["payload_app_build"] == "13")
        #expect(info["payload_multiple_app_versions"] == "true")
        #expect(info["payload_begin"] == payload.begin.formatted(.iso8601))
        #expect(info["payload_end"] == payload.end.formatted(.iso8601))
    }

    @Test func theLedgerKeepsOnlyTheMostRecentPayloads() {
        let ledger = ReportedPayloadLedger(defaults: defaults)
        for index in 0...ReportedPayloadLedger.capacity {
            ledger.insert("payload-\(index)")
        }

        #expect(!ledger.contains("payload-0"))
        #expect(ledger.contains("payload-1"))
        #expect(ledger.contains("payload-\(ReportedPayloadLedger.capacity)"))
    }
}
