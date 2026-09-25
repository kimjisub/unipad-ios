import Foundation
import Testing
@testable import unipad

/// The core usage events, checked against a recording analytics service instead of Firebase.
@MainActor
struct UsageAnalyticsTests {
    final class RecordingAnalytics: AnalyticsServiceProtocol, @unchecked Sendable {
        struct Event {
            let name: String
            let parameters: [String: String]
        }

        private(set) var events: [Event] = []

        func logEvent(name: String, parameters: [String: Any]?) {
            let strings = (parameters ?? [:]).mapValues { "\($0)" }
            events.append(Event(name: name, parameters: strings))
        }

        func setUserProperty(value: String?, forName name: String) {}

        func events(named name: String) -> [Event] {
            events.filter { $0.name == name }
        }
    }

    final class FakeClock {
        var seconds: TimeInterval = 100
    }

    private func makeSession() -> (RecordingAnalytics, FakeClock, PlaySessionTracker) {
        let sink = RecordingAnalytics()
        let clock = FakeClock()
        let session = UsageAnalytics(sink: sink).makePlaySession(now: { clock.seconds })
        return (sink, clock, session)
    }

    // MARK: - Pack import

    @Test func importSuccessReportsSourceOnly() {
        let sink = RecordingAnalytics()
        UsageAnalytics(sink: sink).packImportSucceeded(source: .store)

        #expect(sink.events.count == 1)
        #expect(sink.events[0].name == "pack_import")
        #expect(sink.events[0].parameters == ["result": "success", "import_source": "store"])
    }

    @Test func importFailureReportsClassifiedErrorWithoutItsText() {
        let sink = RecordingAnalytics()
        let analytics = UsageAnalytics(sink: sink)
        let detail = "/private/var/mobile/Containers/Data/My Secret Pack/info missing"

        analytics.packImportFailed(source: .file, error: UniPackImporter.ImportError.criticalError(detail))

        let event = sink.events.first
        #expect(event?.parameters == ["result": "failure", "import_source": "file", "error_type": "invalid_pack"])
        #expect(event?.parameters.values.contains { $0.contains("Secret") || $0.contains("/") } == false)
    }

