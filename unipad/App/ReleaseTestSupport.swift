#if DEBUG || UNIPAD_RELEASE_TESTS
import Foundation
import AVFoundation

/// Compiled only in Debug or explicit release checks, never by a store/archive build.
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
        guard !fm.fileExists(atPath: root.path) else {
            try exposePickerArchive(in: root)
            try updateDeleteProtection(in: root)
            return
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("UniPack")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        if !UserDefaults.standard.bool(forKey: "UniPadReleaseEmpty") {
            switch UserDefaults.standard.string(forKey: "UniPadUITestLibrary") {
            case "search":
                for (folder, title, producer) in [("Faded", "Alan Walker - Faded", "Otarygen, 김지섭, K1A2"),
                                                  ("Sunflower", "Sunflower", "Post Malone"),
                                                  ("Spring", "봄날", "방탄소년단")] {
                    try makePack(at: library.appendingPathComponent(folder), title: title, producer: producer)
                }
            case "play-usage":
                let pack = library.appendingPathComponent("PlayUsage")
                try makePack(at: pack, title: "JIS20 First Input Fixture", producer: "Tester")
                // Match the short, one-chain scenario pack in test-fixtures/PlayUsage.
                for (name, contents) in [
                    ("info", "title=JIS20 First Input Fixture\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\nsquareButton=true\n"),
                    ("keySound", "1 1 1 silence.wav\n1 1 2 silence.wav\n1 1 3 silence.wav\n"),
                    ("autoPlay", "on 1 1\ndelay 400\non 1 2\ndelay 400\non 1 3\n"),
                ] {
                    try contents.write(to: pack.appendingPathComponent(name), atomically: true, encoding: .utf8)
                }
                try fm.removeItem(at: pack.appendingPathComponent("keyLed/1 1 1 1"))
            case "deletion":
                try makePack(at: library.appendingPathComponent("Deletion"), title: "UI Test Pack")
            case "chain-release":
                // The screen check passes the approved archive's exact bytes; staging it is the
                // direct extraction its fixture README requires, not a ZIP import.
                guard let encoded = UserDefaults.standard.string(forKey: "UniPadReleaseArchive"),
                      let archive = Data(base64Encoded: encoded) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                let file = root.appendingPathComponent("chain-release.uni")
                try archive.write(to: file)
                try fm.unzipItem(at: file, to: library.appendingPathComponent("ChainRelease"))
            default:
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
            }
        }
        let download = root.appendingPathComponent("download")
        try makePack(at: download, title: "Downloaded Fixture")
        let archive = root.appendingPathComponent("ReleaseFixture.zip")
        try ZipHelper.zipDirectory(source: download, destination: archive)
        try exposePickerArchive(in: root)
        try updateDeleteProtection(in: root)
    }

    /// Keep picker contents independent of earlier tests on a reused simulator.
    /// Only this explicit test namespace is cleared; user archives stay untouched.
    private static func exposePickerArchive(in root: URL) throws {
        guard UserDefaults.standard.bool(forKey: "UniPadReleaseFile"), let token else { return }
        let fm = FileManager.default
        let folder = WorkspaceManager.documentsDirectory.appendingPathComponent("00-ReleaseTestImports")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("ReleaseFixture-\(token).zip")
        for previous in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            if previous != destination { try fm.removeItem(at: previous) }
        }
        if !fm.fileExists(atPath: destination.path) {
            try fm.copyItem(at: root.appendingPathComponent("ReleaseFixture.zip"), to: destination)
        }
    }

    /// Protect the complete isolated deletion fixture, as the old host's recursive lock did.
    /// A subsequent launch with NO unlocks the directories before their contents.
    private static func updateDeleteProtection(in root: URL) throws {
        guard UserDefaults.standard.string(forKey: "UniPadUITestLibrary") == "deletion" else { return }
        let pack = root.appendingPathComponent("UniPack/Deletion")
        let fm = FileManager.default
        guard fm.fileExists(atPath: pack.path) else { return }
        let contents = try fm.subpathsOfDirectory(atPath: pack.path)
        var paths = [pack] + contents.map { pack.appendingPathComponent($0) }
        let protect = UserDefaults.standard.bool(forKey: "UniPadUITestDeleteFailure")
        if protect { paths.reverse() }
        for path in paths {
            try fm.setAttributes([.immutable: protect], ofItemAtPath: path.path)
        }
    }

    static func makePack(at root: URL, title: String, producer: String = "Tests", firstPadRepeats: Int = 0, loadingLEDLines: Int = 0) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("keyLed"), withIntermediateDirectories: true)
        try "title=\(title)\nproducerName=\(producer)\nbuttonX=8\nbuttonY=8\nchain=2\n"
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
