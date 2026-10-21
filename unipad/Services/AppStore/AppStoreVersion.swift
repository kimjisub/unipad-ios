import Foundation

/// Decimal components, with missing trailing components equal to zero. Comparing normalized
/// strings avoids integer overflow and rejects suffixes, signs, whitespace and non-ASCII digits.
nonisolated struct NumericAppVersion: Comparable, Sendable {
    private let components: [String]

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            return nil
        }
        var normalized = parts.map { part in
            let digits = part.drop(while: { $0 == "0" })
            return digits.isEmpty ? "0" : String(digits)
        }
        while normalized.last == "0" { normalized.removeLast() }
        components = normalized
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : "0"
            let right = index < rhs.components.count ? rhs.components[index] : "0"
            if left.count != right.count { return left.count < right.count }
            if left != right { return left < right }
        }
        return false
    }
}

nonisolated enum AppStoreCountry {
    /// StoreKit supplies ISO alpha-3. Foundation canonicalizes known region aliases to alpha-2.
    /// Unknown codes remain three letters and are rejected; the device locale is never consulted.
    static func lookupCode(_ storefrontCode: String?) -> String? {
        guard let storefrontCode, storefrontCode.utf8.count == 3,
              storefrontCode.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        guard let code = Locale(identifier: "und_" + storefrontCode).region?.identifier,
              code.utf8.count == 2, Locale.Region.isoRegions.contains(where: { $0.identifier == code }) else { return nil }
        return code
    }
}

/// The home-screen link keeps its own literal URL: `ci/app_store_link.py` reads it from source.
nonisolated enum AppStoreApp {
    static let id: UInt64 = 6760479102
}

nonisolated enum AppStoreInstallation {
    static func mayCheck(debug: Bool, version: String, verifiedProduction: Bool) -> Bool {
        !debug && NumericAppVersion(version) != nil && verifiedProduction
    }
}

nonisolated struct AppStoreUpdateContext: Codable, Equatable, Sendable {
    let version: String
    let bundleID: String
    let operatingSystem: String
    let deviceFamily: String

    func hasUpdate(in data: Data, country: String) throws -> Bool {
        guard data.count <= 1_048_576 else { throw LookupError.invalidResponse }
        let response = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard response.resultCount == 1, response.results.count == 1,
              let app = response.results.first,
              app.trackId == AppStoreApp.id, app.bundleId == bundleID,
              app.kind == "software", app.wrapperType == "software",
              let destination = URL(string: app.trackViewUrl), destination.scheme == "https",
              destination.host == "apps.apple.com",
              destination.pathComponents.dropFirst().first == country.lowercased(),
              let current = NumericAppVersion(version), let latest = NumericAppVersion(app.version),
              let minimumOS = NumericAppVersion(app.minimumOsVersion),
              let currentOS = NumericAppVersion(operatingSystem),
              !app.supportedDevices.isEmpty else {
            throw LookupError.invalidResponse
        }
        // A newer version this device cannot install is a valid answer with nothing to offer.
        return latest > current && currentOS >= minimumOS
            && ["iPhone", "iPad", "iPod"].contains(deviceFamily)
            && app.supportedDevices.contains(where: { $0.hasPrefix(deviceFamily) })
    }

    enum LookupError: Error { case invalidResponse }
    private struct LookupResponse: Decodable {
        let resultCount: Int
        let results: [App]
        struct App: Decodable {
            let trackId: UInt64
            let bundleId: String
            let version: String
            let minimumOsVersion: String
            let kind: String
            let wrapperType: String
            let trackViewUrl: String
            let supportedDevices: [String]
        }
    }
}
