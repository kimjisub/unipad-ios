import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

extension AppStoreUpdateChecker {
    static let shared: AppStoreUpdateChecker = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let family: String
#if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: family = "iPhone"
        case .pad: family = "iPad"
        default: family = ""
        }
#else
        family = ""
#endif
        let context = AppStoreUpdateContext(version: version, bundleID: bundleID,
                                            operatingSystem: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                                            deviceFamily: family)
#if DEBUG || UNIPAD_RELEASE_TESTS
        if let fixture = AppStoreUpdateTestSupport.makeChecker(context: context) { return fixture }
#endif
        let client = AppStoreLookupClient()
        let checker = AppStoreUpdateChecker(context: context, cache: AppStoreUpdateCache(),
            installationAllowed: {
#if DEBUG
                return false
#else
                guard let result = try? await AppTransaction.shared,
                      case .verified(let transaction) = result else { return false }
                return AppStoreInstallation.mayCheck(debug: false, version: version,
                    verifiedProduction: transaction.environment == .production && transaction.bundleID == bundleID)
#endif
            },
            storefront: { await Storefront.current?.countryCode },
            lookup: { try await client.lookup(country: $0) })
        checker.observeStorefronts(AsyncStream { continuation in
            let observer = Task {
                for await storefront in Storefront.updates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(storefront.countryCode)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in observer.cancel() }
        })
        return checker
    }()
}
