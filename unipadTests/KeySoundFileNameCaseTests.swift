import Foundation
import Testing
@testable import unipad

/// keySound names a sound the way its author's disk found it. Windows and macOS disks ignore letter
/// case, so official store packs name `End.wav` for a file stored as `END.wav`; an iPhone's disk does
/// not, and those pads were silent here while the web and Android played them.
struct KeySoundFileNameCaseTests {
    private func load(keySound: String, sounds: [String]) throws -> (pack: UniPackFolder, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "KeySoundFileNameCaseTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let soundsDir = root.appending(path: "sounds", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)
        try "title=Case\nproducerName=UniPad\nbuttonX=4\nbuttonY=4\nchain=1\n"
            .write(to: root.appending(path: "info"), atomically: true, encoding: .utf8)
        try keySound.write(to: root.appending(path: "keySound"), atomically: true, encoding: .utf8)
        for sound in sounds {
            let file = soundsDir.appending(path: sound)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 4).write(to: file)
        }
        let pack = UniPackFolder(rootFolder: root)
        pack.checkFile()
        pack.loadInfo()
        pack.loadDetail()
        return (pack, root)
    }

    /// The path below `sounds/` of the file the pad at (x, y) of chain 1 plays first.
    private func soundPath(_ pack: UniPackFolder, root: URL, x: Int, y: Int) -> String? {
        guard let file = pack.soundTable?[0][x][y]?.first?.file else { return nil }
        let base = root.resolvingSymlinksInPath().appending(path: "sounds").path + "/"
        let path = file.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    @Test func aNameThatDiffersOnlyInCasePlaysTheStoredFile() throws {
        let (pack, root) = try load(keySound: "1 1 1 End.wav\n1 2 1 clap.wav\n", sounds: ["END.wav", "Clap.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(soundPath(pack, root: root, x: 0, y: 0) == "END.wav")
        #expect(soundPath(pack, root: root, x: 1, y: 0) == "Clap.wav")
        #expect(pack.errorDetail == nil)
    }

    @Test func folderNamesBelowSoundsAlsoMatchRegardlessOfCase() throws {
        let (pack, root) = try load(keySound: "1 1 1 fx/sweep.wav\n", sounds: ["FX/Sweep.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(soundPath(pack, root: root, x: 0, y: 0) == "FX/Sweep.wav")
        #expect(pack.errorDetail == nil)
    }

    @Test func anExactNameIsPreferredOverOneThatDiffersInCase() throws {
        let (pack, root) = try load(keySound: "1 1 1 kick.wav\n", sounds: ["kick.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(soundPath(pack, root: root, x: 0, y: 0) == "kick.wav")
    }

    @Test func aNameNoFileMatchesInAnyCaseIsStillMissing() throws {
        let (pack, root) = try load(keySound: "1 1 1 End.wav\n1 2 1 nope.wav\n", sounds: ["END.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(soundPath(pack, root: root, x: 0, y: 0) == "END.wav")
        #expect(soundPath(pack, root: root, x: 1, y: 0) == nil)
        #expect(pack.errorDetail == "keySound : [1 2 1 nope.wav] sound was not found")
    }

    @Test func aFolderIsNotTakenForASoundFile() throws {
        let (pack, root) = try load(keySound: "1 1 1 Fx\n", sounds: ["fx/sweep.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(soundPath(pack, root: root, x: 0, y: 0) == nil)
        #expect(pack.errorDetail == "keySound : [1 1 1 Fx] sound was not found")
    }
}
