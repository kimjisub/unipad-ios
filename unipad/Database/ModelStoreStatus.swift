import Foundation
import Observation

/// Whether bookmarks and play counts are really being kept this launch. Read it from the environment
/// (`@Environment(ModelStoreStatus.self)`) wherever that matters to what the user is told.
@MainActor
@Observable
final class ModelStoreStatus {
    /// True when the on-disk store could not be opened and SwiftData is running in memory.
    let isTemporary: Bool
    private(set) var isNoticeDismissed = false

    @ObservationIgnored private let openError: (any Error)?
    @ObservationIgnored private var hasReported = false

    init(openError: (any Error)?) {
        self.openError = openError
        self.isTemporary = openError != nil
    }

    var showsNotice: Bool { isTemporary && !isNoticeDismissed }

    func dismissNotice() {
        isNoticeDismissed = true
    }

    /// Sends the open failure to Crashlytics as a non-fatal, once. The store is opened in the App
    /// initializer, before `FirebaseApp.configure()` runs, so this is called when the first scene
    /// appears rather than at the moment of failure.
    func reportIfNeeded(to crashlytics: any CrashlyticsServiceProtocol) {
        guard let openError, !hasReported else { return }
        hasReported = true
        crashlytics.log("SwiftData store could not be opened; running on an in-memory store: \(openError)")
        crashlytics.record(openError)
    }
}
