import CoreGraphics
import Foundation
import Testing
@testable import unipad

@MainActor
struct PlayCrashKeysTests {
    final class RecordingCrashlytics: CrashlyticsServiceProtocol, @unchecked Sendable {
        private(set) var keys: [String: String] = [:]
        private(set) var writes = 0

        func setCrashlyticsCollectionEnabled(_ enabled: Bool) {}
        func log(_ message: String) {}
        func record(_ error: Error) {}

        func setCustomValue(_ value: String?, forKey key: String) {
            keys[key] = value
            writes += 1
        }
    }

    private let crashlytics = RecordingCrashlytics()
    private let crashKeys: PlayCrashKeys

    private let fullScreen = ScreenLayout(windowSize: CGSize(width: 1376, height: 1032), screenSize: CGSize(width: 1376, height: 1032))
    private let narrow = ScreenLayout(windowSize: CGSize(width: 402, height: 874), screenSize: CGSize(width: 1032, height: 1376))

    private let fullScreenKeys = [
        "play_orientation": "landscape", "play_screen_short_side": "840dp_plus", "play_window_mode": "full_screen",
    ]
    private let narrowKeys = [
        "play_orientation": "portrait", "play_screen_short_side": "lt_600dp", "play_window_mode": "multi_window",
    ]

    init() {
        crashKeys = PlayCrashKeys(crashlytics: crashlytics)
    }

    @Test func aWindowChangeUpdatesTheKeys() {
        crashKeys.screenLayoutChanged(fullScreen)
        #expect(crashlytics.keys == fullScreenKeys)

        crashKeys.screenLayoutChanged(narrow)
        #expect(crashlytics.keys == narrowKeys)
    }

    @Test func noKeysWhileTheWindowIsUnknown() {
        crashKeys.screenLayoutChanged(nil)
        crashKeys.screenCovered()
        crashKeys.screenShown()

        #expect(crashlytics.writes == 0)
    }

    @Test func anUndefinedSizeKeepsTheLastWindow() {
        crashKeys.screenLayoutChanged(fullScreen)
        crashKeys.screenLayoutChanged(nil)

        #expect(crashlytics.keys == fullScreenKeys)
    }

    @Test func theSameWindowIsNotWrittenAgain() {
        crashKeys.screenLayoutChanged(fullScreen)
        let writes = crashlytics.writes

        crashKeys.screenLayoutChanged(fullScreen)

        #expect(crashlytics.writes == writes)
    }

    @Test func closingTheScreenRemovesTheKeysForGood() {
        crashKeys.screenLayoutChanged(fullScreen)

        crashKeys.screenClosed()
        #expect(crashlytics.keys.isEmpty)

        crashKeys.screenLayoutChanged(narrow)
        crashKeys.screenCovered()
        crashKeys.screenShown()
        #expect(crashlytics.keys.isEmpty)
    }

    @Test func aCoveredScreenHasNoKeysAndReturnsWithItsLatestWindow() {
        crashKeys.screenLayoutChanged(fullScreen)

        crashKeys.screenCovered()
        #expect(crashlytics.keys.isEmpty)

        crashKeys.screenLayoutChanged(narrow)
        #expect(crashlytics.keys.isEmpty)

        crashKeys.screenShown()
        #expect(crashlytics.keys == narrowKeys)
    }
}
