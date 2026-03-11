import Foundation
import SwiftUI
import Combine

@MainActor
final class PreferenceManager: ObservableObject {
    static let shared = PreferenceManager()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let launchpadConnectMethod = "LaunchpadConnectMethod"
        static let selectedTheme = "SelectedTheme"
        static let prevStoreCount = "PrevStoreCount"
        static let sortMethod = "SortMethod"
        static let sortOrder = "SortOrder"
        static let downloadStoragePath = "download_storage_path"
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
