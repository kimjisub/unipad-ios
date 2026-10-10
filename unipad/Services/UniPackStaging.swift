import Foundation

/// A private folder where one pack is unpacked, unwrapped and checked before it enters the library.
/// The library lists every folder in the workspace, so a pack unpacked in place was listed half
/// written (often as an error pack) after the app was killed mid-install, and stayed there.
nonisolated struct UniPackStaging {
    /// In the app's own container, on the same volume as the workspace, so moving a finished pack
    /// into the library is a rename. Nothing but staging folders is ever written here.
    static let defaultRoot = FileManager.default.temporaryDirectory
        .appending(path: "UniPackStaging", directoryHint: .isDirectory)

    let directory: URL

    /// Where the pack is unpacked; it becomes the pack's folder in the library when published.
    var packFolder: URL { directory.appending(path: "pack", directoryHint: .isDirectory) }

    init(root: URL = defaultRoot) throws {
        directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packFolder, withIntermediateDirectories: true)
    }

    /// A working file (a downloaded or copied archive) that is deleted with the staging folder.
    func file(named name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }

    /// Moves the finished pack into `workspace` under the first free numbered `name`, in one step.
    func publish(to workspace: URL, name: String) throws -> URL {
        try FileManagerExtensions.moveToNextFreePath(packFolder, dir: workspace, name: name)
    }

    func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Deletes what installs killed with the app left behind. Only the folders present now are
    /// deleted, so an install that starts while this runs keeps its own; call it once at launch.
    @discardableResult
    static func removeLeftovers(in root: URL = defaultRoot) -> Task<Void, Never> {
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return Task.detached(priority: .utility) {
            for leftover in leftovers {
                try? FileManager.default.removeItem(at: leftover)
            }
        }
    }
}
