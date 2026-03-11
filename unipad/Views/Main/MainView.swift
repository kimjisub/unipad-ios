import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @State private var vm = MainViewModel()
    @State private var showDeleteConfirmation = false

    var body: some View {
        rightPanel
        .background(AppColors.background1)
        .platformNavigationBarHidden(true)
        .onAppear {
            vm.modelContainer = modelContext.container
            vm.refreshList()
            vm.updateStats()
        }
        .fileImporter(
            isPresented: Binding(
                get: { vm.isImporting },
                set: { vm.isImporting = $0 }
            ),
            allowedContentTypes: [.zip, .folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let workspace = WorkspaceManager.shared.downloadWorkspace.url

                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }

                if url.pathExtension.lowercased() == "zip" {
                    vm.isImportingInProgress = true
                    Task {
                        let importer = UniPackImporter()
                        await importer.importPack(from: url, to: workspace, delegate: nil)
                        await MainActor.run {
                            vm.isImportingInProgress = false
                            vm.refreshList()
                            vm.updateStats()
                        }
                    }
                } else {
                    let destName = url.lastPathComponent
                    let destDir = workspace.appendingPathComponent(destName)
                    do {
                        try FileManagerExtensions.copyDirectory(from: url, to: destDir)
                        vm.refreshList()
                        vm.updateStats()
                    } catch {
                        vm.importResult = .error(error.localizedDescription)
                    }
                }
            case .failure(let error):
                vm.importResult = .error(error.localizedDescription)
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

    // MARK: - Right Panel

    @ViewBuilder
    private var rightPanel: some View {
        VStack(spacing: 0) {
            headerSummary
            if vm.unipackItems.isEmpty && !vm.isRefreshing {
                emptyStateView
            } else {
                sortBar
                packList
            }
        }
    }

    // MARK: - Sort Bar

    @State private var showSearch = false

    private var headerSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("UniPad")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Text(vm.appVersion)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textPrimary)
                }

                Spacer()

                Button {
                    router.navigate(to: .settings)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(AppColors.darkSurfaceHigh)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            HStack(spacing: 10) {
                SummaryChip(label: String(localized: "MPT_playCount"), value: "\(vm.totalOpenCount)")
                SummaryChip(label: String(localized: "MTP_count"), value: vm.unipackCount.map(String.init) ?? "-")
                SummaryChip(label: String(localized: "MTP_size"), value: vm.unipackCapacity.map { "\($0) MB" } ?? "-")
            }

            if vm.updateAvailable {
                Text(String(localized: "update_available"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColors.blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var sortBar: some View {
        VStack(spacing: 4) {
            HStack {
                Menu {
                    ForEach(MainViewModel.SortMethod.allCases, id: \.rawValue) { method in
                        Button(method.displayName) {
                            vm.updateSortMethod(method)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(vm.sortMethod.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textPrimary)

                        Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textPrimary)
                            .onTapGesture {
                                vm.toggleSortOrder()
                            }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(AppColors.darkSurfaceHigh)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

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
                        .font(.system(size: 16))
                        .foregroundStyle(showSearch ? AppColors.blue : AppColors.textPrimary)
                }
                .frame(width: 36, height: 36)

                Button {
                    router.navigate(to: .store)
                } label: {
                    Image(systemName: "cart")
                        .font(.system(size: 16))
                        .foregroundStyle(AppColors.textPrimary)
                }
                .frame(width: 36, height: 36)

                Button {
                    vm.isImporting = true
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 16))
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Pack List

    private var packList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(vm.unipackItems) { item in
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
                        isSelected: false,
                        flagColor: item.unipack.criticalError ? AppColors.red : AppColors.skyblue,
                        flagText: "PLAY",
                        onTap: {
                            vm.recordOpen(item)
                            router.navigate(to: .play(packPath: item.unipack.getPathString()))
                        },
                        onPlay: {
                            vm.recordOpen(item)
                            router.navigate(to: .play(packPath: item.unipack.getPathString()))
                        }
                    )
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            vm.deleteTargetItem = item
                            showDeleteConfirmation = true
                        } label: {
                            Label(String(localized: "delete"), systemImage: "trash")
                        }
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
    }

    // MARK: - Empty State / Guiding Actions

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

            GuidingChip(
                icon: "gearshape",
                text: String(localized: "guide_restore_packs")
            ) {
                router.navigate(to: .settingsStorage)
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

private struct SummaryChip: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(AppColors.textPrimary)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppColors.darkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
