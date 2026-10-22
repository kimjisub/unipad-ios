import Foundation
import Testing
@testable import unipad

/// A keySound sound name is a path relative to `sounds/`, looked up as Android and the web look it up.
struct SoundPathLookupTests {
    /// A pack with the given sound files (and `rootFiles` beside info), loaded as the library loads it.
    static func load(keySound: String, sounds: [String], rootFiles: [String] = [], base: URL = FileManager.default.temporaryDirectory)
        throws -> (pack: UniPackFolder, root: URL) {
        let root = base.appending(path: "SoundPathLookupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "sounds"), withIntermediateDirectories: true)
        try Data("title=Paths\nproducerName=UniPad\nbuttonX=4\nbuttonY=4\nchain=1\n".utf8).write(to: root.appending(path: "info"))
        try Data(keySound.utf8).write(to: root.appending(path: "keySound"))
        for (index, path) in (sounds.map { "sounds/\($0)" } + rootFiles).enumerated() {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([UInt8(index)]).write(to: file)
        }
        let pack = UniPackFolder(rootFolder: root)
        pack.load()
        pack.loadDetail()
        return (pack, root)
    }

    /// The path below `sounds/` of the file pad (x, 1) of chain 1 plays first.
    static func soundPath(_ pack: UniPackFolder, root: URL, x: Int) -> String? {
        guard let file = pack.soundTable?[0][x][0]?.first?.file else { return nil }
        let base = root.resolvingSymlinksInPath().appending(path: "sounds").path + "/"
        let path = file.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    @Test func backslashesSeparateFolders() throws {
        let (pack, root) = try Self.load(keySound: "1 1 1 fx\\sweep.wav\n1 2 1 \\fx\\\\sweep.wav\n", sounds: ["fx/sweep.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Self.soundPath(pack, root: root, x: 0) == "fx/sweep.wav")
        #expect(Self.soundPath(pack, root: root, x: 1) == "fx/sweep.wav")
        #expect(pack.errorDetail == nil)
    }

    @Test func leadingSlashesDotsAndRepeatedSlashesAreDropped() throws {
        let (pack, root) = try Self.load(keySound: "1 1 1 /a.wav\n1 2 1 ./a.wav\n1 3 1 fx//./s.wav\n", sounds: ["a.wav", "fx/s.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Self.soundPath(pack, root: root, x: 0) == "a.wav")
        #expect(Self.soundPath(pack, root: root, x: 1) == "a.wav")
        #expect(Self.soundPath(pack, root: root, x: 2) == "fx/s.wav")
        #expect(pack.errorDetail == nil)
    }

    @Test func aNameNeverLeavesTheSoundsFolder() throws {
        let (pack, root) = try Self.load(keySound: "1 1 1 ../bgm.wav\n1 2 1 ../info\n1 3 1 fx/../a.wav\n1 4 1 a.wav\n",
                                         sounds: ["a.wav", "fx/s.wav"], rootFiles: ["bgm.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Self.soundPath(pack, root: root, x: 0) == nil)
        #expect(Self.soundPath(pack, root: root, x: 1) == nil)
        #expect(Self.soundPath(pack, root: root, x: 2) == nil)
        #expect(Self.soundPath(pack, root: root, x: 3) == "a.wav")
        #expect(pack.errorDetail == """
            keySound : [1 1 1 ../bgm.wav] sound was not found
            keySound : [1 2 1 ../info] sound was not found
            keySound : [1 3 1 fx/../a.wav] sound was not found
            """)
    }

    @Test func composedAndDecomposedNamesFindTheSameFile() throws {
        let decomposed = "소리".decomposedStringWithCanonicalMapping + ".wav"
        let (pack, root) = try Self.load(keySound: "1 1 1 \(decomposed)\n", sounds: ["소리.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Self.soundPath(pack, root: root, x: 0)?.precomposedStringWithCanonicalMapping == "소리.wav")
    }
}

/// Names that differ only in letter case are different files only on a case-sensitive disk, as on an
/// iPhone; the simulator's Mac disk usually is not.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["UNIPACK_CASE_ROOT"] != nil,
                "Requires an explicitly configured case-sensitive volume"))
struct CaseSensitiveSoundPathLookupTests {
    private let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UNIPACK_CASE_ROOT"] ?? "/", isDirectory: true)

    @Test func theFirstCandidateInUTF16OrderIsTaken() throws {
        let (pack, root) = try SoundPathLookupTests.load(keySound: "1 1 1 End.wav\n1 2 1 end.wav\n", sounds: ["end.wav", "END.wav"], base: base)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SoundPathLookupTests.soundPath(pack, root: root, x: 0) == "END.wav")
        #expect(SoundPathLookupTests.soundPath(pack, root: root, x: 1) == "end.wav")
    }

    @Test func wholePathsAreComparedNotOneFolderAtATime() throws {
        let (pack, root) = try SoundPathLookupTests.load(keySound: "1 1 1 Fx/b.wav\n1 2 1 fx/A.wav\n", sounds: ["FX/a.wav", "fx/b.wav"], base: base)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SoundPathLookupTests.soundPath(pack, root: root, x: 0) == "fx/b.wav")
        #expect(SoundPathLookupTests.soundPath(pack, root: root, x: 1) == "FX/a.wav")
        #expect(pack.errorDetail == nil)
    }
}
