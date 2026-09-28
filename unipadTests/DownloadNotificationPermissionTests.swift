import Foundation
import Testing
@testable import unipad

/// The store asks for notification permission only while the user has not answered yet.
@MainActor
struct DownloadNotificationPermissionTests {
    final class FakeCenter: NotificationAuthorizationCenter {
        private let undetermined: Bool
        private(set) var requestCount = 0

        init(undetermined: Bool) {
            self.undetermined = undetermined
        }

        func isAuthorizationUndetermined() async -> Bool { undetermined }

        func requestAuthorization() async {
            requestCount += 1
        }
    }

    /// Right after the system starts, the settings query can stay unanswered for minutes.
    final class FirstQueryHangsCenter: NotificationAuthorizationCenter {
        private var queryCount = 0
        private var hungQuery: CheckedContinuation<Bool, Never>?
        private(set) var requestCount = 0

        func isAuthorizationUndetermined() async -> Bool {
            queryCount += 1
            guard queryCount == 1 else { return true }
            return await withCheckedContinuation { hungQuery = $0 }
        }

        func requestAuthorization() async {
            requestCount += 1
        }

        func answerHungQuery() {
            hungQuery?.resume(returning: true)
            hungQuery = nil
        }
    }

    @Test func asksWhenTheUserHasNotAnswered() async {
        let center = FakeCenter(undetermined: true)
        let permission = DownloadNotificationPermission(center: center)

        await permission.requestIfUndetermined()?.value

        #expect(center.requestCount == 1)
    }

    @Test func doesNotAskAgainAfterAnAnswer() async {
        let center = FakeCenter(undetermined: false)
        let permission = DownloadNotificationPermission(center: center)

        await permission.requestIfUndetermined()?.value

        #expect(center.requestCount == 0)
    }

    @Test func concurrentDownloadStartsAskOnlyOnce() async {
        let center = FakeCenter(undetermined: true)
        let permission = DownloadNotificationPermission(center: center)

        let first = permission.requestIfUndetermined()
        let second = permission.requestIfUndetermined()
        await first?.value

        #expect(second == nil)
        #expect(center.requestCount == 1)
    }

    @Test func unansweredSettingsQueryLetsTheNextDownloadAsk() async throws {
        let center = FirstQueryHangsCenter()
        let permission = DownloadNotificationPermission(center: center, settingsTimeout: .milliseconds(50))

        let unanswered = permission.requestIfUndetermined()
        try await Task.sleep(for: .milliseconds(300))
        let next = permission.requestIfUndetermined()
        await next?.value

        #expect(next != nil)
        #expect(center.requestCount == 1)

        center.answerHungQuery()
        await unanswered?.value

        #expect(center.requestCount == 1)
    }
}
