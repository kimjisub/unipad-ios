import SwiftUI

@Observable
final class StoreViewModel {

    struct StoreItem: Identifiable {
        let id: String
        var title: String
        var producerName: String
        var downloadURL: String = ""
        var fileSize: Int64 = 0
        var downloadCount: Int
        var isLED: Bool
        var isAutoPlay: Bool
        var downloaded: Bool
        var downloading: Bool = false
        var isToggle: Bool = false
        var playText: String = ""
        var flagColorOverride: Color?
    }

    var storeItems: [StoreItem] = []
    var isLoading = true

    var selectedItem: StoreItem? {
        storeItems.first { $0.isToggle }
    }

    var downloadedCount: Int {
        storeItems.filter(\.downloaded).count
    }

    // MARK: - Actions

    private let firebaseManager = FirebaseManager.shared
    private let workspaceManager = WorkspaceManager.shared

    func loadStore() {
        isLoading = true
        Task { @MainActor in
            do {
                let firestoreItems = try await firebaseManager.firestore.fetchStoreItems()

                let downloadedPackIds = Set(
                    workspaceManager.getUnipackFolders(workspace: workspaceManager.downloadWorkspace)
                        .compactMap { folderURL -> String? in
                            let pack = UniPackFolder(rootFolder: folderURL)
                            pack.load()
                            return pack.id
                        }
                )

                storeItems = firestoreItems.map { item in
                    let isDownloaded = downloadedPackIds.contains(item.id)
                    return StoreItem(
                        id: item.id,
                        title: item.title,
                        producerName: item.producer,
                        downloadURL: item.downloadURL,
                        fileSize: item.fileSize,
                        downloadCount: item.downloadCount,
                        isLED: item.isLED,
                        isAutoPlay: item.isAutoPlay,
                        downloaded: isDownloaded,
                        playText: isDownloaded ? String(localized: "downloaded") : "",
                        flagColorOverride: isDownloaded ? Color(hex: 0x66BB6A) : nil
                    )
                }
            } catch {
                storeItems = []
            }
            isLoading = false
        }
    }

    func toggleSelection(_ item: StoreItem) {
        for i in storeItems.indices {
            if storeItems[i].id == item.id {
                storeItems[i].isToggle.toggle()
            } else {
                storeItems[i].isToggle = false
            }
        }
    }

    func startDownload(_ item: StoreItem) {
        guard let index = storeItems.firstIndex(where: { $0.id == item.id }) else { return }
        guard !storeItems[index].downloaded, !storeItems[index].downloading else { return }

        storeItems[index].downloading = true
        storeItems[index].flagColorOverride = Color(hex: 0xA6B4C9)
        storeItems[index].playText = "0%"

        let itemId = item.id
        let title = item.title
        let downloadURL = item.downloadURL
        let fileSize = item.fileSize
        let workspace = workspaceManager.downloadWorkspace.url

        Task {
            let downloader = UniPackDownloader()
            let delegate = StoreDownloadDelegate(viewModel: self, itemId: itemId)
            await downloader.download(
                title: title,
                url: downloadURL,
                workspace: workspace,
                folderName: itemId,
                preKnownFileSize: fileSize,
                delegate: delegate
            )
        }
    }

    func openYouTubeSearch(for item: StoreItem) {
        let query = "UniPad \(item.title) \(item.producerName)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://www.youtube.com/results?search_query=\(query)") {
            PlatformHelpers.openURL(url)
        }
    }
}

// MARK: - Store Download Delegate

private final class StoreDownloadDelegate: UniPackDownloader.Delegate, @unchecked Sendable {
    private weak var viewModel: StoreViewModel?
    private let itemId: String

    init(viewModel: StoreViewModel, itemId: String) {
        self.viewModel = viewModel
        self.itemId = itemId
    }

    private func updateItem(_ block: (inout StoreViewModel.StoreItem) -> Void) {
        guard let vm = viewModel,
              let index = vm.storeItems.firstIndex(where: { $0.id == itemId }) else { return }
        block(&vm.storeItems[index])
    }

    @MainActor func onInstallStart() {
        updateItem { $0.playText = String(localized: "downloading") }
    }

    @MainActor func onGetFileSize(fileSize: Int64, contentLength: Int64, preKnownFileSize: Int64) {}

    @MainActor func onDownloadProgress(percent: Int, downloadedSize: Int64, fileSize: Int64) {
        let dlMB = String(format: "%.1f", Double(downloadedSize) / 1_048_576.0)
        let totalMB = String(format: "%.1f", Double(fileSize) / 1_048_576.0)
        updateItem { $0.playText = "\(percent)% (\(dlMB)/\(totalMB)MB)" }
    }

    @MainActor func onImportStart() {
        updateItem {
            $0.playText = String(localized: "importing")
            $0.flagColorOverride = Color(hex: 0xFF9800)
        }
    }

    @MainActor func onInstallComplete(folder: URL) {
        updateItem {
            $0.downloading = false
            $0.downloaded = true
            $0.playText = String(localized: "downloaded")
            $0.flagColorOverride = Color(hex: 0x66BB6A)
        }
    }

    @MainActor func onError(_ error: Error) {
        updateItem {
            $0.downloading = false
            $0.playText = String(localized: "failed")
            $0.flagColorOverride = Color(hex: 0xFF6B4E)
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
