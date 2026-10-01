import Foundation
import Combine
import os.log

@MainActor
final class WorkspaceManager: ObservableObject {
    static let shared = WorkspaceManager()

    private let logger = Logger(subsystem: "com.kimjisub.unipad", category: "Workspace")
    private let preferenceManager = PreferenceManager.shared

    nonisolated struct Workspace: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let url: URL

        init(name: String, url: URL) {
            self.id = url.path
            self.name = name
            self.url = url
        }
    }

    private init() {}

    // MARK: - Workspace Discovery

    var availableWorkspaces: [Workspace] {
        Self.currentWorkspaces()
    }

    /// Touches the disk (creates the folder when missing), so it is callable from any thread for a background read.
    nonisolated static func currentWorkspaces() -> [Workspace] {
        var workspaces: [Workspace] = []

        let documentsURL = Self.documentsDirectory
        let uniPackDir = documentsURL.appendingPathComponent("UniPack", isDirectory: true)
        Self.ensureDirectoryExists(at: uniPackDir)

        workspaces.append(Workspace(name: "App Storage", url: uniPackDir))

        return workspaces
    }

    /// Documents directory used as app workspace root
    nonisolated static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    nonisolated static func ensureDirectoryExists(at url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Workspace Validation

    func validateWorkspace() {
        let available = availableWorkspaces
        let downloadPath = preferenceManager.downloadStoragePath
        let availablePaths = Set(available.map(\.url.path))

        if downloadPath == nil || !availablePaths.contains(downloadPath!) {
            preferenceManager.downloadStoragePath = available.first?.url.path
        }
    }

    var downloadWorkspace: Workspace {
        let available = availableWorkspaces
        if let path = preferenceManager.downloadStoragePath,
           let match = available.first(where: { $0.url.path == path }) {
            return match
        }
        return available[0]
    }

    // MARK: - UniPack Listing

    func getUnipackCount(workspace: Workspace) -> Int {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: workspace.url.path) else { return 0 }
        return contents.filter { name in
            var isDir: ObjCBool = false
            let fullPath = workspace.url.appendingPathComponent(name).path
            return fm.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue && name != ".nomedia"
        }.count
    }

    func getUnipackFolders(workspace: Workspace) -> [URL] {
        Self.unipackFolders(in: workspace)
    }

    /// Every pack folder in every workspace. A full disk scan, callable from any thread.
    nonisolated static func allUnipackFolders() -> [URL] {
        currentWorkspaces().flatMap { unipackFolders(in: $0) }
    }

    nonisolated static func unipackFolders(in workspace: Workspace) -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: workspace.url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return contents.filter { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir && url.lastPathComponent != ".nomedia"
        }
    }

    // MARK: - Workspace Size

    func getAvailableWorkspacesSize() async -> Int64 {
        let workspaces = availableWorkspaces
        var total: Int64 = 0
        for workspace in workspaces {
            total += await FileManagerExtensions.getFolderSize(at: workspace.url)
        }
        return total
    }
}
