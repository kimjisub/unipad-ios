import SwiftUI

struct TransferView: View {
    @Environment(AppRouter.self) private var router
    let config: Route.TransferConfig

    @State private var state: TransferState = .loading
    @State private var searchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            topBar
            contentForState
        }
        .background(AppColors.background1)
        .platformNavigationBarHidden(true)
        .onAppear {
            loadConfiguration()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button {
                if case .executing = state { return }
                router.pop()
            } label: {
                Image(systemName: "chevron.left")
                    .foregroundStyle(AppColors.textPrimary)
            }
            .padding(.leading, 8)

            Text(config.title ?? String(localized: "transfer_title"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)

            Spacer()

            if case .configuration(let data) = state {
                let canStart = !data.items.filter(\.selected).isEmpty && data.selectedTargetId != nil
                Button(String(localized: "transfer_start")) {
                    startTransfer()
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(canStart ? AppColors.blue : AppColors.blue.opacity(0.38))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .disabled(!canStart)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentForState: some View {
        switch state {
        case .loading:
            loadingContent
        case .configuration(let data):
            configurationContent(data)
        case .executing(let progress):
            executingContent(progress)
        case .complete(let result):
            completeContent(result)
        }
    }

    private var loadingContent: some View {
        VStack {
            Spacer()
            ProgressView()
                .tint(AppColors.blue)
            Spacer()
        }
    }

    // MARK: - Configuration

    private func configurationContent(_ data: ConfigurationData) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // Left: Source items
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel(String(localized: "transfer_source") + ": " + data.sourceName)

                if !data.items.isEmpty {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(AppColors.textSecondary)
                            .font(.system(size: 14))

                        TextField("Search", text: $searchQuery)
                            .font(.system(size: 13))
                            .foregroundStyle(AppColors.textPrimary)

                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AppColors.textSecondary)
                                    .font(.system(size: 14))
                            }
                        }
                    }
                    .padding(8)
                    .background(AppColors.darkSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppColors.divider, lineWidth: 1)
                    )
                    .padding(.bottom, 8)

                    // Select all
                    let filteredItems = filteredItemIndices(data.items)
                    let allSelected = filteredItems.allSatisfy { data.items[$0].selected }

                    Button {
                        toggleSelectAll(!allSelected, indices: filteredItems)
                    } label: {
                        HStack {
                            Image(systemName: allSelected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(allSelected ? AppColors.blue : AppColors.textSecondary)

                            Text(allSelected
                                 ? String(localized: "transfer_deselect_all")
                                 : String(localized: "transfer_select_all"))
                                .font(.system(size: 13))
                                .foregroundStyle(AppColors.textPrimary)

                            Spacer()

                            Text(String(format: String(localized: "transfer_selected_count"), data.items.filter(\.selected).count))
                                .font(.system(size: 12))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        .padding(.vertical, 4)
                    }

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredItems, id: \.self) { index in
                                let item = data.items[index]
                                Button {
                                    toggleItem(at: index)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: item.selected ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(item.selected ? AppColors.blue : AppColors.textSecondary)

                                        if item.isZip {
                                            Text("ZIP")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(AppColors.blue)
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                        } else {
                                            Image(systemName: "folder")
                                                .font(.system(size: 14))
                                                .foregroundStyle(AppColors.textSecondary)
                                        }

                                        Text(item.name)
                                            .font(.system(size: 13))
                                            .foregroundStyle(item.selected ? AppColors.textPrimary : AppColors.textSecondary)
                                            .lineLimit(1)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                } else {
                    Text(String(localized: "transfer_no_items"))
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(.top, 8)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)

            // Right: Target selection + mode
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel(String(localized: "transfer_target"))

                    ForEach(data.targets, id: \.id) { target in
                        let isSelected = target.id == data.selectedTargetId
                        Button {
                            selectTarget(target.id)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(isSelected ? AppColors.blue : AppColors.textSecondary)
                                    .font(.system(size: 18))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AppColors.textPrimary)

                                    if !target.description.isEmpty {
                                        Text(target.description)
                                            .font(.system(size: 11))
                                            .foregroundStyle(AppColors.textSecondary)
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppColors.darkSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.bottom, 8)
                    }

                    Spacer().frame(height: 16)

                    sectionLabel("Mode")

                    HStack(spacing: 8) {
                        modeButton(
                            text: String(localized: "transfer_mode_copy"),
                            selected: data.mode == .copy
                        ) {
                            setMode(.copy)
                        }

                        modeButton(
                            text: String(localized: "transfer_mode_move"),
                            selected: data.mode == .move
                        ) {
                            setMode(.move)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Executing

    private func executingContent(_ progress: ProgressData) -> some View {
        VStack {
            Spacer()

            ProgressView(value: progress.total > 0
                         ? Double(progress.current) / Double(progress.total)
                         : 0)
                .tint(AppColors.blue)
                .padding(.horizontal, 40)

            Spacer().frame(height: 16)

            Text("\(progress.current) / \(progress.total)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            if !progress.currentName.isEmpty {
                Text(progress.currentName)
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.top, 8)
            }

            Spacer()
        }
    }

    // MARK: - Complete

    private func completeContent(_ result: TransferResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("Result")

                VStack(spacing: 0) {
                    resultRow(label: "Transferred", count: result.transferred, color: AppColors.green)

                    if result.skipped > 0 {
                        cardDivider
                        resultRow(label: "Skipped", count: result.skipped, color: AppColors.orange)
                    }

                    if result.failed > 0 {
                        cardDivider
                        resultRow(label: "Failed", count: result.failed, color: AppColors.red)
                    }
                }
                .padding(16)
                .background(AppColors.darkSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if !result.errors.isEmpty {
                    Spacer().frame(height: 16)
                    sectionLabel(String(localized: "error"))

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.errors, id: \.self) { error in
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(AppColors.red)
                        }
                    }
                    .padding(16)
                    .background(AppColors.darkSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Spacer().frame(height: 24)

                HStack {
                    Spacer()
                    Button(String(localized: "transfer_done")) {
                        router.pop()
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(AppColors.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(24)
        }
    }

    // MARK: - Reusable Components

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppColors.blue)
            .tracking(0.5)
            .padding(.leading, 4)
            .padding(.bottom, 8)
    }

    private func modeButton(text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : AppColors.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(selected ? AppColors.blue : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? AppColors.blue : AppColors.textSecondary.opacity(0.5), lineWidth: 1)
                )
        }
    }

    private func resultRow(label: String, count: Int, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textPrimary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
        }
        .padding(.vertical, 4)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(AppColors.divider)
            .frame(height: 1)
    }

    // MARK: - State Management

    private func loadConfiguration() {
        let workspaceManager = WorkspaceManager.shared
        let workspaces = workspaceManager.availableWorkspaces

        let sourceWorkspace: WorkspaceManager.Workspace
        if let sourcePath = config.sourcePath,
           let match = workspaces.first(where: { $0.url.path == sourcePath }) {
            sourceWorkspace = match
        } else {
            sourceWorkspace = workspaceManager.downloadWorkspace
        }

        let fm = FileManager.default
        var items: [TransferItem] = []
        if let contents = try? fm.contentsOfDirectory(
            at: sourceWorkspace.url,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for url in contents {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let name = url.lastPathComponent
                if name.hasPrefix(".") { continue }

                let isZip = url.pathExtension.lowercased() == "zip"
                if isDir || isZip {
                    items.append(TransferItem(
                        name: name,
                        selected: true,
                        isZip: isZip,
                        sourcePath: url.path
                    ))
                }
            }
        }

        let targets: [TransferTarget] = workspaces
            .filter { $0.url.path != sourceWorkspace.url.path }
            .map { TransferTarget(id: $0.id, name: $0.name, description: $0.url.path) }
        + [TransferTarget(id: "app", name: "App Storage", description: sourceWorkspace.url.path)]

        let filteredTargets = targets.filter { $0.description != sourceWorkspace.url.path }
        let finalTargets = filteredTargets.isEmpty ? targets : filteredTargets

        state = .configuration(ConfigurationData(
            sourceName: sourceWorkspace.name,
            items: items,
            targets: finalTargets,
            selectedTargetId: finalTargets.first?.id,
            mode: config.mode == "move" ? .move : .copy
        ))
    }

    private func filteredItemIndices(_ items: [TransferItem]) -> [Int] {
        items.enumerated().compactMap { index, item in
            if searchQuery.isEmpty || item.name.localizedCaseInsensitiveContains(searchQuery) {
                return index
            }
            return nil
        }
    }

    private func toggleItem(at index: Int) {
        guard case .configuration(var data) = state else { return }
        data.items[index].selected.toggle()
        state = .configuration(data)
    }

    private func toggleSelectAll(_ selectAll: Bool, indices: [Int]) {
        guard case .configuration(var data) = state else { return }
        for i in indices {
            data.items[i].selected = selectAll
        }
        state = .configuration(data)
    }

    private func selectTarget(_ targetId: String) {
        guard case .configuration(var data) = state else { return }
        data.selectedTargetId = targetId
        state = .configuration(data)
    }

    private func setMode(_ mode: TransferMode) {
        guard case .configuration(var data) = state else { return }
        data.mode = mode
        state = .configuration(data)
    }

    private func startTransfer() {
        guard case .configuration(let data) = state else { return }
        let selectedItems = data.items.filter(\.selected)
        guard !selectedItems.isEmpty, let targetId = data.selectedTargetId else { return }
        let mode = data.mode

        let targetPath: String
        if let target = data.targets.first(where: { $0.id == targetId }) {
            targetPath = target.description
        } else {
            return
        }

        state = .executing(ProgressData(current: 0, total: selectedItems.count, currentName: ""))

        Task {
            let fm = FileManager.default
            let targetURL = URL(fileURLWithPath: targetPath)
            FileManagerExtensions.ensureDirectoryExists(at: targetURL)

            var transferred = 0
            var skipped = 0
            var failed = 0
            var errors: [String] = []

            for (i, item) in selectedItems.enumerated() {
                state = .executing(ProgressData(
                    current: i,
                    total: selectedItems.count,
                    currentName: item.name
                ))

                let sourceURL = URL(fileURLWithPath: item.sourcePath)
                let destinationURL = FileManagerExtensions.makeNextPath(
                    dir: targetURL,
                    name: item.name,
                    extension: item.isZip ? ".zip" : ""
                )

                do {
                    if item.isZip {
                        let importer = UniPackImporter()
                        await importer.importPack(from: sourceURL, to: targetURL, delegate: nil)
                        if mode == .move {
                            try fm.removeItem(at: sourceURL)
                        }
                    } else {
                        switch mode {
                        case .copy:
                            try FileManagerExtensions.copyDirectory(from: sourceURL, to: destinationURL)
                        case .move:
                            try fm.moveItem(at: sourceURL, to: destinationURL)
                        }
                    }
                    transferred += 1
                } catch {
                    failed += 1
                    errors.append("\(item.name): \(error.localizedDescription)")
                }
            }

            state = .complete(TransferResult(
                total: selectedItems.count,
                transferred: transferred,
                skipped: skipped,
                failed: failed,
                errors: errors
            ))
        }
    }
}

// MARK: - Transfer Data Types

enum TransferState {
    case loading
    case configuration(ConfigurationData)
    case executing(ProgressData)
    case complete(TransferResult)
}

struct ConfigurationData {
    var sourceName: String
    var items: [TransferItem]
    var targets: [TransferTarget]
    var selectedTargetId: String?
    var mode: TransferMode = .copy
}

struct TransferItem {
    var name: String
    var selected: Bool = true
    var isZip: Bool = false
    var sourcePath: String = ""
}

struct TransferTarget: Identifiable {
    let id: String
    let name: String
    var description: String = ""
}

enum TransferMode {
    case copy, move
}

struct ProgressData {
    var current: Int
    var total: Int
    var currentName: String
}

struct TransferResult {
    var total: Int
    var transferred: Int
    var skipped: Int
    var failed: Int
    var errors: [String]
}
