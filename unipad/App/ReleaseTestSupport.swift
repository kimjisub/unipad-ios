#if DEBUG || UNIPAD_RELEASE_TESTS
import Foundation
import AVFoundation
import Security

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
        if UserDefaults.standard.bool(forKey: "UniPadReleaseFile"), let token {
            try removeStalePickerFixtures(keeping: token)
        }
        guard !fm.fileExists(atPath: root.path) else {
            try exposePickerArchive(in: root)
            try updateDeleteProtection(in: root)
            return
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("UniPack")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        if !UserDefaults.standard.bool(forKey: "UniPadReleaseEmpty") {
            let kind = UserDefaults.standard.string(forKey: "UniPadUITestLibrary")
            switch kind {
            case "search":
                for (folder, title, producer) in [("Faded", "Alan Walker - Faded", "Otarygen, 김지섭, K1A2"),
                                                  ("Sunflower", "Sunflower", "Post Malone"),
                                                  ("Spring", "봄날", "방탄소년단")] {
                    try makePack(at: library.appendingPathComponent(folder), title: title, producer: producer)
                }
            case "play-usage":
                let pack = library.appendingPathComponent("PlayUsage")
                try makePack(at: pack, title: "First Input Fixture", producer: "Tester")
                // Match the short, one-chain scenario pack in test-fixtures/PlayUsage.
                for (name, contents) in [
                    ("info", "title=First Input Fixture\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\nsquareButton=true\n"),
                    ("keySound", "1 1 1 silence.wav\n1 1 2 silence.wav\n1 1 3 silence.wav\n"),
                    ("autoPlay", "on 1 1\ndelay 400\non 1 2\ndelay 400\non 1 3\n"),
                ] {
                    try contents.write(to: pack.appendingPathComponent(name), atomically: true, encoding: .utf8)
                }
                try fm.removeItem(at: pack.appendingPathComponent("keyLed/1 1 1 1"))
            case "chain-layout":
                // INF-002 of the public conformance corpus: the smallest grid with the most chains.
                let small = library.appendingPathComponent("Conformance")
                try makePack(at: small, title: "Conformance")
                try "title=Conformance\nproducerName=UniPad Conformance\nbuttonX=4\nbuttonY=3\nchain=24\nsquareButton=true"
                    .write(to: small.appendingPathComponent("info"), atomically: true, encoding: .utf8)
                try "24 1 1 a.wav".write(to: small.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
                for name in ["a.wav", "b.wav", "c.wav"] {
                    try fm.copyItem(at: small.appendingPathComponent("sounds/silence.wav"),
                                    to: small.appendingPathComponent("sounds/\(name)"))
                }
                for name in ["sounds/silence.wav", "keyLed", "autoPlay"] {
                    try fm.removeItem(at: small.appendingPathComponent(name))
                }
                // The shared Faded sample's grid and chain count, with silent sounds.
                try makePack(at: library.appendingPathComponent("Faded"), title: "Alan Walker - Faded",
                             producer: "Otarygen, 김지섭, K1A2", chains: 6)
            case "autoplay-relaunch":
                // unipadUITests/Fixtures/PlaybackStop, whose three single-pad groups the step check walks.
                try makePlaybackStopPack(at: library.appendingPathComponent("PlaybackStop"))
                // The shared Faded sample's grid and chains, silent, with a song that walks every
                // chain and ends in about 15 s so the relaunch check can wait for two full runs.
                let faded = library.appendingPathComponent("Faded")
                try makePack(at: faded, title: "Alan Walker - Faded", producer: "Otarygen, 김지섭, K1A2", chains: 6)
                let song = (1...6).map { "chain \($0)\non 1 1\ndelay 1250\noff 1 1\non 1 2\ndelay 1250\noff 1 2\n" }
                try song.joined().write(to: faded.appendingPathComponent("autoPlay"), atomically: true, encoding: .utf8)
            case "zero-duration-led":
                let pack = library.appendingPathComponent("ZeroDurationLED")
                try fm.createDirectory(at: pack.appendingPathComponent("keyLed"), withIntermediateDirectories: true)
                // Keep the public extreme-repeat fixture unchanged, including its empty sound map.
                for (name, contents) in [
                    ("info", "title=Zero Duration LED Fixture\nproducerName=Tests\nbuttonX=8\nbuttonY=8\nchain=2\n"),
                    ("keySound", ""),
                    ("keyLed/1 1 1 2147483647", "o 1 1 a 5\nf 1 1\n"),
                    ("keyLed/1 1 2 2147483647", "o 1 2 a 9\nd 0\n"),
                    ("keyLed/1 1 3 2147483647", "o 1 3 a 5\nd 10\nf 1 3\nd -20\n")
                ] {
                    try contents.write(to: pack.appendingPathComponent(name), atomically: true, encoding: .utf8)
                }
            case "deletion":
                try makePack(at: library.appendingPathComponent("Deletion"), title: "UI Test Pack")
            case "warning-sound", "warning-info", "warning-none":
                let pack = library.appendingPathComponent("Warning")
                try makePack(at: pack, title: "Warning Test", producer: "Tester")
                let metadata = kind == "warning-info" ? "" : "title=Warning Test\nproducerName=Tester\n"
                try (metadata + "buttonX=3\nbuttonY=4\nchain=1\nsquareButton=true\n")
                    .write(to: pack.appendingPathComponent("info"), atomically: true, encoding: .utf8)
                try fm.removeItem(at: pack.appendingPathComponent("autoPlay"))
                try (kind == "warning-sound" ? "1 1 1 nope.wav\n" : "1 1 1 silence.wav\n")
                    .write(to: pack.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
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
                                        ("Faded", "Faded - Tests")] {
                    let needsLongVoice = folder == "Release" && UserDefaults.standard.bool(forKey: "UniPadReleaseRepeat")
                    let repeats = needsLongVoice ? 10_000 : 0
                    let loadingLEDLines = folder == "Faded" &&
                        UserDefaults.standard.bool(forKey: "UniPadReleaseThemeLoading") ? 1_000_000 : 0
                    try makePack(at: library.appendingPathComponent(folder), title: title,
                                 firstPadRepeats: repeats, loadingLEDLines: loadingLEDLines)
                }
                try makePlaybackStopPack(at: library.appendingPathComponent("PlaybackStop"))
            }
        }
        let download = root.appendingPathComponent("download")
        try makePack(at: download, title: "Downloaded Fixture")
        if UserDefaults.standard.bool(forKey: "UniPadReleaseSlowDownload") {
            var padding = Data(count: 4 * 1024 * 1024)
            _ = padding.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            try padding.write(to: download.appendingPathComponent("padding"))
        }
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

    private static func removeStalePickerFixtures(keeping token: String) throws {
        let fm = FileManager.default
        let prefix = "ReleaseFixture-"
        let currentName = "\(prefix)\(token).zip"
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        for url in try fm.contentsOfDirectory(at: WorkspaceManager.documentsDirectory,
                                              includingPropertiesForKeys: Array(keys)) {
            let name = url.lastPathComponent
            guard name != currentName, name.hasPrefix(prefix), url.pathExtension == "zip",
                  UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))) != nil else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try fm.removeItem(at: url)
        }
    }

    /// Locks the whole isolated deletion fixture, directories after their contents, so the
    /// app's delete fails. A later launch with NO unlocks the directories before their contents.
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

    static func makePack(at root: URL, title: String, producer: String = "Tests", chains: Int = 2,
                         firstPadRepeats: Int = 0, loadingLEDLines: Int = 0) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("keyLed"), withIntermediateDirectories: true)
        try "title=\(title)\nproducerName=\(producer)\nbuttonX=8\nbuttonY=8\nchain=\(chains)\n"
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
        try writeSilence(to: root.appendingPathComponent("sounds/silence.wav"))
    }

    /// The same pack as unipadUITests/Fixtures/PlaybackStop, which checks outside the release
    /// suite read from the shared library: one chain, three single-pad groups along the top row.
    /// The first pad repeats its sound for about 100 s, so a check that taps it and then leaves
    /// still exits while the sound is playing.
    static let playbackStopFiles = [
        "info": "title=Playback Stop Fixture\nproducerName=Test\nbuttonX=8\nbuttonY=8\nchain=1\n",
        "keySound": "1 1 1 a.wav 10000\n1 1 2 a.wav 3\n",
        "autoPlay": "on 1 1\noff 1 1\ndelay 10000\non 1 2\noff 1 2\ndelay 10000\non 1 3\noff 1 3\n",
    ]

    static func makePlaybackStopPack(at root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        for (name, contents) in playbackStopFiles {
            try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try writeSilence(to: root.appendingPathComponent("sounds/a.wav"))
    }

    /// 10 ms of silence, so fixture packs never make sound.
    private static func writeSilence(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
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
    private let deliveryLock = NSLock()
    private var delivery: Task<Void, Never>?

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
            if url.host == "release.invalid", url.path == "/pack.zip",
               UserDefaults.standard.bool(forKey: "UniPadReleaseSlowDownload") {
                deliverSlowly(body, url: url)
                return
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
    private func deliverSlowly(_ body: Data, url: URL) {
        let offset = request.value(forHTTPHeaderField: "Range")
            .flatMap { Int($0.dropFirst("bytes=".count).dropLast()) } ?? 0
        let headers = ["Content-Type": "application/zip", "Accept-Ranges": "bytes", "ETag": "\"fixture\"",
                       "Content-Length": String(body.count - offset),
                       "Content-Range": "bytes \(offset)-\(body.count - 1)/\(body.count)"]
        let response = HTTPURLResponse(url: url, statusCode: offset > 0 ? 206 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        deliveryLock.withLock {
            delivery = Task { [self] in
                do {
                    var position = offset
                    while position < body.count {
                        try await Task.sleep(for: .milliseconds(400))
                        try Task.checkCancellation()
                        let end = min(position + 128 * 1024, body.count)
                        client?.urlProtocol(self, didLoad: body.subdata(in: position..<end))
                        position = end
                        if offset == 0, position >= body.count / 2,
                           UserDefaults.standard.bool(forKey: "UniPadReleaseInterruptDownload") {
                            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                            return
                        }
                    }
                    client?.urlProtocolDidFinishLoading(self)
                } catch { /* Cancellation must stop delivering bytes. */ }
            }
        }
    }

    override func stopLoading() {
        deliveryLock.withLock { delivery?.cancel(); delivery = nil }
    }
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
