import SwiftUI
import SwiftData

@Observable
final class MainViewModel {
    // MARK: - Sort

    enum SortMethod: Int, CaseIterable {
        case title = 0
        case producer
        case playCount
        case lastOpenedDate
        case downloadDate

        var displayName: String {
            switch self {
            case .title: return String(localized: "sort_title")
            case .producer: return String(localized: "sort_producer")
            case .playCount: return String(localized: "sort_play_count")
            case .lastOpenedDate: return String(localized: "sort_last_opened_date")
            case .downloadDate: return String(localized: "sort_download_date")
            }
        }

        var defaultAscending: Bool {
            switch self {
            case .title, .producer: return false
            case .playCount, .lastOpenedDate: return false
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
    var currentThemeName: String? {
        let themeId = ThemeManager.shared.activeThemeId
        if themeId == "default" { return "Default" }
        if themeId.hasPrefix(ThemeManager.bundledThemePrefix) {
            return String(themeId.dropFirst(ThemeManager.bundledThemePrefix.count))
        }
        return themeId
    }

    // MARK: - MIDI

    var onLaunchpadPlay: ((UniPackItem) -> Void)?
    var scrollToItemId: String?
    private var lastPlayIndex: Int = -1
    private var midiControllerAdapter: MainMidiControllerAdapter?

    func setupMidiController() {
        let adapter = MainMidiControllerAdapter(viewModel: self)
        midiControllerAdapter = adapter
        MidiManager.shared.controller = adapter
    }

    func removeMidiController() {
        if let adapter = midiControllerAdapter {
            MidiManager.shared.removeController(adapter)
        }
        midiControllerAdapter = nil
    }

    func updateLP() {
        showWatermark()
        showSelectLPUI()
    }

    private func showWatermark() {
        let driver = MidiManager.shared.driver
        driver.sendPadLed(x: 3, y: 3, velocity: 61)
        driver.sendPadLed(x: 3, y: 4, velocity: 40)
        driver.sendPadLed(x: 4, y: 3, velocity: 40)
        driver.sendPadLed(x: 4, y: 4, velocity: 61)
    }

    func showSelectLPUI() {
        let driver = MidiManager.shared.driver
        driver.sendFunctionKeyLed(f: 0, velocity: havePrev() ? 63 : 5)
        driver.sendFunctionKeyLed(f: 2, velocity: haveNow() ? 61 : 0)
        driver.sendFunctionKeyLed(f: 1, velocity: haveNext() ? 63 : 5)
    }

    private func haveNow() -> Bool {
        lastPlayIndex >= 0 && lastPlayIndex <= unipackItems.count - 1
    }

    private func haveNext() -> Bool {
        lastPlayIndex < unipackItems.count - 1
    }

    private func havePrev() -> Bool {
        lastPlayIndex > 0
    }

    func selectByIndex(_ index: Int) {
        guard index >= 0 && index < unipackItems.count else { return }
        lastPlayIndex = index
        selectedItem = unipackItems[index]
        scrollToItemId = unipackItems[index].id
        showSelectLPUI()
    }

    func navigateNext() {
        if haveNext() {
            selectByIndex(lastPlayIndex + 1)
        }
    }

    func navigatePrev() {
        if havePrev() {
            selectByIndex(lastPlayIndex - 1)
        }
    }

    func currentClick() -> UniPackItem? {
        if haveNow() {
            return unipackItems[lastPlayIndex]
        }
        return nil
    }

    // MARK: - Methods

    private let workspaceManager = WorkspaceManager.shared

    func versionCheck() {
        let thisVersion = appVersion
        guard !thisVersion.contains("b") else { return }

        let versionListString = FirebaseManager.shared.remoteConfig.getString("ios_version")
        guard !versionListString.isEmpty,
              let data = versionListString.data(using: .utf8),
              let versionList = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }

        if !versionList.contains(thisVersion) {
            updateAvailable = true
        }
    }
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
        withAnimation(.easeInOut(duration: 0.5)) {
            if selectedItem?.id == item.id {
                selectedItem = nil
            } else {
                selectedItem = item
            }
        }
        if selectedItem != nil {
            loadDetailIfNeeded(item)
        }
    }

    var detailLoadVersion = 0

    private func loadDetailIfNeeded(_ item: UniPackItem) {
        guard !item.unipack.detailLoaded else { return }
        Task.detached(priority: .userInitiated) {
            let _ = item.unipack.loadDetail()
            await MainActor.run { [weak self] in
                guard let self, self.selectedItem?.id == item.id else { return }
                self.detailLoadVersion += 1
            }
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
            case .playCount:
                result = a.openCount < b.openCount ? -1 : (a.openCount > b.openCount ? 1 : 0)
            case .lastOpenedDate:
                let aDate = a.lastOpenedAt ?? .distantPast
                let bDate = b.lastOpenedAt ?? .distantPast
                result = aDate < bDate ? -1 : (aDate > bDate ? 1 : 0)
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

    func toggleBookmark(_ item: UniPackItem) {
        guard let container = modelContainer else { return }
        let repo = UnipackRepository(modelContainer: container)
        try? repo.toggleBookmark(id: item.unipack.id)
        refreshList()
    }

    func showImportResultForNew(existingIds: Set<String>) {
        if let newItem = unipackItems.first(where: { !existingIds.contains($0.id) }) {
            newItem.unipack.loadDetail()
            importResult = .success(newItem.unipack)
        }
    }

    func showImportSuccessForFolder(_ folderURL: URL) {
        let pack = UniPackFolder(rootFolder: folderURL)
        pack.load()
        pack.loadDetail()
        if pack.criticalError {
            importResult = .warning(pack.errorDetail ?? String(localized: "errOccur"))
        } else {
            importResult = .success(pack)
        }
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

// MARK: - Main MIDI Controller Adapter

final class MainMidiControllerAdapter: MidiController {
    weak var viewModel: MainViewModel?

    init(viewModel: MainViewModel) {
        self.viewModel = viewModel
    }

    func onAttach() {
        MidiManager.shared.driver.sendClearLed()
        viewModel?.updateLP()
    }

    func onDetach() {}

    func onPadTouch(x: Int, y: Int, upDown: Bool, velocity: Int) {
        let isWatermarkArea = (x == 3 || x == 4) && (y == 3 || y == 4)
        guard !isWatermarkArea else { return }

        let driver = MidiManager.shared.driver
        if upDown {
            driver.sendPadLed(x: x, y: y, velocity: [40, 61].randomElement()!)
        } else {
            driver.sendPadLed(x: x, y: y, velocity: 0)
        }
    }

    func onFunctionKeyTouch(f: Int, upDown: Bool) {
        guard upDown else { return }
        switch f {
        case 0: viewModel?.navigatePrev()
        case 1: viewModel?.navigateNext()
        case 2:
            if let item = viewModel?.currentClick() {
                viewModel?.onLaunchpadPlay?(item)
            }
        default: break
        }
    }

    func onChainTouch(c: Int, upDown: Bool) {}

    func onUnknownEvent(cmd: Int, sig: Int, note: Int, velocity: Int) {
        if cmd == 7 && sig == 46 && note == 0 && velocity == -9 {
            viewModel?.updateLP()
        }
    }
}
