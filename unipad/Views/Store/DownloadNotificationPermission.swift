import Foundation
import UserNotifications

protocol NotificationAuthorizationCenter: Sendable {
    func isAuthorizationUndetermined() async -> Bool
    func requestAuthorization() async
}

struct SystemNotificationAuthorizationCenter: NotificationAuthorizationCenter {
    func isAuthorizationUndetermined() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }
}

/// Asks for notification permission the first time a store download starts, instead of at launch.
/// The download never waits for the answer, so declining cannot block it, and users who already
/// answered are not asked again.
///
/// Until the system's notification service is ready (minutes after the device starts), the
/// settings query goes unanswered. An attempt whose query outlasts `settingsTimeout` is given
/// up: the next download asks again, and the late answer does not bring the alert up over
/// whatever the user is doing by then.
@MainActor
final class DownloadNotificationPermission {
    static let shared = DownloadNotificationPermission(center: SystemNotificationAuthorizationCenter())

    private let center: NotificationAuthorizationCenter
    private let settingsTimeout: Duration
    private var currentAttempt: UUID?

    init(center: NotificationAuthorizationCenter, settingsTimeout: Duration = .seconds(10)) {
        self.center = center
        self.settingsTimeout = settingsTimeout
    }

    @discardableResult
    func requestIfUndetermined() -> Task<Void, Never>? {
        guard currentAttempt == nil else { return nil }
        let attempt = UUID()
        currentAttempt = attempt
        let giveUp = Task {
            try? await Task.sleep(for: settingsTimeout)
            if !Task.isCancelled {
                finish(attempt)
            }
        }
        return Task {
            let undetermined = await center.isAuthorizationUndetermined()
            giveUp.cancel()
            guard currentAttempt == attempt else { return }
            if undetermined {
                await center.requestAuthorization()
            }
            finish(attempt)
        }
    }

    private func finish(_ attempt: UUID) {
        if currentAttempt == attempt {
            currentAttempt = nil
        }
    }
}
