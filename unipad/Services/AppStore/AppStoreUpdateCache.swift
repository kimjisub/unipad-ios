import Foundation

/// One entry, scoped to the storefront and the installed app/device context. A failed attempt
/// retains its retry time, never a previous successful payload.
@MainActor
final class AppStoreUpdateCache {
    struct Entry: Codable {
        let country: String
        let context: AppStoreUpdateContext
        let checkedAt: Date
        let payload: Data?
    }

    private let defaults: UserDefaults
    private let key = "appStoreUpdateCheck.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> Entry? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func save(_ entry: Entry?) {
        if let entry, let data = try? JSONEncoder().encode(entry) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
