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
                let needsLongVoice = folder == "PlaybackStop" ||
                    (folder == "Release" && UserDefaults.standard.bool(forKey: "UniPadReleaseRepeat"))
                let repeats = needsLongVoice ? 10_000 : 0
                let loadingLEDLines = folder == "Faded" &&
                    UserDefaults.standard.bool(forKey: "UniPadReleaseThemeLoading") ? 1_000_000 : 0
                try makePack(at: library.appendingPathComponent(folder), title: title,
                             firstPadRepeats: repeats, loadingLEDLines: loadingLEDLines)
            }
            if UserDefaults.standard.bool(forKey: "UniPadReleaseInputEdges") {
                try makeInputEdgePacks(in: library)
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

    /// Packs for the play screen's input edge checks. "Input Edges" loops a silent sample forever
    /// on every pad of both chains and has no LEDs, so each pressed pad shows the feedback light
    /// only while held. The "Grid" packs are one grid size with and without `squareButton`.
    static func makeInputEdgePacks(in library: URL) throws {
        let fm = FileManager.default
        let packs: [(folder: String, title: String, rows: Int, columns: Int, chains: Int, square: Bool)] = [
            ("InputEdges", "Input Edges", 8, 8, 2, true),
            ("Grid8x8Square", "Grid 8x8 square", 8, 8, 1, true),
            ("Grid8x8Rect", "Grid 8x8 rect", 8, 8, 1, false),
            ("Grid4x3Square", "Grid 4x3 square", 4, 3, 1, true),
            ("Grid4x3Rect", "Grid 4x3 rect", 4, 3, 1, false),
        ]
        for pack in packs {
            let root = library.appendingPathComponent(pack.folder)
            try makePack(at: root, title: pack.title)
            try "title=\(pack.title)\nproducerName=Tests\nbuttonX=\(pack.rows)\nbuttonY=\(pack.columns)\nchain=\(pack.chains)\nsquareButton=\(pack.square)\n"
                .write(to: root.appendingPathComponent("info"), atomically: true, encoding: .utf8)
            let keySound = (1...pack.chains).flatMap { chain in
                (1...pack.rows).flatMap { x in (1...pack.columns).map { y in "\(chain) \(x) \(y) silence.wav 0\n" } }
            }
            try keySound.joined().write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
            for name in ["keyLed", "autoPlay"] {
                try fm.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }

    static func makePack(at root: URL, title: String, firstPadRepeats: Int = 0, loadingLEDLines: Int = 0) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("keyLed"), withIntermediateDirectories: true)
        try "title=\(title)\nproducerName=Tests\nbuttonX=8\nbuttonY=8\nchain=2\n"
            .write(to: root.appendingPathComponent("info"), atomically: true, encoding: .utf8)
        try "1 1 1 silence.wav \(firstPadRepeats)\n1 1 2 silence.wav 0\n2 1 1 silence.wav 0\n"
            .write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        // Real parser work keeps the loading screen observable without sleeping in app code.
        // Only the two theme-opening checks request this larger, silent fixture.
        let loadingLED = String(repeating: "delay 1\n", count: loadingLEDLines)
        try (loadingLED + "on 1 1 a 5\ndelay 1000\noff 1 1\n")
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
            var status = 200
            let body: Data
            let contentType: String
            switch (url.host, url.path) {
            case ("api.unipad.io", "/unishare/release-test"):
                body = try JSONSerialization.data(withJSONObject: ["_id": "release-test", "title": "Downloaded Fixture", "producer": "Tests", "fileSize": zip.count])
                contentType = "application/json"
            case ("api.unipad.io", "/unishare/release-test/download"), ("release.invalid", "/pack.zip"):
                body = zip
                contentType = "application/zip"
            case ("release.invalid", "/missing.zip"):
                // A store entry whose file is gone from the server.
                status = 404
                body = Data()
                contentType = "text/html"
            default: throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
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
                               title: index == 0 ? "Downloaded Fixture" : index == 1 ? "Missing Fixture" : "Store Fixture \(index)",
                               producer: "Tests",
                               downloadURL: index == 1 ? "https://release.invalid/missing.zip" : "https://release.invalid/pack.zip",
                               fileSize: 0, downloadCount: 0, isLED: true, isAutoPlay: true, timestamp: nil)
        }
    }
    func fetchStoreItemCount() async throws -> Int { 40 }
    func incrementDownloadCount(for itemId: String) async throws {}
}
#endif
