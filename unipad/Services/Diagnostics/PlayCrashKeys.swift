import Foundation

/// Crash reports carry the play screen's window in the same coarse buckets as `play_start`, so a
/// crash in a large window can be told apart. The keys exist only while that screen is the one
/// showing: a crash anywhere else reports no window, not the last one played in.
final class PlayCrashKeys {
    private enum Screen {
        case shown
        case covered
        case closed
    }

    private static let names = [UsageParam.orientation, UsageParam.screenShortSide, UsageParam.windowMode]

    private let crashlytics: any CrashlyticsServiceProtocol
    private var screen = Screen.shown
    private var layout: ScreenLayout?
    private var written: ScreenLayout?

    init(crashlytics: any CrashlyticsServiceProtocol) {
        self.crashlytics = crashlytics
    }

    /// A nil layout (a moment of undefined size) keeps the one known before.
    func screenLayoutChanged(_ layout: ScreenLayout?) {
        if let layout { self.layout = layout }
        writeKeys()
    }

    func screenCovered() {
        screen = .covered
        writeKeys()
    }

    func screenShown() {
        screen = .shown
        writeKeys()
    }

    /// The view can still lay out while it leaves; nothing after this writes the keys again.
    func screenClosed() {
        screen = .closed
        writeKeys()
    }

    private func writeKeys() {
        let current = screen == .shown ? layout : nil
        guard current != written else { return }
        written = current
        let values = current?.parameters ?? [:]
        for name in Self.names {
            crashlytics.setCustomValue(values[name], forKey: "play_\(name)")
        }
    }
}
