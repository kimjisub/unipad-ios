import Foundation
import SwiftUI
import Combine

@MainActor
final class PreferenceManager: ObservableObject {
    static let shared = PreferenceManager()

    private let defaults = UserDefaults.standard

    enum Keys {
        static let launchpadConnectMethod = "LaunchpadConnectMethod"
        static let selectedTheme = "SelectedTheme"
        static let prevStoreCount = "PrevStoreCount"
        static let sortMethod = "SortMethod"
        static let sortOrder = "SortOrder"
        static let downloadStoragePath = "download_storage_path"
        static let traceLogClassic = "TraceLogClassic"
    }

    private init() {}

    @AppStorage(Keys.launchpadConnectMethod)
    var launchpadConnectMethod: Int = 0

    @AppStorage(Keys.selectedTheme)
    var selectedTheme: String = Bundle.main.bundleIdentifier ?? "com.kimjisub.unipad"

    var prevStoreCount: Int64 {
        get { Int64(defaults.integer(forKey: Keys.prevStoreCount)) }
        set {
            defaults.set(Int(newValue), forKey: Keys.prevStoreCount)
            objectWillChange.send()
        }
    }

    @AppStorage(Keys.sortMethod)
    var sortMethod: Int = 4

    @AppStorage(Keys.sortOrder)
    var sortOrder: Bool = true

    /// Classic trace log: tap order as numbers on each pad (the pre-4.1 look) instead of the line-and-dot overlay.
    @AppStorage(Keys.traceLogClassic)
    var traceLogClassic: Bool = false

    var downloadStoragePath: String? {
        get { defaults.string(forKey: Keys.downloadStoragePath) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.downloadStoragePath)
            } else {
                defaults.removeObject(forKey: Keys.downloadStoragePath)
            }
            objectWillChange.send()
        }
    }
}
