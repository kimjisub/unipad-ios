import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @State private var vm = MainViewModel()
    @State private var showDeleteConfirmation = false
    @State private var showImportResult = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Left panel (40%)
                leftPanel
                    .frame(width: geometry.size.width * 0.4)

                // Right panel (60%)
                rightPanel
                    .frame(width: geometry.size.width * 0.6)
            }
        }
        .background(AppColors.background1)
        .platformNavigationBarHidden(true)
        .onKeyPress(.escape) {
            if vm.selectedItem != nil {
                vm.toggleSelection(vm.selectedItem!)
                return .handled
            }
            return .ignored
        }
        .onAppear {
            vm.modelContainer = modelContext.container
            vm.refreshList()
            vm.updateStats()
            vm.versionCheck()
            vm.onLaunchpadPlay = { item in
                vm.recordOpen(item)
                router.navigate(to: .play(packPath: item.unipack.getPathString()))
            }
            vm.setupMidiController()
        }
        .onDisappear {
            vm.removeMidiController()
        }
        .onChange(of: router.currentRoute) { _, currentRoute in
            if currentRoute == .main {
                vm.setupMidiController()
            }
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            vm.removeMidiController()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            vm.setupMidiController()
            vm.refreshList()
            vm.versionCheck()
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UniPadExternalFileImported"))) { _ in
            vm.isImportingInProgress = false
            vm.refreshList()
            vm.updateStats()
            showImportResult = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UniPadExternalFileImportFailed"))) { notification in
            if let errorMsg = notification.userInfo?["error"] as? String {
                vm.importResult = .error(errorMsg)
            }
            showImportResult = true
        }
        .fileImporter(
            isPresented: Binding(
                get: { vm.isImporting },
                set: { vm.isImporting = $0 }
            ),
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }

                guard url.startAccessingSecurityScopedResource() else {
                    UsageAnalytics.shared.packImportFailed(source: .file, error: CocoaError(.fileReadNoPermission))
                    vm.importResult = .error(String(localized: "import_no_file_access"))
                    showImportResult = true
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }

                do {
                    let zipData = try Data(contentsOf: url)
                    let fileName = url.lastPathComponent

                    vm.isImportingInProgress = true

                    Task {
                        let workspace = WorkspaceManager.shared.downloadWorkspace.url
                        let importer = UniPackImporter()
                        let delegate = MainViewImportDelegate(viewModel: vm)
                        // The delegate already shows the error; the thrown value is only reported.
                        var importedFolder: URL?
                        do {
                            importedFolder = try await importer.importPack(data: zipData, fileName: fileName, to: workspace, delegate: delegate)
                            UsageAnalytics.shared.packImportSucceeded(source: .file)
                        } catch {
                            UsageAnalytics.shared.packImportFailed(source: .file, error: error)
                        }

                        await MainActor.run {
                            vm.isImportingInProgress = false
                            vm.refreshList()
                            vm.updateStats()
                            if let importedFolder {
                                vm.showImportResult(forImportedFolder: importedFolder)
                            }
                            showImportResult = true
                        }
                    }
                } catch {
                    UsageAnalytics.shared.packImportFailed(source: .file, error: error)
                    vm.importResult = .error(error.localizedDescription)
                    showImportResult = true
                }
            case .failure(let error):
                UsageAnalytics.shared.packImportFailed(source: .file, error: error)
                vm.importResult = .error(error.localizedDescription)
                showImportResult = true
            }
        }
        .alert(String(localized: "warning"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "accept"), role: .destructive) {
                if let item = vm.deleteTargetItem {
                    vm.deleteItem(item)
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {
                vm.deleteTargetItem = nil
            }
        } message: {
            Text(String(localized: "doYouWantToDeleteUniPack"))
        }
        .alert(String(localized: "error"), isPresented: $vm.deleteFailed) {
            Button("OK") {}
        } message: {
            Text(String(localized: "errOccur"))
        }
        .overlay {
            if showImportResult, let result = vm.importResult {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                        .onTapGesture {
                            dismissImportResult()
                        }

                    ImportResultDialog(
                        result: result,
                        onDismiss: dismissImportResult,
                        onPlayNow: playImportedPack
                    )
                }
            }
        }
        .overlay {
            if vm.isImportingInProgress {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.5)
                        Text(String(localized: "importing"))
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    }
                    .padding(32)
                    .background(AppColors.darkSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func dismissImportResult() {
        showImportResult = false
        vm.importResult = nil
    }

    private func playImportedPack(_ unipack: UniPack) {
        dismissImportResult()
        vm.recordOpen(unipack)
        router.navigate(to: .play(packPath: unipack.getPathString()))
    }

    // MARK: - Left Panel

    @ViewBuilder
    private var leftPanel: some View {
        let _ = vm.detailLoadVersion
        VStack {
            Group {
                if let selected = vm.selectedItem {
                    MainPackPanel(
                        item: selected,
                        onBookmarkToggle: { vm.toggleBookmark(selected) },
                        onDelete: {
                            vm.deleteTargetItem = selected
                            showDeleteConfirmation = true
                        },
                        onYouTube: {
                            let query = "UniPad \(selected.unipack.title) \(selected.unipack.producerName)"
                                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                            if let url = URL(string: "https://www.youtube.com/results?search_query=\(query)") {
                                PlatformHelpers.openURL(url)
                            }
                        },
                        onWebsite: selected.unipack.website.flatMap { urlString in
                            { if let url = URL(string: urlString) { PlatformHelpers.openURL(url) } }
                        }
                    )
                    .transition(.opacity)
                } else {
                    MainTotalPanel(
                        openCount: vm.totalOpenCount,
                        unipackCount: vm.unipackCount,
                        unipackCapacity: vm.unipackCapacity,
                        themeName: vm.currentThemeName,
                        updateAvailable: vm.updateAvailable,
                        onSettingsClick: { router.navigate(to: .settings) },
                        onUpdateClick: { PlatformHelpers.openURL(Self.appStoreURL) }
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: vm.selectedItem?.id)
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 0))
    }

    // MARK: - Right Panel

    @ViewBuilder
    private var rightPanel: some View {
        VStack(spacing: 0) {
            if vm.unipackItems.isEmpty && !vm.isRefreshing && vm.searchQuery.isEmpty {
                emptyStateView
            } else {
                sortBar
                if vm.unipackItems.isEmpty && !vm.searchQuery.isEmpty {
                    searchEmptyView
                } else {
                    packList
                }
            }
        }
    }

    // MARK: - Sort Bar

    @State private var showSearch = false

    private var sortBar: some View {
        VStack(spacing: 4) {
            HStack {
                HStack(spacing: 0) {
                    Menu {
                        ForEach(MainViewModel.SortMethod.allCases, id: \.rawValue) { method in
                            Button(method.displayName) {
                                vm.updateSortMethod(method)
                            }
                        }
                    } label: {
                        Text(vm.sortMethod.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textPrimary)
                            .padding(.leading, 10)
                            .padding(.vertical, 4)
                    }

                    Button {
                        vm.toggleSortOrder()
                    } label: {
                        Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 18))
                            .foregroundStyle(AppColors.textPrimary)
                            .padding(.trailing, 10)
                            .padding(.vertical, 4)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .background(AppColors.darkSurfaceHigh)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSearch.toggle()
                        if !showSearch {
                            vm.searchQuery = ""
                            vm.refreshList()
                        }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(showSearch ? AppColors.blue : AppColors.textPrimary)
                }
                .frame(width: 36, height: 36)
            }

            if showSearch {
                SearchBar(
                    text: Binding(
                        get: { vm.searchQuery },
                        set: { vm.searchQuery = $0; vm.refreshList() }
                    )
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 8))
    }

    // MARK: - Pack List

    private var packList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(vm.unipackItems) { item in
                        let isSelected = vm.selectedItem?.id == item.id
                        UnipackListItemView(
                            title: item.unipack.criticalError
                                ? String(localized: "errOccur")
                                : item.unipack.title,
                            subtitle: item.unipack.criticalError
                                ? item.unipack.getPathString()
                                : item.unipack.producerName,
                            hasLed: item.unipack.keyLedExist,
                            hasAutoPlay: item.unipack.autoPlayExist,
                            isBookmarked: item.isBookmarked,
                            isSelected: isSelected,
                            flagColor: isSelected
                                ? AppColors.red
                                : (item.unipack.criticalError ? AppColors.red : AppColors.skyblue),
                            onTap: {
                                vm.toggleSelection(item)
                            },
                            onPlay: {
                                vm.recordOpen(item)
                                router.navigate(to: .play(packPath: item.unipack.getPathString()))
                            }
                        )
                        .id(item.id)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                vm.deleteTargetItem = item
                                showDeleteConfirmation = true
                            } label: {
                                Label(String(localized: "delete"), systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                vm.toggleBookmark(item)
                            } label: {
                                Label(
                                    item.isBookmarked ? String(localized: "remove_bookmark") : String(localized: "add_bookmark"),
                                    systemImage: item.isBookmarked ? "bookmark.slash" : "bookmark.fill"
                                )
                            }
                            .tint(AppColors.green)
                        }
                    }

                    guidingActionsRow
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("main.packList")
            .refreshable {
                vm.refreshList()
            }
            .onChange(of: vm.scrollToItemId) { _, itemId in
                guard let itemId else { return }
                withAnimation {
                    proxy.scrollTo(itemId, anchor: .center)
                }
                vm.scrollToItemId = nil
            }
        }
    }

    // MARK: - Empty State / Guiding Actions

    private var searchEmptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.textPrimary.opacity(0.5))
            Text(String(localized: "no_search_results"))
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textPrimary)
            guidingActionsRow
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            Spacer()
        }
    }

    /// Centred when it fits; on short screens the same content scrolls instead of being clipped.
    private var emptyStateView: some View {
        ViewThatFits(in: .vertical) {
            VStack {
                Spacer(minLength: 0)
                emptyStateContent
                Spacer(minLength: 0)
            }
            ScrollView {
                emptyStateContent
            }
        }
    }

    private var emptyStateContent: some View {
        VStack(spacing: 12) {
            FirstPackGuide()
            guidingActionsRow
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    /// The only entry points to the store and to file import on the home screen.
    private var guidingActionsRow: some View {
        HStack(spacing: 6) {
            GuidingChip(
                icon: "cart",
                text: String(localized: "guide_download_new")
            ) {
                router.navigate(to: .store)
            }
            .accessibilityIdentifier("main.guide.download")

            GuidingChip(
                icon: "folder",
                text: String(localized: "guide_import_external")
            ) {
                vm.isImporting = true
            }
            .accessibilityIdentifier("main.guide.import")
        }
    }
}

// MARK: - Guiding Chip

/// Tells someone with an empty library how to get a pack and start playing.
private struct FirstPackGuide: View {
    static let getStartedURL = URL(string: "https://unipad.io/docs/get-started")!

    private let stepKeys: [String] = [
        "main_empty_step_get_pack",
        "main_empty_step_play",
        "main_empty_step_no_launchpad",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "main_empty_title"))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AppColors.white)

            ForEach(Array(stepKeys.enumerated()), id: \.offset) { index, key in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                    // LocalizedStringKey renders the **bold** button names in the strings.
                    Text(LocalizedStringKey(key))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textPrimary)
            }

            Button {
                PlatformHelpers.openURL(Self.getStartedURL)
            } label: {
                HStack(spacing: 4) {
                    Text(String(localized: "main_empty_guide_link"))
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.orange)
            }
            .accessibilityIdentifier("main.guide.getStarted")
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppColors.darkSurfaceHigh.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct GuidingChip: View {
    let icon: String
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(AppColors.textPrimary)

                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(AppColors.darkSurfaceHigh.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - MainViewImportDelegate

private final class MainViewImportDelegate: UniPackImporter.Delegate, @unchecked Sendable {
    weak var viewModel: MainViewModel?

    init(viewModel: MainViewModel) {
        self.viewModel = viewModel
    }

    @MainActor func onImportStart() {}

    @MainActor func onImportComplete(folder: URL) {
        viewModel?.showImportSuccessForFolder(folder)
    }

    @MainActor func onImportError(_ error: Error) {
        viewModel?.importResult = .error(error.localizedDescription)
    }
}

extension MainView {
    static let appStoreURL = URL(string: "https://apps.apple.com/app/id6760479102")!
}
