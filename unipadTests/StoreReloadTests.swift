import Foundation
import os
import Testing
@testable import unipad

/// The store reads its list again each time its screen shows, including when a screen opened over it
/// (the device screen from the connection banner, a play link) closes. Reading it again must not
/// forget a download that is running or failed, nor the selected row.
@MainActor
struct StoreReloadTests {
    private final class ScriptedStore: FirestoreServiceProtocol {
        private let results: OSAllocatedUnfairLock<[Result<[FirestoreStoreItem], URLError>]>

        init(_ results: [Result<[FirestoreStoreItem], URLError>]) {
            self.results = OSAllocatedUnfairLock(initialState: results)
        }

        func fetchStoreItems() async throws -> [FirestoreStoreItem] {
            let result = results.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
            return try result.get()
        }

        func fetchStoreItemCount() async throws -> Int { 0 }
        func incrementDownloadCount(for itemId: String) async throws {}
    }

    private let stagingRoot: URL
    private let session: URLSession
    private let host = "stub-\(UUID().uuidString.lowercased()).test"
    private let packId = "store-reload-\(UUID().uuidString)"
    private let otherId = "store-reload-other-\(UUID().uuidString)"

    init() {
        stagingRoot = FileManager.default.temporaryDirectory
            .appending(path: "StoreReloadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    private func cleanUp() {
        StubURLProtocol.remove(host: host)
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    private var listing: [FirestoreStoreItem] {
        [packId, otherId].map {
            FirestoreStoreItem(id: $0, title: $0, producer: "Tests", downloadURL: "https://\(host)/pack.zip",
                               fileSize: 0, downloadCount: 0, isLED: false, isAutoPlay: false, timestamp: nil)
        }
    }

    private func makeViewModel(_ results: [Result<[FirestoreStoreItem], URLError>]) -> StoreViewModel {
        StoreViewModel(store: ScriptedStore(results)) { [session, stagingRoot] in
            UniPackDownloader(session: session, stagingRoot: stagingRoot, waitBeforeRetry: { _ in })
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func load(_ vm: StoreViewModel) async throws {
        vm.loadStore()
        try await waitUntil { !vm.isLoading }
    }

    private func row(_ vm: StoreViewModel) throws -> StoreViewModel.StoreItem {
        try #require(vm.storeItems.first { $0.id == packId })
    }

    /// Selects the pack and starts its download, which then waits on the server until released.
    private func startStalledDownload(_ vm: StoreViewModel) async throws {
        StubURLProtocol.register(host: host, .init(status: 200, chunks: [], contentLength: 1024, stallsAfterChunks: true))
        try await load(vm)
        vm.toggleSelection(try row(vm))
        vm.startDownload(try row(vm))
        try await waitUntil { StubURLProtocol.isStalled(host: host) }
    }

    private func endDownload(_ vm: StoreViewModel) async throws {
        StubURLProtocol.release(host: host, .fail(URLError(.networkConnectionLost)))
        try await waitUntil { !vm.storeItems.contains { $0.downloading } }
    }

    @Test func showingTheStoreAgainKeepsTheRunningDownload() async throws {
        defer { cleanUp() }
        let vm = makeViewModel([.success(listing)])
        try await startStalledDownload(vm)
        let before = try row(vm)

        try await load(vm)

        let after = try row(vm)
        #expect(after.downloading, "the running download is no longer shown")
        #expect(after.playText == before.playText)
        #expect(after.flagColorOverride == before.flagColorOverride)
        #expect(vm.selectedItem?.id == packId)
        #expect(vm.storeItems.contains { $0.downloading }, "the back button no longer sees a running download")

        vm.startDownload(after)
        try await Task.sleep(for: .milliseconds(300))
        #expect(StubURLProtocol.requests(host: host).count == 1, "a second download of the same pack started")

        try await endDownload(vm)
    }

    @Test func failingToReadTheListAgainKeepsTheRunningDownload() async throws {
        defer { cleanUp() }
        let vm = makeViewModel([.success(listing), .failure(URLError(.notConnectedToInternet))])
        try await startStalledDownload(vm)

        try await load(vm)

        #expect(vm.storeItems.map(\.id) == [packId, otherId])
        #expect(try row(vm).downloading)
        #expect(vm.selectedItem?.id == packId)

        try await endDownload(vm)
    }

    @Test func showingTheStoreAgainKeepsTheFailedMark() async throws {
        defer { cleanUp() }
        StubURLProtocol.register(host: host, .init(status: 404, chunks: []))
        let vm = makeViewModel([.success(listing)])
        try await load(vm)
        vm.toggleSelection(try row(vm))
        vm.startDownload(try row(vm))
        try await waitUntil { (try? row(vm).downloadFailed) == true }

        try await load(vm)

        let after = try row(vm)
        #expect(after.downloadFailed)
        #expect(after.listFlagText == String(localized: "failed"))
        #expect(after.flagColorOverride == AppColors.red)
        #expect(vm.selectedItem?.id == packId)
    }
}
