import SwiftUI

struct ImportByUrlView: View {
    @Environment(AppRouter.self) private var router
    let code: String

    @State private var titleText = ""
    @State private var messageText = ""
    @State private var infoText = ""

    /// The pack a `unipad://` link wants to install, held while the user decides.
    ///
    /// The link used to run straight from the metadata response into the download,
    /// so anything able to open a URL on this device could make the app fetch and
    /// unpack a file with no say from the person holding it. The metadata call has
    /// already returned by the time this is set, which is why the question can name
    /// the pack instead of asking about an anonymous download.
    @State private var pendingInstall: UnishareVO?

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

                        if let pending = pendingInstall {
                            Text(String(localized: "import_pack_confirm"))
                                .font(.system(size: 14))
                                .foregroundStyle(AppColors.textPrimary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 12)

                            HStack(spacing: 8) {
                                Button(String(localized: "cancel")) {
                                    pendingInstall = nil
                                    router.pop()
                                }
                                Button(String(localized: "accept")) {
                                    pendingInstall = nil
                                    Task { await performInstall(pending) }
                                }
                            }
                            .foregroundStyle(AppColors.blue)
                            .padding(.top, 8)
                        }

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

        do {
            log("Fetching unishare info...")
            let unishare = try await api.getUnishare(code: code)

            let title = unishare.title ?? code
            titleText = title
            messageText = unishare.producer ?? ""
            log("title: \(title), producer: \(unishare.producer ?? "")")

            guard unishare.id != nil else {
                titleText = String(localized: "errOccur")
                messageText = "Invalid unishare ID"
                try? await Task.sleep(for: .seconds(3))
                router.pop()
                return
            }

            // Ask first. performInstall runs from the button, not from here.
            infoText = String(format: String(localized: "import_pack_confirm_source"), Self.unishareHost)
            pendingInstall = unishare
            return
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

    /// Shown with the question so the person can see where the file comes from.
    private static let unishareHost = "api.unipad.io"

    private func performInstall(_ unishare: UnishareVO) async {
        guard let unishareId = unishare.id else { return }
        let workspaceManager = WorkspaceManager.shared
        let title = unishare.title ?? code
        infoText = ""

        do {
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
