import SwiftUI
import SwiftData

@Observable
final class MainViewModel {
    // MARK: - Sort

    enum SortMethod: Int, CaseIterable {
        case title = 0
        case producer
        case downloadDate

        var displayName: String {
            switch self {
            case .title: return String(localized: "sort_title")
            case .producer: return String(localized: "sort_producer")
            case .downloadDate: return String(localized: "sort_download_date")
            }
        }

        var defaultAscending: Bool {
            switch self {
            case .title, .producer: return false
            case .downloadDate: return true
            }
        }
    }

    var sortMethod: SortMethod = SortMethod(rawValue: PreferenceManager.shared.sortMethod) ?? .title
    var sortAscending: Bool = PreferenceManager.shared.sortOrder

    // MARK: - Pack List

    var unipackItems: [UniPackItem] = []
    var selectedItem: UniPackItem?
    var isRefreshing = false
    var searchQuery = ""

    // MARK: - Stats

    var unipackCount: Int?
    var unipackCapacity: String?
    var totalOpenCount: Int = 0

    // MARK: - Import

    var isImporting = false
    var isImportingInProgress = false
    var importResult: ImportResult?
    var deleteTargetItem: UniPackItem?

    // MARK: - Version

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    var updateAvailable = false

    // MARK: - Methods

    private let workspaceManager = WorkspaceManager.shared
    var modelContainer: ModelContainer?

    func refreshList() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task { @MainActor in
            var items: [UniPackItem] = []
            let repo = modelContainer.map { UnipackRepository(modelContainer: $0) }

            for workspace in workspaceManager.availableWorkspaces {
                let folders = workspaceManager.getUnipackFolders(workspace: workspace)
                for folderURL in folders {
                    let pack = UniPackFolder(rootFolder: folderURL)
                    pack.load()

                    let entity = try? repo?.getOrCreate(id: pack.id)
                    items.append(UniPackItem(
                        unipack: pack,
                        isBookmarked: entity?.bookmark ?? false,
                        openCount: entity?.openCount ?? 0,
                        lastOpenedAt: entity?.lastOpenedAt,
                        createdAt: entity?.createdAt
                    ))
                }
            }

            let selectedPath = selectedItem?.id
            unipackItems = sortedItems(filterItems(items))

            if let selectedPath {
                selectedItem = unipackItems.first { $0.id == selectedPath }
            }
            isRefreshing = false
        }
    }

    func updateStats() {
        var totalCount = 0
        for workspace in workspaceManager.availableWorkspaces {
            totalCount += workspaceManager.getUnipackCount(workspace: workspace)
        }
        unipackCount = totalCount

        if let container = modelContainer {
            let repo = UnipackRepository(modelContainer: container)
            totalOpenCount = Int((try? repo.totalOpenCount()) ?? 0)
        }

        Task { @MainActor in
            let sizeBytes = await workspaceManager.getAvailableWorkspacesSize()
            unipackCapacity = FileManagerExtensions.byteToMB(sizeBytes)
        }
    }

    func toggleSelection(_ item: UniPackItem) {
        if selectedItem?.id == item.id {
            selectedItem = nil
        } else {
            selectedItem = item
        }
    }

    private func filterItems(_ items: [UniPackItem]) -> [UniPackItem] {
        guard !searchQuery.isEmpty else { return items }
        let query = searchQuery.lowercased()
        return items.filter {
            $0.unipack.title.lowercased().contains(query)
            || $0.unipack.producerName.lowercased().contains(query)
        }
    }

    func sortedItems(_ items: [UniPackItem]) -> [UniPackItem] {
        let multiplier = sortAscending ? 1 : -1
        return items.sorted { a, b in
            let result: Int
            switch sortMethod {
            case .title:
                result = a.unipack.title.localizedCompare(b.unipack.title) == .orderedAscending ? -1 : 1
            case .producer:
                result = a.unipack.producerName.localizedCompare(b.unipack.producerName) == .orderedAscending ? -1 : 1
            case .downloadDate:
                result = a.unipack.lastModified() < b.unipack.lastModified() ? -1 : 1
            }
            return result * multiplier < 0
        }
    }

    func updateSortMethod(_ method: SortMethod) {
        sortMethod = method
        sortAscending = method.defaultAscending
        persistSort()
        refreshList()
    }

    func toggleSortOrder() {
        sortAscending.toggle()
        persistSort()
        refreshList()
    }

    private func persistSort() {
        PreferenceManager.shared.sortMethod = sortMethod.rawValue
        PreferenceManager.shared.sortOrder = sortAscending
    }

    func recordOpen(_ item: UniPackItem) {
        guard let container = modelContainer else { return }
        let repo = UnipackRepository(modelContainer: container)
        try? repo.recordOpen(id: item.unipack.id)
    }

    func deleteItem(_ item: UniPackItem) {
        item.unipack.delete()
        selectedItem = nil
        refreshList()
    }
}

// MARK: - Supporting Types

struct UniPackItem: Identifiable, Hashable {
    let id: String
    let unipack: UniPack
    var isBookmarked: Bool = false
    var openCount: Int64 = 0
    var lastOpenedAt: Date?
    var createdAt: Date?

    init(unipack: UniPack, isBookmarked: Bool = false, openCount: Int64 = 0, lastOpenedAt: Date? = nil, createdAt: Date? = nil) {
        self.id = unipack.getPathString()
        self.unipack = unipack
        self.isBookmarked = isBookmarked
        self.openCount = openCount
        self.lastOpenedAt = lastOpenedAt
        self.createdAt = createdAt
    }

    static func == (lhs: UniPackItem, rhs: UniPackItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum ImportResult {
    case success(UniPack)
    case warning(String)
    case error(String)
}