    @Test func importCancellationIsNotAFailure() {
        let sink = RecordingAnalytics()
        let analytics = UsageAnalytics(sink: sink)

        analytics.packImportFailed(source: .code, error: CancellationError())
        analytics.packImportFailed(source: .store, error: URLError(.cancelled))

        #expect(sink.events.map(\.parameters) == [
            ["result": "cancelled", "import_source": "code"],
            ["result": "cancelled", "import_source": "store"],
        ])
    }

    @Test(arguments: [
        (UniPackImporter.ImportError.emptyZip as Error, UsageErrorType.corruptArchive),
        (UniPackImporter.ImportError.extractionFailed("EOCD not found"), .corruptArchive),
        (UniPackDownloader.DownloadError.criticalError("x"), .invalidPack),
        (UniPackDownloader.DownloadError.httpError(statusCode: 404), .notFound),
        (UniPackDownloader.DownloadError.httpError(statusCode: 503), .server),
        (UniPackDownloader.DownloadError.writeFailed, .storage),
        (APIError.httpError(statusCode: 404), .notFound),
        (APIError.decodingFailed, .server),
        (URLError(.notConnectedToInternet), .network),
        (CocoaError(.fileReadNoPermission), .fileAccess),
        (CocoaError(.fileWriteOutOfSpace), .storage),
        (NSError(domain: "other", code: 1), .unknown),
    ])
    func errorClassification(error: Error, expected: UsageErrorType) {
        #expect(UsageErrorType.classify(error) == expected)
    }

    // MARK: - Pack load and play

    @Test func loadSuccessIsReportedOnceWithDurationBucket() {
        let (sink, clock, session) = makeSession()

        session.loadStarted()
        clock.seconds += 2
        session.loadSucceeded()
        session.loadSucceeded()
        session.loadStarted()
        session.loadFailed(.soundEngine)

        #expect(sink.events.map(\.name) == ["pack_load"])
        #expect(sink.events[0].parameters == ["result": "success", "duration_bucket": "1s_3s"])
    }

    @Test func loadFailureIsReportedOnceAndEndsTheSession() {
        let (sink, _, session) = makeSession()

        session.loadStarted()
        session.loadFailed(.invalidPack)
        session.loadFailed(.soundEngine)
        session.loadSucceeded()
        session.playTriggered(.pad)
        session.ended()

        #expect(sink.events.map(\.name) == ["pack_load"])
        #expect(sink.events[0].parameters == ["result": "failure", "error_type": "invalid_pack"])
    }

    @Test func leavingWhileLoadingIsCancelled() {
        let (sink, _, session) = makeSession()

        session.loadStarted()
        session.ended()
        session.ended()

        #expect(sink.events.map(\.parameters) == [["result": "cancelled"]])
    }

    @Test func playStartsOnceAndEndsOnceWithDuration() {
        let (sink, clock, session) = makeSession()

        session.loadStarted()
        session.loadSucceeded()
        session.playTriggered(.autoplay)
        session.playTriggered(.pad)
        session.playTriggered(.pad)
        clock.seconds += 45
        session.ended()
        session.ended()

        #expect(sink.events.map(\.name) == ["pack_load", "play_start", "play_end"])
        #expect(sink.events(named: "play_start")[0].parameters == ["trigger": "autoplay"])
        #expect(sink.events(named: "play_end")[0].parameters == ["duration_bucket": "30s_2m"])
    }

    @Test func noPlayEventsWithoutAPressAfterLoading() {
        let (sink, _, session) = makeSession()

        session.playTriggered(.pad)
        session.loadStarted()
        session.playTriggered(.pad)
        session.loadSucceeded()
        session.ended()
        session.playTriggered(.pad)

        #expect(sink.events.map(\.name) == ["pack_load"])
    }

    @Test func everyParameterIsAllowedAndCategorical() {
        let (sink, clock, session) = makeSession()
        let analytics = UsageAnalytics(sink: sink)

        analytics.packImportSucceeded(source: .openIn)
        analytics.packImportFailed(source: .file, error: CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: "/tmp/pack.zip"]))
        session.loadStarted()
        clock.seconds += 7200
        session.loadSucceeded()
        session.playTriggered(.pad)
        session.ended()

        let categorical = Set(
            ["success", "failure", "cancelled", "file", "open_in", "store", "code", "pad", "autoplay",
             "lt_1s", "1s_3s", "3s_10s", "10s_30s", "30s_2m", "2m_10m", "10m_30m", "30m_plus"]
        ).union([
            "invalid_pack", "corrupt_archive", "file_access", "storage", "not_found", "server", "network",
            "sound_engine", "unknown",
        ])
        for event in sink.events {
            #expect(Set(event.parameters.keys).isSubset(of: UsageParam.allowed))
            #expect(Set(event.parameters.values).isSubset(of: categorical))
        }
        #expect(sink.events(named: "pack_load")[0].parameters["duration_bucket"] == "30m_plus")
    }

    @Test(arguments: [(0.0, "lt_1s"), (0.999, "lt_1s"), (1.0, "1s_3s"), (9.9, "3s_10s"), (599, "2m_10m"), (1800, "30m_plus")])
    func durationBuckets(seconds: TimeInterval, label: String) {
        #expect(DurationBucket.label(for: seconds) == label)
    }

    // MARK: - Collection settings

    @Test func testRunsNeverReachFirebase() {
        #expect(FirebaseRuntime.isLocalOnly)
        #expect(FirebaseManager.shared.analytics is AnalyticsServiceStub)
    }

    /// Collection stays on by default but is never forced on in code, so a persisted
    /// `setAnalyticsCollectionEnabled(false)` or `FIREBASE_ANALYTICS_COLLECTION_DEACTIVATED` still wins.
    /// Advertising consent and ad identifiers are off.
    @Test func infoPlistKeepsAdvertisingSignalsOff() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["FIREBASE_ANALYTICS_COLLECTION_ENABLED"] as? Bool == true)
        #expect(info["FIREBASE_ANALYTICS_COLLECTION_DEACTIVATED"] == nil)
        #expect(info["GOOGLE_ANALYTICS_DEFAULT_ALLOW_ANALYTICS_STORAGE"] as? Bool == true)
        #expect(info["GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_STORAGE"] as? Bool == false)
        #expect(info["GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_USER_DATA"] as? Bool == false)
        #expect(info["GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS"] as? Bool == false)
        #expect(info["GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED"] as? Bool == false)
        #expect(info["GOOGLE_ANALYTICS_REGISTRATION_WITH_AD_NETWORK_ENABLED"] as? Bool == false)
        #expect(info["NSUserTrackingUsageDescription"] == nil)
    }

    @Test func privacyManifestIsBundledAndDeclaresNoTracking() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let data = try Data(contentsOf: url)
        let manifest = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        let types = (manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]) ?? []
        #expect(types.contains { $0["NSPrivacyCollectedDataType"] as? String == "NSPrivacyCollectedDataTypeProductInteraction" })
        #expect(types.allSatisfy { $0["NSPrivacyCollectedDataTypeTracking"] as? Bool == false })
    }
}
