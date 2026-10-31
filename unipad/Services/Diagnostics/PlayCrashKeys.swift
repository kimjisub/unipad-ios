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
        guard screen != .closed else { return }
        screen = .covered
        writeKeys()
    }

    func screenShown() {
        guard screen != .closed else { return }
        screen = .shown
        writeKeys()
    }

    /// The view can still lay out while it leaves, so this is final: nothing writes the keys again.
    func screenClosed() {
        screen = .closed
        writeKeys()
    }

    private func writeKeys() {
        let current = screen == .shown ? layout : nil
        guard current != written, let names = (current ?? written)?.parameters.keys else { return }
        written = current
        for name in names {
            crashlytics.setCustomValue(current?.parameters[name], forKey: "play_\(name)")
        }
    }
}
