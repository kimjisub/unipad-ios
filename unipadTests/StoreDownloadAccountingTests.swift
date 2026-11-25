import Foundation
import Testing
@testable import unipad

@MainActor
struct StoreDownloadAccountingTests {
    @Test func durableQueueLimitsAndExpiry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DownloadAccountingChecks.run(in: root)
    }

    actor Accounting: DownloadAccounting {
        var issued: [String] = []
        var savedCodes: [String] = []
        var installedWhenSaved = false
        let installedFolder: URL
        let receiptAvailable: Bool
        init(_ folder: URL, receiptAvailable: Bool) {
            installedFolder = folder
            self.receiptAvailable = receiptAvailable
        }
        func issueReceipt(code: String) -> DownloadReceipt? {
            issued.append(code)
            guard receiptAvailable else { return nil }
            return DownloadReceipt(receipt: "receipt-\(issued.count)", expiresAt: Date() + 1000)
        }
        func saved(code: String, receipt: DownloadReceipt, at completion: Date) {
            savedCodes.append(code)
            installedWhenSaved = FileManager.default.fileExists(atPath: installedFolder.appendingPathComponent("info").path)
        }
    }

    @Test(arguments: [true, false])
    func onlyPublishedPacksSendCompletionAndTheDisplayedCountIsUnchanged(receiptAvailable: Bool) async throws {
        let code = "accounting-\(UUID().uuidString)"
        let host = "\(code).test"
        let folder = WorkspaceManager.shared.downloadWorkspace.url.appendingPathComponent(code)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(code)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            StubURLProtocol.remove(host: host)
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: staging)
        }
        let accounting = Accounting(folder, receiptAvailable: receiptAvailable)
        let vm = StoreViewModel(accounting: accounting) {
            UniPackDownloader(session: session, stagingRoot: staging, waitBeforeRetry: { _ in })
        }
        vm.storeItems = [.init(id: code, title: "Accounting", producerName: "Test",
                              downloadURL: "https://\(host)/pack.zip", downloadCount: 123,
                              isLED: false, isAutoPlay: false, downloaded: false)]
        StubURLProtocol.register(host: host, .init(status: 200, chunks: [Data("broken zip".utf8)]))
        vm.startDownload(vm.storeItems[0])
        try await wait { !vm.storeItems[0].downloading }
        #expect(vm.storeItems[0].downloadFailed)
        #expect(await accounting.savedCodes.isEmpty)
        let zip = TestZip.stored([
            ("info", Data("title=Accounting\nproducerName=Test\nbuttonX=8\nbuttonY=8\nchain=1\n".utf8)),
            ("keySound", Data("1 1 1 a.wav\n".utf8)),
            ("sounds/a.wav", Data(repeating: 0, count: 8192))
        ])
        StubURLProtocol.register(host: host, .init(status: 200, chunks: [zip]))
        vm.startDownload(vm.storeItems[0])
        try await wait { !vm.storeItems[0].downloading }
        if receiptAvailable {
            let deadline = ContinuousClock.now + .seconds(10)
            while await accounting.savedCodes.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        }
        #expect(vm.storeItems[0].downloaded)
        #expect(vm.storeItems[0].downloadCount == 123)
        #expect(await accounting.issued == [code, code])
        #expect(await accounting.savedCodes == (receiptAvailable ? [code] : []))
        #expect(await accounting.installedWhenSaved == receiptAvailable)
    }

    @Test func productionRequiresAllInstallationChecks() {
        for bits in 0..<32 {
            #expect(DownloadAccountingInstallation.allowed(development: bits & 1 != 0,
                simulator: bits & 2 != 0, verified: bits & 4 != 0,
                production: bits & 8 != 0, bundleMatches: bits & 16 != 0) == (bits == 28))
        }
    }

    @Test func failedPublicationDoesNotSendCompletion() async throws {
        // A valid archive cannot be published under a name longer than a file-system component.
        let code = String(repeating: "a", count: 300)
        let host = "accounting-\(UUID().uuidString).test"
        let folder = WorkspaceManager.shared.downloadWorkspace.url.appendingPathComponent(code)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            StubURLProtocol.remove(host: host)
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: staging)
        }
        let accounting = Accounting(folder, receiptAvailable: true)
        let vm = StoreViewModel(accounting: accounting) {
            UniPackDownloader(session: session, stagingRoot: staging, waitBeforeRetry: { _ in })
        }
        vm.storeItems = [.init(id: code, title: "Accounting", producerName: "Test",
                              downloadURL: "https://\(host)/pack.zip", downloadCount: 123,
                              isLED: false, isAutoPlay: false, downloaded: false)]
        let zip = TestZip.stored([
            ("info", Data("title=Accounting\nproducerName=Test\nbuttonX=8\nbuttonY=8\nchain=1\n".utf8)),
            ("keySound", Data("1 1 1 a.wav\n".utf8)),
            ("sounds/a.wav", Data(repeating: 0, count: 8192))
        ])
        StubURLProtocol.register(host: host, .init(status: 200, chunks: [zip]))
        vm.startDownload(vm.storeItems[0])
        try await wait { !vm.storeItems[0].downloading }
        #expect(vm.storeItems[0].downloadFailed)
        #expect(!vm.storeItems[0].downloaded)
        #expect(vm.storeItems[0].downloadCount == 123)
        #expect(await accounting.issued == [code])
        #expect(await accounting.savedCodes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func legacyFallbackResolvesWithHeadAndNeverGetsTheCountingAddress() async throws {
        let host = "us-central1-unipad-e41ab.cloudfunctions.net"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { StubURLProtocol.remove(host: host); session.invalidateAndCancel() }
        StubURLProtocol.register(host: host, .init(status: 302, chunks: [],
            headers: ["Location": "https://packs.example/pack.zip"]))
        let resolved = try await StoreDownloadURL.resolve("https://\(host)/downloadUniPackLegacy?code=pack", session: session)
        #expect(resolved == "https://packs.example/pack.zip")
        #expect(StubURLProtocol.requests(host: host).map(\.httpMethod) == ["HEAD"])
        _ = try await StoreDownloadURL.resolve("https://packs.example/direct.zip", session: session)
        #expect(StubURLProtocol.requests(host: host).count == 1)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
