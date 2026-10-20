#if DEBUG || UNIPAD_RELEASE_TESTS
import Foundation

/// Like the offline pack fixtures, this override exists only in test builds and requires both
/// an isolated test library and local-only Firebase. Store builds cannot read the override.
enum AppStoreUpdateTestSupport {
    static func makeChecker(context: AppStoreUpdateContext) -> AppStoreUpdateChecker? {
        guard FirebaseRuntime.isLocalOnly, ReleaseTestSupport.root != nil,
              let mode = UserDefaults.standard.string(forKey: "UniPadAppStoreResponse"),
              ["available", "current", "failure", "delay"].contains(mode),
              let token = ReleaseTestSupport.token,
              let defaults = UserDefaults(suiteName: "AppStoreUpdateFixture-" + token) else { return nil }
        return AppStoreUpdateChecker(context: context, cache: AppStoreUpdateCache(defaults: defaults),
                                    installationAllowed: { true }, storefront: { "KOR" }, lookup: { _ in
            switch mode {
            case "failure": throw URLError(.notConnectedToInternet)
            case "delay":
                try await Task.sleep(for: .seconds(10))
                throw URLError(.timedOut)
            default:
                return try JSONSerialization.data(withJSONObject: ["resultCount": 1, "results": [[
                    "trackId": 6760479102, "bundleId": context.bundleID,
                    "version": mode == "available" ? "999.0" : context.version,
                    "minimumOsVersion": "17.0", "kind": "software", "wrapperType": "software",
                    "trackViewUrl": "https://apps.apple.com/kr/app/unipad/id6760479102",
                    "supportedDevices": ["iPhone17Pro-iPhone17Pro", "iPadPro-iPadPro"],
                ]]])
            }
        })
    }
}
#endif
