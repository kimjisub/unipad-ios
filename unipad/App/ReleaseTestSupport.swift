#if DEBUG || UNIPAD_RELEASE_TESTS
import Foundation
import AVFoundation

/// Compiled only by the release-check command, never by a store/archive build.
/// Every UI test gets its own library and database. Existing simulator packs are left intact.
nonisolated enum ReleaseTestSupport {
    static var token: String? { UserDefaults.standard.string(forKey: "UniPadReleaseTest") }
    static var root: URL? {
        guard let token, UUID(uuidString: token) != nil else { return nil }
        return WorkspaceManager.documentsDirectory.appendingPathComponent("ReleaseTests/\(token)")
    }
    static var storeURL: URL? { root?.appendingPathComponent("history.sqlite") }

    static func configure(_ configuration: URLSessionConfiguration) {
        guard root != nil else { return }
        configuration.protocolClasses = [ReleaseURLProtocol.self]
    }

    @MainActor static func prepare() throws {
        guard let root else { return }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { return }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("UniPack")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        if !UserDefaults.standard.bool(forKey: "UniPadReleaseEmpty") {
            for (folder, title) in [("Release", "Release Fixture - Tests"),
                                    ("PlaybackStop", "Playback Stop Fixture"),
                                    ("Faded", "Faded - Tests")] {
                try makePack(at: library.appendingPathComponent(folder), title: title)
            }
        }
        let download = root.appendingPathComponent("download")
        try makePack(at: download, title: "Downloaded Fixture")
        let archive = root.appendingPathComponent("ReleaseFixture.zip")
        try ZipHelper.zipDirectory(source: download, destination: archive)
        // The system file picker exposes Documents, not the test's private workspace.
        if UserDefaults.standard.bool(forKey: "UniPadReleaseFile"), let token {
            try fm.copyItem(at: archive, to: WorkspaceManager.documentsDirectory.appendingPathComponent("ReleaseFixture-\(token).zip"))
        }
    }

    static func makePack(at root: URL, title: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("keyLed"), withIntermediateDirectories: true)
        try "title=\(title)\nproducerName=Tests\nbuttonX=8\nbuttonY=8\nchain=2\n"
            .write(to: root.appendingPathComponent("info"), atomically: true, encoding: .utf8)
        try "1 1 1 silence.wav 0\n1 1 2 silence.wav 0\n2 1 1 silence.wav 0\n"
            .write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        try "on 1 1 a 5\ndelay 1000\noff 1 1\n"
            .write(to: root.appendingPathComponent("keyLed/1 1 1 1"), atomically: true, encoding: .utf8)
        try "on 1 1\non 1 2\ndelay 60000\noff 1 1\noff 1 2\nchain 2\non 1 1\ndelay 60000\noff 1 1\n"
            .write(to: root.appendingPathComponent("autoPlay"), atomically: true, encoding: .utf8)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: root.appendingPathComponent("sounds/silence.wav"), settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = 0 }
        }
        try file.write(from: buffer)
    }
}

/// Fail closed: an unexpected request fails the test instead of reaching a live server.
private final class ReleaseURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url, let root = ReleaseTestSupport.root else {
                throw URLError(.badURL)
            }
            let zip = try Data(contentsOf: root.appendingPathComponent("ReleaseFixture.zip"))
            let body: Data
            let contentType: String
            switch (url.host, url.path) {
            case ("api.unipad.io", "/unishare/release-test"):
                body = try JSONSerialization.data(withJSONObject: ["_id": "release-test", "title": "Downloaded Fixture", "producer": "Tests", "fileSize": zip.count])
                contentType = "application/json"
            case ("api.unipad.io", "/unishare/release-test/download"), ("release.invalid", "/pack.zip"):
                body = zip
                contentType = "application/zip"
            default: throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": contentType, "Content-Length": String(body.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

nonisolated struct ReleaseStore: FirestoreServiceProtocol {
    func fetchStoreItems() async throws -> [FirestoreStoreItem] {
        (0..<40).map { index in
            FirestoreStoreItem(id: index == 0 ? "release-test" : "release-test-\(index)",
                               title: index == 0 ? "Downloaded Fixture" : "Store Fixture \(index)", producer: "Tests",
                               downloadURL: "https://release.invalid/pack.zip", fileSize: 0,
                               downloadCount: 0, isLED: true, isAutoPlay: true, timestamp: nil)
        }
    }
    func fetchStoreItemCount() async throws -> Int { 40 }
    func incrementDownloadCount(for itemId: String) async throws {}
}
#endif
