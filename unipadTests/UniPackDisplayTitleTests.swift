import Foundation
import Testing
@testable import unipad

/// The name the pack list and detail panel show: the info file's title, or the pack's folder name
/// when that title is empty or blank. The stored title and its warning stay as read.
struct UniPackDisplayTitleTests {
    private func load(folderName: String, info: String) throws -> (pack: UniPackFolder, cleanup: () -> Void) {
        let parent = FileManager.default.temporaryDirectory.appending(path: "UniPackDisplayTitleTests-\(UUID().uuidString)")
        let root = parent.appending(path: folderName)
        try FileManager.default.createDirectory(at: root.appending(path: "sounds"), withIntermediateDirectories: true)
        try Data(info.utf8).write(to: root.appending(path: "info"))
        try Data("1 1 1 a.wav\n".utf8).write(to: root.appending(path: "keySound"))
        try Data().write(to: root.appending(path: "sounds/a.wav"))
        let pack = UniPackFolder(rootFolder: root)
        pack.load()
        return (pack, { try? FileManager.default.removeItem(at: parent) })
    }

    @Test func aMissingTitleShowsTheFolderName() throws {
        let (pack, cleanup) = try load(folderName: "Untitled Pack A", info: "buttonX=4\nbuttonY=3\nchain=1\n")
        defer { cleanup() }

        #expect(pack.title == "")
        #expect(pack.displayTitle == "Untitled Pack A")
        #expect(pack.errorDetail?.contains("info : title was missing") == true)
    }

    @Test(arguments: [" ", " \t ", "\u{3000}"])
    func aBlankTitleShowsTheFolderName(title: String) throws {
        let (pack, cleanup) = try load(folderName: "Untitled Pack B", info: "buttonX=4\nbuttonY=3\nchain=1\n")
        defer { cleanup() }
        pack.title = title

        #expect(pack.displayTitle == "Untitled Pack B")
        #expect(pack.title == title)
    }

    @Test func aNamedTitleIsShownUnchanged() throws {
        let (pack, cleanup) = try load(folderName: "folder-name",
                                       info: "title=My Pack\nproducerName=Tester\nbuttonX=4\nbuttonY=3\nchain=1\n")
        defer { cleanup() }

        #expect(pack.displayTitle == "My Pack")
    }
}
