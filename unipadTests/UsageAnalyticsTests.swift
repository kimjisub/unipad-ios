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

        analytics.packImportFailed(source: .file, error: CancellationError())
        analytics.packImportFailed(source: .store, error: URLError(.cancelled))

        #expect(sink.events.map(\.parameters) == [
            ["result": "cancelled", "import_source": "file"],
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
        (URLError(.notConnectedToInternet), .networkOffline),
        (CocoaError(.fileReadNoPermission), .fileAccess),
        (CocoaError(.fileWriteOutOfSpace), .storage),
        (NSError(domain: "other", code: 1), .unknown),
    ])
    func errorClassification(error: Error, expected: UsageErrorType) {
        #expect(UsageErrorType.classify(error) == expected)
    }

    @Test(arguments: [
        (URLError.timedOut, "network_timeout"),
        (.networkConnectionLost, "network_lost"),
        (.notConnectedToInternet, "network_offline"),
        (.cannotFindHost, "network"),
    ])
    func networkFailuresKeepTheirReason(code: URLError.Code, category: String) {
        let sink = RecordingAnalytics()
        UsageAnalytics(sink: sink).packImportFailed(source: .store, error: URLError(code))
        #expect(sink.events.map(\.parameters) == [
            ["result": "failure", "import_source": "store", "error_type": category],
        ])
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
        session.playTriggered(.pad(.screen))
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
        session.playTriggered(.pad(.screen))
        session.playTriggered(.pad(.screen))
        clock.seconds += 45
        session.ended()
        session.ended()

        #expect(sink.events.map(\.name) == ["pack_load", "play_start", "play_first_input", "play_end"])
        #expect(sink.events(named: "play_start")[0].parameters == ["trigger": "autoplay"])
        #expect(sink.events(named: "play_first_input").map(\.parameters) == [["trigger": "pad", "input_source": "screen"]])
        #expect(sink.events(named: "play_end")[0].parameters == ["duration_bucket": "30s_2m"])
    }

    @Test func noPlayEventsWithoutAPressAfterLoading() {
        let (sink, _, session) = makeSession()

        session.playTriggered(.pad(.screen))
        session.loadStarted()
        session.playTriggered(.pad(.screen))
        session.loadSucceeded()
        session.ended()
        session.playTriggered(.pad(.screen))

        #expect(sink.events.map(\.name) == ["pack_load"])
    }

    @Test func automaticOnlyVisitHasNoHumanInputAndNextVisitCanRecordOne() {
        let sink = RecordingAnalytics()
        let analytics = UsageAnalytics(sink: sink)
        let automatic = analytics.makePlaySession()
        automatic.loadStarted()
        automatic.loadSucceeded()
        automatic.playTriggered(.autoplay)
        automatic.playTriggered(.autoplay)
        automatic.ended()
        automatic.playTriggered(.pad(.screen))
        #expect(sink.events(named: "play_first_input").isEmpty)

        let next = analytics.makePlaySession()
        next.loadStarted()
        next.playTriggered(.pad(.screen))
        next.loadSucceeded()
        next.playTriggered(.pad(.midi))
        next.playTriggered(.autoplay)
        next.playTriggered(.pad(.screen))
        next.ended()
        #expect(sink.events(named: "play_start").map(\.parameters) == [
            ["trigger": "autoplay"], ["trigger": "pad"],
        ])
        #expect(sink.events(named: "play_first_input").map(\.parameters) == [["trigger": "pad", "input_source": "midi"]])
        #expect(sink.events(named: "play_end").count == 2)
    }

    @Test(arguments: [(PlayInputSource.screen, "screen"), (PlayInputSource.midi, "midi")])
    func firstHumanInputNamesOnlyItsSource(source: PlayInputSource, value: String) {
        let (sink, _, session) = makeSession()

        session.loadStarted()
        session.loadSucceeded()
        session.playTriggered(.autoplay)
        session.playTriggered(.pad(source))
        session.playTriggered(.pad(source == .screen ? .midi : .screen))
        session.playTriggered(.pad(source))
        session.ended()

        #expect(sink.events(named: "play_first_input").map(\.parameters) == [["trigger": "pad", "input_source": value]])
        for name in ["pack_load", "play_start", "play_end"] {
            #expect(sink.events(named: name).allSatisfy { $0.parameters["input_source"] == nil }, "\(name)")
        }
    }

    @Test func everyParameterIsAllowedAndCategorical() {
        let (sink, clock, session) = makeSession()
        let analytics = UsageAnalytics(sink: sink)

        analytics.packImportSucceeded(source: .openIn)
        analytics.packImportFailed(source: .file, error: CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: "/tmp/pack.zip"]))
        session.screenLayoutChanged(ScreenLayout(windowSize: CGSize(width: 1210, height: 834), screenSize: CGSize(width: 1210, height: 834)))
        session.loadStarted()
        clock.seconds += 7200
        session.loadSucceeded()
        session.playTriggered(.pad(.midi))
        session.ended()

        let categorical = Set(
            ["success", "failure", "cancelled", "file", "open_in", "store", "pad", "autoplay", "screen", "midi",
             "lt_1s", "1s_3s", "3s_10s", "10s_30s", "30s_2m", "2m_10m", "10m_30m", "30m_plus",
             "landscape", "portrait", "lt_600dp", "600dp_839dp", "840dp_plus", "full_screen", "multi_window"]
        ).union([
            "invalid_pack", "corrupt_archive", "file_access", "storage", "not_found", "server", "network",
            "network_timeout", "network_lost", "network_offline", "sound_engine", "unknown",
        ])
        for event in sink.events {
            #expect(Set(event.parameters.keys).isSubset(of: UsageParam.allowed))
            #expect(Set(event.parameters.values).isSubset(of: categorical))
        }
        #expect(sink.events(named: "pack_load")[0].parameters["duration_bucket"] == "30m_plus")
        #expect(sink.events(named: "play_first_input")[0].parameters["input_source"] == "midi")
        #expect(sink.events(named: "play_end")[0].parameters["screen_short_side"] == "600dp_839dp")
    }

    @Test(arguments: [(0.0, "lt_1s"), (0.999, "lt_1s"), (1.0, "1s_3s"), (9.9, "3s_10s"), (599, "2m_10m"), (1800, "30m_plus")])
    func durationBuckets(seconds: TimeInterval, label: String) {
        #expect(DurationBucket.label(for: seconds) == label)
    }

    // MARK: - Screen layout

    private func layout(_ width: CGFloat, _ height: CGFloat, screen: CGSize? = nil) -> ScreenLayout? {
        ScreenLayout(windowSize: CGSize(width: width, height: height), screenSize: screen ?? CGSize(width: width, height: height))
    }

    @Test(arguments: [
        (1, "lt_600dp"), (599, "lt_600dp"), (600, "600dp_839dp"), (839, "600dp_839dp"), (840, "840dp_plus"), (2000, "840dp_plus"),
    ] as [(CGFloat, String)])
    func shortSideBucketsMatchAndroid(points: CGFloat, bucket: String) {
        #expect(ScreenLayout.ShortSide.of(points).rawValue == bucket)
        #expect(layout(1280, points)?.shortSide.rawValue == bucket, "landscape window")
        #expect(layout(points, 1280)?.shortSide.rawValue == bucket, "portrait window")
    }

    @Test func aWiderWindowIsLandscapeAndASquareOneIsPortrait() {
        #expect(layout(801, 800)?.orientation == .landscape)
        #expect(layout(800, 800)?.orientation == .portrait)
        #expect(layout(800, 1280)?.orientation == .portrait)
    }

    @Test func anUndefinedSizeReportsNoLayout() {
        #expect(layout(0, 800) == nil)
        #expect(layout(1280, 0) == nil)
        #expect(layout(0, 0, screen: CGSize(width: 1024, height: 768)) == nil)
    }

    @Test func aWindowSmallerThanItsScreenIsMultiWindow() {
        let iPad = CGSize(width: 1376, height: 1032)
        #expect(layout(1376, 1032, screen: iPad)?.window == .fullScreen)
        #expect(layout(1032, 1376, screen: iPad)?.window == .fullScreen, "mid-rotation, the sides still cover the screen")
        #expect(layout(1376, 1031.5, screen: iPad)?.window == .fullScreen, "half-point rounding")
        #expect(layout(684, 1032, screen: iPad)?.window == .multiWindow, "split view half")
        #expect(layout(1376, 900, screen: iPad)?.window == .multiWindow, "resizable window")
        #expect(layout(874, 402, screen: CGSize(width: 874, height: 402))?.window == .fullScreen, "iPhone")
    }

    @Test func onlyTheThreeBucketNamesAreSent() {
        #expect(layout(700, 1000, screen: CGSize(width: 1032, height: 1376))?.parameters == [
            "orientation": "portrait", "screen_short_side": "600dp_839dp", "window_mode": "multi_window",
        ])
    }

    @Test func playStartAndEndCarryTheLayoutAtThatMoment() {
        let (sink, _, session) = makeSession()

        session.screenLayoutChanged(layout(874, 402))
        session.loadStarted()
        session.loadSucceeded()
        session.playTriggered(.pad(.screen))
        session.screenLayoutChanged(layout(684, 1032, screen: CGSize(width: 1032, height: 1376)))
        session.screenLayoutChanged(nil)
        session.ended()

        #expect(sink.events(named: "play_start").map(\.parameters) == [[
            "trigger": "pad", "orientation": "landscape", "screen_short_side": "lt_600dp", "window_mode": "full_screen",
        ]])
        #expect(sink.events(named: "play_end").map(\.parameters) == [[
            "duration_bucket": "lt_1s", "orientation": "portrait", "screen_short_side": "600dp_839dp", "window_mode": "multi_window",
        ]])
        for name in ["pack_load", "play_first_input"] {
            #expect(sink.events(named: name).allSatisfy { $0.parameters["window_mode"] == nil }, "\(name)")
        }
    }

    @Test func aLayoutChangeBeforeStartIsTheOneStartReports() {
        let (sink, _, session) = makeSession()

        session.loadStarted()
        session.screenLayoutChanged(layout(402, 874))
        session.loadSucceeded()
        session.screenLayoutChanged(layout(1376, 1032))
        session.screenLayoutChanged(layout(0, 1032))
        session.playTriggered(.autoplay)
        session.screenLayoutChanged(layout(1032, 1376))
        session.playTriggered(.pad(.midi))

        #expect(sink.events(named: "play_start").map(\.parameters) == [[
            "trigger": "autoplay", "orientation": "landscape", "screen_short_side": "840dp_plus", "window_mode": "full_screen",
        ]])
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
