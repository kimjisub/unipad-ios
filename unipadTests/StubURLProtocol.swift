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
    }

    enum Ending {
        case finish([Data])
        case fail(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
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
            loader.client?.urlProtocol(loader, didFailWithError: error)
        }
    }

    static func register(host: String, _ script: Script) {
        lock.withLock { scripts[host] = script }
    }

    static func remove(host: String) {
        lock.withLock {
            scripts.removeValue(forKey: host)
            stalled.removeValue(forKey: host)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { scripts[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let script = Self.lock.withLock({ Self.scripts[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var headers: [String: String] = [:]
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
            client?.urlProtocol(self, didFailWithError: failure)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
