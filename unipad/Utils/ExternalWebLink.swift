import Foundation

/// Keeps automated visits to the official website out of its usage counts.
nonisolated enum ExternalWebLink {
    static func url(_ url: URL, launchArguments: [String] = ProcessInfo.processInfo.arguments) -> URL {
        // Read this launch's explicit argument, never the saved Firebase preference.
        guard let flag = launchArguments.firstIndex(of: "-UniPadFirebaseLocalOnly"),
              launchArguments.indices.contains(flag + 1), launchArguments[flag + 1] == "YES",
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "unipad.io",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }

        // Preserve the existing query's escaping, order and empty values, and the fragment.
        var items = components.percentEncodedQuery.map { $0.isEmpty ? [] : $0.components(separatedBy: "&") } ?? []
        let markers = items.indices.filter {
            items[$0].components(separatedBy: "=")[0].removingPercentEncoding == "no_analytics"
        }
        if let first = markers.first {
            items[first] = "no_analytics=1"
            for index in markers.dropFirst().reversed() { items.remove(at: index) }
        } else {
            items.append("no_analytics=1")
        }
        components.percentEncodedQuery = items.joined(separator: "&")
        return components.url ?? url
    }
}
