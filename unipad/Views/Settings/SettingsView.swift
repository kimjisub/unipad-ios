import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppRouter.self) private var router
    @State private var vm = SettingsViewModel()
    @State private var showCommunityDialog = false
    @State private var showBackupShareSheet = false
    @State private var backupFileURL: URL?
    @State private var showRestorePicker = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showRestoreGuideAlert = false

    var initialCategory: SettingsViewModel.Category = .info

    var body: some View {
        HStack(spacing: 0) {
            categoryNav
                .frame(width: 220)

            contentArea
                .frame(maxWidth: .infinity)
        }
        .background(AppColors.background1)
        .platformNavigationBarHidden(true)
        .onAppear {
            vm.selectedCategory = initialCategory
            vm.refreshStorageInfo()
        }
        .sheet(isPresented: $showCommunityDialog) {
            communitySheet
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showBackupShareSheet) {
            if let url = backupFileURL {
                ShareSheet(activityItems: [url])
            }
        }
        .sheet(isPresented: $showRestorePicker) {
            DocumentPickerView { urls in
                guard let url = urls.first else { return }
                startRestore(from: url)
            }
        }
        #endif
        .alert(String(localized: "backup_section"), isPresented: $showAlert) {
            Button(String(localized: "accept")) {}
        } message: {
            Text(alertMessage)
        }
        .alert(String(localized: "backup_guide_title"), isPresented: $showRestoreGuideAlert) {
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "backup_guide_continue")) {
                showRestorePicker = true
            }
        } message: {
            Text(
                "\(String(localized: "backup_guide_description"))\n\n" +
                "\(String(localized: "backup_guide_step1"))\n" +
                "\(String(localized: "backup_guide_step2"))\n" +
                "\(String(localized: "backup_guide_step3"))"
            )
        }
    }

    // MARK: - Category Nav

    private var categoryNav: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { router.pop() } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(AppColors.textPrimary)
                }
                .padding(.trailing, 4)

                Text(String(localized: "setting"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
            }
            .padding(.bottom, 24)

            navItem(
                icon: "info.circle",
                title: String(localized: "settings_info"),
                isSelected: vm.selectedCategory == .info
            ) {
                vm.selectedCategory = .info
            }

            navItem(
                icon: "externaldrive",
                title: String(localized: "settings_storage"),
                isSelected: vm.selectedCategory == .storage
            ) {
                vm.selectedCategory = .storage
            }

            navItem(
                icon: "paintpalette",
                title: String(localized: "settings_theme"),
                isSelected: false,
                showChevron: true
            ) {
                router.navigate(to: .theme)
            }

            Spacer()
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
        .background(AppColors.background1)
    }

    private func navItem(
        icon: String,
        title: String,
        isSelected: Bool,
        showChevron: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? AppColors.blue : AppColors.textSecondary)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textSecondary)
                if showChevron {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppColors.navItemSelected : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        switch vm.selectedCategory {
        case .info:
            infoContent
        case .storage:
            storageContent
        }
    }

    // MARK: - Info Content

    private var infoContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Device
                sectionLabel(String(localized: "settings_device"))
                settingsCard {
                    settingsRow(title: String(localized: "reconnect_launchpad")) {
                        router.navigate(to: .midiSelect)
                    }
                }

                // App Info
                sectionLabel(String(localized: "settings_info"))
                settingsCard {
                    VStack(spacing: 0) {
                        settingsRow(title: vm.appVersionInfo, subtitle: String(localized: "copyright"))
                        cardDivider
                        settingsRow(title: String(localized: "community")) {
                            showCommunityDialog = true
                        }
                    }
                }

                // Developer
                sectionLabel(String(localized: "settings_developer"))
                settingsCard {
                    VStack(spacing: 0) {
                        settingsRow(title: String(localized: "github")) {
                            vm.openGitHub()
                        }
                        cardDivider
                        settingsRow(title: String(localized: "openSourceLicense")) {
                            vm.openURL("https://github.com/kimjisub/unipad-android/blob/main/LICENSE")
                        }
                        cardDivider
                        settingsRow(title: String(localized: "FCMToken"), subtitle: String(localized: "tap_to_copy")) {
                            Task {
                                let token = await vm.copyFcmToken()
                                alertMessage = token == String(localized: "fcm_token_unavailable")
                                    ? token
                                    : String(localized: "copied")
                                showAlert = true
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Storage Content

    private var storageContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sectionLabel(String(localized: "settings_storage"))
                settingsCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("App Storage")
                            .font(.system(size: 14))
                            .foregroundStyle(AppColors.textPrimary)
                        Text(vm.workspacePath)
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textSecondary)
                        Text("\(vm.unipackCount) UniPacks")
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textSecondary)
                        if !vm.storageUsed.isEmpty {
                            Text(vm.storageUsed)
                                .font(.system(size: 12))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                    .padding(16)
                }

                sectionLabel(String(localized: "backup_section"))
                settingsCard {
                    VStack(spacing: 0) {
                        settingsRow(title: String(localized: "backup_title"), subtitle: String(localized: "backup_description")) {
                            startBackup()
                        }
                        cardDivider
                        settingsRow(title: String(localized: "restore_title"), subtitle: String(localized: "restore_description")) {
                            showRestoreGuideAlert = true
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Community Sheet

    private var communitySheet: some View {
        NavigationStack {
            List(vm.communityLinks) { link in
                Button {
                    vm.openURL(link.url)
                    showCommunityDialog = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: link.iconName)
                            .font(.system(size: 20))
                            .foregroundStyle(AppColors.blue)
                            .frame(width: 36, height: 36)

                        VStack(alignment: .leading) {
                            Text(link.title)
                                .font(.system(size: 14))
                                .foregroundStyle(AppColors.textPrimary)
                            Text(link.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.darkSurface)
            .navigationTitle(String(localized: "community"))
            .platformNavigationBarTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("OK") { showCommunityDialog = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Reusable Components

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppColors.blue)
            .tracking(0.5)
            .padding(.leading, 4)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.darkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func settingsRow(
        title: String,
        subtitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            action?()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                Spacer()
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .disabled(action == nil)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(AppColors.divider)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    // MARK: - Backup & Restore

    private func startBackup() {
        Task {
            let workspace = WorkspaceManager.shared.downloadWorkspace
            let folders = WorkspaceManager.shared.getUnipackFolders(workspace: workspace)
            guard !folders.isEmpty else {
                alertMessage = String(localized: "backup_no_items")
                showAlert = true
                return
            }

            let fm = FileManager.default
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = dateFormatter.string(from: Date())
            let backupDir = fm.temporaryDirectory.appendingPathComponent("UniPad_Backup_\(timestamp)")

            do {
                try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                for folder in folders {
                    let dest = backupDir.appendingPathComponent(folder.lastPathComponent)
                    try FileManagerExtensions.copyDirectory(from: folder, to: dest)
                }

                backupFileURL = backupDir
                showBackupShareSheet = true
            } catch {
                alertMessage = String(localized: "backup_failed")
                showAlert = true
            }
        }
    }

    private func startRestore(from url: URL) {
        Task {
            let workspace = WorkspaceManager.shared.downloadWorkspace
            let fm = FileManager.default
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            do {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    guard let contents = try? fm.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey]
                    ) else { return }

                    for item in contents {
                        let itemIsDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        if itemIsDir {
                            let dest = FileManagerExtensions.makeNextPath(
                                dir: workspace.url,
                                name: item.lastPathComponent,
                                extension: ""
                            )
                            try FileManagerExtensions.copyDirectory(from: item, to: dest)
                        }
                    }
                } else if url.pathExtension.lowercased() == "zip" {
                    let importer = UniPackImporter()
                    await importer.importPack(from: url, to: workspace.url, delegate: nil)
                }

                alertMessage = String(localized: "restore_success")
                showAlert = true
                vm.refreshStorageInfo()
            } catch {
                alertMessage = String(localized: "restore_failed")
                showAlert = true
            }
        }
    }
}

// MARK: - UIKit Wrappers

#if canImport(UIKit)
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .zip])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
#endif
