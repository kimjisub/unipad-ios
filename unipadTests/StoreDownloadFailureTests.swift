import Foundation
import Testing
@testable import unipad

/// A store download that fails (file gone from the server, connection lost) leaves its row marked
/// failed until the user starts the next attempt, which clears the mark and downloads again.
@MainActor
struct StoreDownloadFailureTests {
    private let stagingRoot: URL
    private let session: URLSession
    private let host = "stub-\(UUID().uuidString.lowercased()).test"

    init() {
        stagingRoot = FileManager.default.temporaryDirectory
            .appending(path: "StoreDownloadFailureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    private func cleanUp() {
        StubURLProtocol.remove(host: host)
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    private func makeViewModel() -> StoreViewModel {
        let vm = StoreViewModel { [session, stagingRoot] in
            UniPackDownloader(session: session, stagingRoot: stagingRoot, waitBeforeRetry: { _ in })
        }
        vm.storeItems = [StoreViewModel.StoreItem(
            id: "missing", title: "Missing", producerName: "Tests",
            downloadURL: "https://\(host)/pack.zip", downloadCount: 0,
            isLED: false, isAutoPlay: false, downloaded: false, isToggle: true
        )]
        return vm
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func failedDownloadStaysMarkedUntilTheNextAttempt() async throws {
        defer { cleanUp() }
        StubURLProtocol.register(host: host, .init(status: 404, chunks: []))
        let vm = makeViewModel()

        vm.startDownload(vm.storeItems[0])
        try await waitUntil { !vm.storeItems[0].downloading }

        var item = vm.storeItems[0]
        #expect(item.downloadFailed)
        #expect(!item.downloaded)
        #expect(item.listFlagText == String(localized: "failed"))
        #expect(item.flagColorOverride == AppColors.red)

        StubURLProtocol.register(host: host, .init(status: 200, chunks: [], contentLength: 1024, stallsAfterChunks: true))
        vm.startDownload(item)

        item = vm.storeItems[0]
        #expect(item.downloading)
        #expect(!item.downloadFailed)
        #expect(item.listFlagText != String(localized: "failed"))

        try await waitUntil { StubURLProtocol.isStalled(host: host) }
        StubURLProtocol.release(host: host, .fail(URLError(.networkConnectionLost)))
        try await waitUntil { !vm.storeItems[0].downloading }

        item = vm.storeItems[0]
        #expect(item.downloadFailed)
        #expect(item.listFlagText == String(localized: "failed"))
    }
}
