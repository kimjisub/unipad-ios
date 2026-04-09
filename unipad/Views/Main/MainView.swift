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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UniPadFileOpenRequest"))) { notification in
            guard let url = notification.userInfo?["url"] as? URL else { return }
            let workspace = WorkspaceManager.shared.downloadWorkspace.url

            vm.isImportingInProgress = true
            let existingIds = Set(vm.unipackItems.map { $0.id })
            Task {
                let importer = UniPackImporter()
                let delegate = MainViewImportDelegate(viewModel: vm)
                await importer.importPack(from: url, to: workspace, delegate: delegate)
                await MainActor.run {
                    vm.isImportingInProgress = false
                    vm.refreshList()
                    vm.updateStats()
                    vm.showImportResultForNew(existingIds: existingIds)
                    showImportResult = true
                }
            }
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
                let workspace = WorkspaceManager.shared.downloadWorkspace.url

                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }

                vm.isImportingInProgress = true
                let existingIds = Set(vm.unipackItems.map { $0.id })
                Task {
                    let importer = UniPackImporter()
                    let delegate = MainViewImportDelegate(viewModel: vm)
                    await importer.importPack(from: url, to: workspace, delegate: delegate)
                    await MainActor.run {
                        vm.isImportingInProgress = false
                        vm.refreshList()
                        vm.updateStats()
                        vm.showImportResultForNew(existingIds: existingIds)
                        showImportResult = true
                    }
                }
            case .failure(let error):
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
        .overlay {
            if showImportResult, let result = vm.importResult {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                        .onTapGesture {
                            showImportResult = false
                            vm.importResult = nil
                        }

                    VStack(spacing: 0) {
                        // Title bar
                        Text({
                            switch result {
                            case .success: String(localized: "importComplete")
                            case .warning: String(localized: "warning")
                            case .error: String(localized: "importFailed")
                            }
                        }())
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(hex: 0x1A1A1A))
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                        ImportResultDialog(result: result, onDismiss: {})

                        // OK button
                        Divider()
                        Button {
                            showImportResult = false
                            vm.importResult = nil
                        } label: {
                            Text(String(localized: "accept"))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(AppColors.blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 40)
                    .frame(maxWidth: 360)
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
                        onUpdateClick: {
                            if let url = URL(string: "https://apps.apple.com/app/unipad/id1668033585") {
                                PlatformHelpers.openURL(url)
                            }
                        }
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

                Button {
                    router.navigate(to: .store)
                } label: {
                    Image(systemName: "cart")
                        .font(.system(size: 20))
                        .foregroundStyle(AppColors.textPrimary)
                }
                .frame(width: 36, height: 36)

                Button {
                    vm.isImporting = true
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 20))
                        .foregroundStyle(AppColors.textPrimary)
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
            Spacer()
        }
    }

    private var emptyStateView: some View {
        VStack {
            Spacer()
            guidingActionsRow
                .padding(.horizontal, 16)
            Spacer()
        }
    }

    private var guidingActionsRow: some View {
        HStack(spacing: 6) {
            GuidingChip(
                icon: "cart",
                text: String(localized: "guide_download_new")
            ) {
                router.navigate(to: .store)
            }

            GuidingChip(
                icon: "folder",
                text: String(localized: "guide_import_external")
            ) {
                vm.isImporting = true
            }
        }
    }
}

// MARK: - Guiding Chip

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

