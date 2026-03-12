import SwiftUI

struct ImportByUrlView: View {
    @Environment(AppRouter.self) private var router
    let code: String

    @State private var titleText = ""
    @State private var messageText = ""
    @State private var infoText = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()

            VStack {
                Spacer()

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(AppColors.background1)

                    if !infoText.isEmpty {
                        Text(infoText)
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textPrimary.opacity(0.5))
                            .padding(12)
                    }

                    VStack(spacing: 8) {
                        Spacer()

                        Text(titleText)
                            .font(.system(size: 25))
                            .foregroundStyle(AppColors.textPrimary)

                        Text(messageText)
                            .font(.system(size: 18))
                            .foregroundStyle(AppColors.textPrimary)
                            .multilineTextAlignment(.center)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                }
                .frame(width: 300, height: 200)

                Spacer()
            }
        }
        .platformNavigationBarHidden(true)
        .task {
            await startImport()
        }
    }

    // MARK: - Import Logic

    private func startImport() async {
        titleText = String(localized: "wait_a_sec")
        messageText = code
        log("code: \(code)")

        let api = UniPadAPI.shared
        let workspaceManager = WorkspaceManager.shared

        do {
            log("Fetching unishare info...")
            let unishare = try await api.getUnishare(code: code)

            let title = unishare.title ?? code
            titleText = title
            messageText = unishare.producer ?? ""
            log("title: \(title), producer: \(unishare.producer ?? "")")

            guard let unishareId = unishare.id else {
                titleText = String(localized: "errOccur")
                messageText = "Invalid unishare ID"
                try? await Task.sleep(for: .seconds(3))
                router.pop()
                return
            }

            let downloadURL = "https://api.unipad.io/unishare/\(unishareId)/download"
            let workspace = workspaceManager.downloadWorkspace.url

            titleText = String(localized: "downloading")
            messageText = "0%"
            log("Downloading from: \(downloadURL)")

            let downloader = UniPackDownloader()

            await downloader.download(
                title: title,
                url: downloadURL,
                workspace: workspace,
                folderName: title,
                preKnownFileSize: unishare.fileSize,
                delegate: ImportDelegate(
                    onProgress: { percent, dlMB, totalMB in
                        Task { @MainActor in
                            messageText = "\(percent)%\n\(dlMB) / \(totalMB) MB"
                        }
                    },
                    onImportStart: {
                        Task { @MainActor in
                            titleText = String(localized: "importing")
                            messageText = "#\(code) \(unishare.title ?? "") \(unishare.producer ?? "")"
                        }
                    },
                    onComplete: { folder in
                        Task { @MainActor in
                            titleText = String(localized: "success")
                            let pack = UniPackFolder(rootFolder: folder)
                            pack.load()
                            messageText = pack.infoString()
                            log("Installed to: \(folder.path)")
                            try? await Task.sleep(for: .seconds(3))
                            router.pop()
                        }
                    },
                    onError: { error in
                        Task { @MainActor in
                            titleText = String(localized: "errOccur")
                            messageText = error.localizedDescription
                            log("Error: \(error.localizedDescription)")
                            try? await Task.sleep(for: .seconds(3))
                            router.pop()
                        }
                    }
                )
            )

        } catch let apiError as APIError where apiError.isNotFound {
            titleText = String(localized: "unipackNotFound")
            messageText = "#\(code)"
            log("404 Not Found")
            try? await Task.sleep(for: .seconds(3))
            router.pop()
        } catch {
            titleText = String(localized: "errOccur")
            messageText = error.localizedDescription
            log("Error: \(error.localizedDescription)")
            try? await Task.sleep(for: .seconds(3))
            router.pop()
        }
    }

    private func log(_ msg: String) {
        infoText += msg + "\n"
    }
}

// MARK: - Import Delegate

private final class ImportDelegate: UniPackDownloader.Delegate, @unchecked Sendable {
    let onProgress: (Int, String, String) -> Void
    let onImportStartCb: () -> Void
    let onCompleteCb: (URL) -> Void
    let onErrorCb: (Error) -> Void

    init(
        onProgress: @escaping (Int, String, String) -> Void,
        onImportStart: @escaping () -> Void,
        onComplete: @escaping (URL) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onProgress = onProgress
        self.onImportStartCb = onImportStart
        self.onCompleteCb = onComplete
        self.onErrorCb = onError
    }

    @MainActor func onInstallStart() {}
    @MainActor func onGetFileSize(fileSize: Int64, contentLength: Int64, preKnownFileSize: Int64) {}

    @MainActor func onDownloadProgress(percent: Int, downloadedSize: Int64, fileSize: Int64) {
        let dlMB = String(format: "%.2f", Double(downloadedSize) / 1_048_576.0)
        let totalMB = String(format: "%.2f", Double(fileSize) / 1_048_576.0)
        onProgress(percent, dlMB, totalMB)
    }

    @MainActor func onImportStart() {
        onImportStartCb()
    }

    @MainActor func onInstallComplete(folder: URL) {
        onCompleteCb(folder)
    }

    @MainActor func onError(_ error: Error) {
        onErrorCb(error)
    }
}
