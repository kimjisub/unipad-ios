import Foundation

/// This session never reuses HTTP cache entries. Only validated, country-specific results are
/// retained by AppStoreUpdateChecker. No account credentials are sent to the public lookup API.
nonisolated final class AppStoreLookupClient: Sendable {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    func lookup(country: String) async throws -> Data {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: String(AppStoreApp.id)),
                                 URLQueryItem(name: "country", value: country)]
        let request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 10)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw AppStoreUpdateContext.LookupError.invalidResponse
        }
        return data
    }
}
