import Foundation

/// Serves a scripted response per host: a status, body chunks delivered one by one, then either
/// success, an error, or silence until the task is cancelled or `release` ends it.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Script: Sendable {
        var status: Int
        var chunks: [Data]
        var contentLength: Int?
        var failure: URLError?
        var stallsAfterChunks = false
        var headers: [String: String] = [:]
        var failureBeforeResponse = false
    }

    enum Ending {
        case finish([Data])
        case fail(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: [Script]] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]
    nonisolated(unsafe) private static var stalled: [String: StubURLProtocol] = [:]

    static func isStalled(host: String) -> Bool {
        lock.withLock { stalled[host] != nil }
    }

    static func release(host: String, _ ending: Ending) {
        guard let loader = lock.withLock({ stalled.removeValue(forKey: host) }) else { return }
        switch ending {
        case .finish(let chunks):
            chunks.forEach { loader.client?.urlProtocol(loader, didLoad: $0) }
            loader.client?.urlProtocolDidFinishLoading(loader)
        case .fail(let error):
            lock.withLock { scripts[host] = [.init(status: 200, chunks: [], failure: error)] }
            loader.client?.urlProtocol(loader, didFailWithError: error)
        }
    }

    static func register(host: String, _ script: Script) {
        register(host: host, scripts: [script])
    }

    static func register(host: String, scripts: [Script]) {
        lock.withLock { self.scripts[host] = scripts; requests[host] = [] }
    }

    static func requests(host: String) -> [URLRequest] {
        lock.withLock { requests[host] ?? [] }
    }

    static func remove(host: String) {
        lock.withLock {
            scripts.removeValue(forKey: host)
            requests.removeValue(forKey: host)
            stalled.removeValue(forKey: host)
        }
    }

    private let deliveryLock = NSLock()
    private var failureTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { scripts[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let script = Self.lock.withLock({ () -> Script? in
                  Self.requests[host, default: []].append(request)
                  guard let script = Self.scripts[host]?.first else { return nil }
                  if (Self.scripts[host]?.count ?? 0) > 1 { Self.scripts[host]?.removeFirst() }
                  return script
              }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if script.failureBeforeResponse, let failure = script.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        var headers = ["Content-Type": "application/zip"].merging(script.headers) { _, value in value }
        if let length = script.contentLength { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in script.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if script.stallsAfterChunks {
            Self.lock.withLock { Self.stalled[host] = self }
            return
        }
        if let failure = script.failure {
            // Let URLSession deliver the body before the connection closes.
            deliveryLock.withLock {
                failureTask = Task { [self] in
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                        try Task.checkCancellation()
                        client?.urlProtocol(self, didFailWithError: failure)
                    } catch { /* A cancelled request delivers nothing further. */ }
                }
            }
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        deliveryLock.withLock { failureTask?.cancel(); failureTask = nil }
    }
}
