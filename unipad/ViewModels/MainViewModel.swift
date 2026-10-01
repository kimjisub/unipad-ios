import SwiftUI
import SwiftData
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "MainViewModel")

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
    /// Every pack from the last disk scan, before the search filter and sort.
    private var loadedItems: [UniPackItem] = []
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
    var deleteFailed = false

    // MARK: - Version

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    var updateAvailable = false
    var currentThemeName: String? {
        ThemeManager.shared.activeResources.name
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
        if MidiManager.shared.isConnected {
            adapter.onAttach()
        }
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

    /// Every pack folder in every workspace. A call is a full disk scan, so only reloads go through it,
    /// and it runs off the main actor.
    @ObservationIgnored var packFolderSource: @Sendable () -> [URL] = { WorkspaceManager.allUnipackFolders() }

    /// Reads one pack folder's info files. Only reloads go through it, and it runs off the main actor.
    @ObservationIgnored var readPack: @Sendable (URL) -> UniPack = { UniPackFolder(rootFolder: $0).load() }

    /// Set when a reload is asked for while another one is reading: the read in progress may predate
    /// the change (an import, a background return), so one more read follows it.
    @ObservationIgnored private var reloadRequestedAgain = false

    /// Set when the read in progress is known to show a pack that no longer exists, so it is not shown.
    @ObservationIgnored private var runningReadIsStale = false

    /// The reload under way, including the follow-up read; import waits on it to find the imported pack.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    /// The download-date sort keys from the last reload that read them.
    @ObservationIgnored private var modificationTimes = PackModificationTimes()

    func refreshList() {
        guard !isRefreshing else {
            reloadRequestedAgain = true
            return
        }
        isRefreshing = true

        reloadTask = Task { @MainActor in
            repeat {
                reloadRequestedAgain = false
                runningReadIsStale = false
                let read = await Self.readPacks(
                    listing: packFolderSource,
                    reading: readPack,
                    knownTimes: sortMethod == .downloadDate ? modificationTimes : nil
                )
                if let times = read.times {
                    modificationTimes = times
                }
                if sortMethod == .downloadDate && read.times == nil {
                    // The sort turned to download date while this read skipped the times.
                    reloadRequestedAgain = true
                } else if !runningReadIsStale {
                    publish(read.packs)
                }
            } while reloadRequestedAgain
            isRefreshing = false
            reloadTask = nil
        }
    }

    /// A pack read off the main actor, with its folder's modification time when the read took it.
    private nonisolated struct ReadPack {
        let pack: UniPack
        let lastModified: TimeInterval
    }

    private nonisolated struct ListRead {
        let packs: [ReadPack]
        /// Nil when the read skipped the modification times, which only the download-date sort uses.
        let times: PackModificationTimes?
    }

    /// Lists the pack folders and reads each pack's info files, away from the main actor. With
    /// `knownTimes` it also takes each folder's modification time, walking only the folders that changed.
    /// The packs are handed over whole and are not touched here afterwards.
    @concurrent private static func readPacks(
        listing: @Sendable () -> [URL],
        reading: @Sendable (URL) -> UniPack,
        knownTimes: PackModificationTimes?
    ) async -> sending ListRead {
        let folders = listing()
        guard let knownTimes else {
            return ListRead(packs: folders.map { ReadPack(pack: reading($0), lastModified: 0) }, times: nil)
        }
        var times = PackModificationTimes()
        let packs = folders.map { folder in
            let pack = reading(folder)
            return ReadPack(pack: pack, lastModified: times.read(pack, in: folder, reusing: knownTimes))
        }
        return ListRead(packs: packs, times: times)
    }

    /// Adds the saved record (bookmark, play count) to the packs that were read and shows them.
    private func publish(_ packs: [ReadPack]) {
        let repo = modelContainer.map { UnipackRepository(modelContainer: $0) }
        loadedItems = packs.map { read in
            let entity = try? repo?.getOrCreate(id: read.pack.id)
            return UniPackItem(
                unipack: read.pack,
                isBookmarked: entity?.bookmark ?? false,
                openCount: entity?.openCount ?? 0,
                lastOpenedAt: entity?.lastOpenedAt,
                createdAt: entity?.createdAt,
                lastModified: read.lastModified
            )
        }
        applyListFilter()
        // The reload replaced the selected pack's object, so its detail has to be read again.
        if let selectedItem {
            loadDetailIfNeeded(selectedItem)
        }
    }

    /// Rebuilds the visible list from `loadedItems` without touching the disk.
    private func applyListFilter() {
        let selectedPath = selectedItem?.id
        unipackItems = sortedItems(filterItems(loadedItems))

        if let selectedPath {
            selectedItem = unipackItems.first { $0.id == selectedPath }
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

    /// Detail reads under way, by pack object: a pack asked for again meanwhile is not read again.
    @ObservationIgnored private var detailReads: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Reads the pack's detail off the main actor and gives the pack the whole result here, on the
    /// main actor, where the panel reads it. Returns the read to wait for, or nil when there is
    /// nothing left to read.
    @discardableResult
    private func loadDetailIfNeeded(_ item: UniPackItem) -> Task<Void, Never>? {
        let unipack = item.unipack
        let key = ObjectIdentifier(unipack)
        if let reading = detailReads[key] { return reading }
        guard let read = unipack.makeDetailRead() else { return nil }

        let reading = Task { [weak self] in
            let detail = await Task.detached(priority: .userInitiated) { read { _, _, _ in } }.value
            unipack.applyDetail(detail)
            guard let self else { return }
            self.detailReads[key] = nil
            if self.selectedItem?.id == item.id {
                self.detailLoadVersion += 1
            }
        }
        detailReads[key] = reading
        return reading
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        applyListFilter()
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
                result = a.lastModified < b.lastModified ? -1 : (a.lastModified > b.lastModified ? 1 : 0)
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
        recordOpen(item.unipack)
    }

    func recordOpen(_ unipack: UniPack) {
        guard let container = modelContainer else { return }
        let repo = UnipackRepository(modelContainer: container)
        try? repo.recordOpen(id: unipack.id)
    }

    func toggleBookmark(_ item: UniPackItem) {
        guard let container = modelContainer else { return }
        let repo = UnipackRepository(modelContainer: container)
        try? repo.toggleBookmark(id: item.unipack.id)
        refreshList()
    }

    /// Counts import result requests, so a slower earlier one cannot replace a later result.
    @ObservationIgnored private var importResultRequests = 0

    /// Shows a finished import: the reloaded list, then the imported pack's result. The progress
    /// stays up until the result is ready, so the screen is never left with neither.
    func completeImport(importedFolder: URL?) async {
        refreshList()
        if let importedFolder {
            // A later import owns the progress now and takes it down with its own result.
            guard await showImportResult(forImportedFolder: importedFolder) else { return }
        }
        isImportingInProgress = false
    }

    /// Matches on the imported folder so the dialog, and its play action, can never point at another pack.
    /// Returns once the result is set, which is after the pack's detail has been read off the main actor,
    /// or false without setting it when a later request came in meanwhile.
    @discardableResult
    func showImportResult(forImportedFolder folder: URL) async -> Bool {
        importResultRequests += 1
        let request = importResultRequests
        await reloadTask?.value

        let pack: UniPack
        if let item = unipackItems.first(where: { $0.id == folder.path }) {
            await loadDetailIfNeeded(item)?.value
            pack = item.unipack
        } else {
            // Not in the shown list (a search hides it, or it went away): read it on its own.
            pack = await Self.readWholePack(folder, reading: readPack)
        }
        guard request == importResultRequests else { return false }

        // The importer already rejected critical errors, so any detail left is a soft parser error:
        // the pack is kept and shown as a warning, as Android does.
        if let detail = pack.errorDetail {
            importResult = .warning(detail)
        } else {
            importResult = .success(pack)
        }
        return true
    }

    /// Reads a pack's info and detail away from the main actor, for a pack nothing else holds.
    @concurrent private static func readWholePack(
        _ folder: URL,
        reading: @Sendable (URL) -> UniPack
    ) async -> sending UniPack {
        let pack = reading(folder)
        _ = pack.loadDetail()
        return pack
    }

    var makeRecordRemover: (ModelContainer) -> UnipackRecordRemoving = { UnipackRepository(modelContainer: $0) }

    /// Removes the pack's files, then its saved row (bookmark, play count) so a reinstall starts fresh.
    /// The row stays when the files could not be removed. Without a store nothing is deleted,
    /// since the row could not be removed afterwards.
    func deleteItem(_ item: UniPackItem) {
        guard let recordRemover = modelContainer.map(makeRecordRemover) else {
            logger.error("deleteItem skipped for \(item.unipack.id, privacy: .public): no model container")
            deleteFailed = true
            return
        }
        do {
            try item.unipack.delete()
            // The row goes now; a read that started before the delete would bring it back.
            runningReadIsStale = true
            loadedItems.removeAll { $0.id == item.id }
            try recordRemover.delete(id: item.unipack.id)
        } catch {
            logger.error("deleteItem failed for \(item.unipack.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            deleteFailed = true
        }
        selectedItem = nil
        applyListFilter()
        refreshList()
        updateStats()
    }
}

// MARK: - Supporting Types

/// Each pack folder's download-date sort key: the newest file time inside it, which takes a walk of
/// every file in the pack. A folder is walked again only when the modification date of the folder or
/// of a folder directly in it (sounds, keyLED) has moved, as a file added, replaced or removed there
/// does. A file rewritten in place, or a change deeper down, keeps the old key until the app restarts.
nonisolated struct PackModificationTimes: Sendable {
    private struct Entry: Sendable {
        let folderDates: [Date]
        let time: TimeInterval
    }

    private var entries: [String: Entry] = [:]

    /// The pack's sort key, taken from `known` when the folder has not changed since it was walked.
    mutating func read(_ pack: UniPack, in folder: URL, reusing known: PackModificationTimes) -> TimeInterval {
        let folderDates = Self.folderDates(of: folder)
        if let folderDates, let entry = known.entries[folder.path], entry.folderDates == folderDates {
            entries[folder.path] = entry
            return entry.time
        }
        let time = pack.lastModified()
        if let folderDates {
            entries[folder.path] = Entry(folderDates: folderDates, time: time)
        }
        return time
    }

    /// The folder's modification date followed by those of the folders directly in it, by name.
    private static func folderDates(of folder: URL) -> [Date]? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        guard
            let date = try? folder.resourceValues(forKeys: keys).contentModificationDate,
            let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
        else { return nil }
        let childDates = children
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { child -> Date? in
                guard let values = try? child.resourceValues(forKeys: keys), values.isDirectory == true else { return nil }
                return values.contentModificationDate
            }
        return [date] + childDates
    }
}

struct UniPackItem: Identifiable, Hashable {
    let id: String
    let unipack: UniPack
    var isBookmarked: Bool = false
    var openCount: Int64 = 0
    var lastOpenedAt: Date?
    var createdAt: Date?
    /// The pack folder's modification time as read with the list, so sorting never touches the disk.
    /// Only a reload for the download-date sort reads it; it is 0 otherwise.
    var lastModified: TimeInterval = 0

    init(unipack: UniPack, isBookmarked: Bool = false, openCount: Int64 = 0, lastOpenedAt: Date? = nil, createdAt: Date? = nil, lastModified: TimeInterval = 0) {
        self.id = unipack.getPathString()
        self.unipack = unipack
        self.isBookmarked = isBookmarked
        self.openCount = openCount
        self.lastOpenedAt = lastOpenedAt
        self.createdAt = createdAt
        self.lastModified = lastModified
    }

    /// Compares the saved record too: `@Observable` skips notifying for an equal value, so a
    /// reload that only changed the play count would otherwise never redraw the selected panel.
    /// Identity alone is `id`.
    static func == (lhs: UniPackItem, rhs: UniPackItem) -> Bool {
        lhs.id == rhs.id
            && lhs.isBookmarked == rhs.isBookmarked
            && lhs.openCount == rhs.openCount
            && lhs.lastOpenedAt == rhs.lastOpenedAt
            && lhs.createdAt == rhs.createdAt
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum ImportResult {
    case success(UniPack)
    case warning(String)
    case error(String)

    var playablePack: UniPack? {
        if case .success(let unipack) = self { return unipack }
        return nil
    }
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
