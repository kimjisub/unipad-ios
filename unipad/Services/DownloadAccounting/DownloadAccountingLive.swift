import Foundation
import StoreKit

/// Production is allowed only for a verified App Store installation, never a test override.
nonisolated enum DownloadAccountingInstallation {
    static func allowed(development: Bool, simulator: Bool, verified: Bool,
                        production: Bool, bundleMatches: Bool) -> Bool {
        !development && !simulator && verified && production && bundleMatches
    }
}

extension DownloadAccountingService {
    static let shared: DownloadAccountingService = {
        let client = DownloadAccountingHTTPClient()
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
#if DEBUG || UNIPAD_RELEASE_TESTS || targetEnvironment(simulator)
        let local = UserDefaults.standard.bool(forKey: "UniPadDownloadAccountingEmulator")
        let endpoint = local ? URL(string: "http://127.0.0.1:5051/demo-unipad/us-central1/") : nil
        let file = folder.appendingPathComponent("download-accounting-local.json")
#else
        let file = folder.appendingPathComponent("download-accounting.json")
#endif
        return DownloadAccountingService(file: file) { function, body in
#if DEBUG || UNIPAD_RELEASE_TESTS || targetEnvironment(simulator)
            guard let endpoint else { return nil }
#else
            guard let verification = try? await AppTransaction.shared,
                  case .verified(let transaction) = verification,
                  DownloadAccountingInstallation.allowed(development: false, simulator: false, verified: true,
                    production: transaction.environment == .production,
                    bundleMatches: transaction.bundleID == Bundle.main.bundleIdentifier),
                  !Task.isCancelled else { return nil }
            let endpoint = URL(string: "https://us-central1-unipad-e41ab.cloudfunctions.net/")!
#endif
            return await client.post(function, body: body, endpoint: endpoint)
        }
    }()
}

nonisolated struct DownloadAccountingHTTPClient: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    func post(_ function: String, body: [String: String], endpoint: URL) async -> Data? {
        var request = URLRequest(url: endpoint.appendingPathComponent(function), timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        guard let (data, response) = try? await session.data(for: request),
              let response = response as? HTTPURLResponse,
              [200, 400, 413, 429, 503].contains(response.statusCode), data.count <= 1_024 else { return nil }
        return data
    }
}

/// The old fallback address counts GETs before the archive is saved. Resolve it with HEAD,
/// then download the file itself so failures and resumed requests cannot increment that counter.
enum StoreDownloadURL {
    static func resolve(_ value: String, session: URLSession = .shared) async throws -> String {
        guard let url = URL(string: value), isLegacy(url) else { return value }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request, delegate: StopRedirect())
        guard let http = response as? HTTPURLResponse, (300...399).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let destination = URL(string: location, relativeTo: url)?.absoluteURL, !isLegacy(destination),
              ["https", "http"].contains(destination.scheme) else { throw URLError(.badServerResponse) }
        return destination.absoluteString
    }

    private final class StopRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                   willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                                   completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func isLegacy(_ url: URL) -> Bool {
        url.host == "us-central1-unipad-e41ab.cloudfunctions.net" && url.path == "/downloadUniPackLegacy"
    }
}
