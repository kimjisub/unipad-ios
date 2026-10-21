import Foundation
import Testing
@testable import unipad

@Suite(.serialized)
struct AppStoreLookupTests {
    private let host = "itunes.apple.com"

    @Test func sendsOnlyTheAppIDAndActualCountryWithNoHTTPCache() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = AppStoreLookupClient(configuration: configuration)
        defer { StubURLProtocol.remove(host: host) }
        let data = Data(#"{"resultCount":0,"results":[]}"#.utf8)
        StubURLProtocol.register(host: host, .init(status: 200, chunks: [data]))
        #expect(try await client.lookup(country: "KR") == data)
        let request = try #require(StubURLProtocol.requests(host: host).first)
        #expect(request.url?.absoluteString == "https://itunes.apple.com/lookup?id=6760479102&country=KR")
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(request.timeoutInterval == 10)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func rejectsHTTPFailuresIncludingRateLimiting() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = AppStoreLookupClient(configuration: configuration)
        defer { StubURLProtocol.remove(host: host) }
        for status in [204, 404, 429, 500] {
            StubURLProtocol.register(host: host, .init(status: status, chunks: [Data("{}".utf8)]))
            await #expect(throws: (any Error).self) { try await client.lookup(country: "KR") }
        }
    }

    @Test(.timeLimit(.minutes(1))) func timesOutARequestThatNeverCompletes() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = AppStoreLookupClient(configuration: configuration)
        defer { StubURLProtocol.remove(host: host) }
        StubURLProtocol.register(host: host, .init(status: 200, chunks: [], stallsAfterChunks: true))
        let started = ContinuousClock.now
        let error = await #expect(throws: URLError.self) { try await client.lookup(country: "KR") }
        #expect(error?.code == .timedOut)
        #expect(started.duration(to: .now) >= .seconds(9))
    }

    @Test func propagatesOfflineAndCancelledRequests() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = AppStoreLookupClient(configuration: configuration)
        defer { StubURLProtocol.remove(host: host) }
        for code: URLError.Code in [.notConnectedToInternet, .cancelled, .timedOut] {
            StubURLProtocol.register(host: host, .init(status: 200, chunks: [], failure: URLError(code),
                                                     failureBeforeResponse: true))
            await #expect(throws: (any Error).self) { try await client.lookup(country: "KR") }
        }
    }
}
