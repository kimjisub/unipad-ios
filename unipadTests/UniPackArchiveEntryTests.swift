import Foundation
import Testing
@testable import unipad

/// Entry names inside an imported ZIP, read as Android and the web read them.
@MainActor
struct UniPackArchiveEntryTests {
    static let info = Data("title=Entries\nproducerName=Tester\nbuttonX=4\nbuttonY=4\nchain=1\n".utf8)

    /// Imports `archive` the way the Files app import does and loads the installed pack.
    static func importArchive(_ archive: Data, base: URL = FileManager.default.temporaryDirectory) async throws
        -> (pack: UniPackFolder, installed: URL, root: URL) {
        let root = base.appending(path: "ArchiveEntries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "packs"), withIntermediateDirectories: true)
        let source = root.appending(path: "pack.zip")
        try archive.write(to: source)
        let installed = try await UniPackImporter(stagingRoot: root.appending(path: "staging"))
            .importPack(from: source, to: root.appending(path: "packs"), delegate: nil)
        let pack = UniPackFolder(rootFolder: installed)
        pack.load()
        pack.loadDetail()
        return (pack, installed, root)
    }

    static func soundName(_ pack: UniPackFolder, x: Int) -> String? {
        pack.soundTable?[0][x][0]?.first?.file.lastPathComponent
    }

    // MARK: Dots in names

    @Test func namesThatContainDotsAreExtracted() async throws {
        let archive = TestZip.stored([
            ("Faded.../info", Self.info),
            ("Faded.../keySound", Data("1 1 1 wait...wav\n".utf8)),
            ("Faded.../sounds/wait...wav", Data([1])),
        ])
        let (pack, installed, root) = try await Self.importArchive(archive)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!pack.criticalError)
        #expect(pack.errorDetail == nil)
        #expect(Self.soundName(pack, x: 0) == "wait...wav")
        #expect(FileManager.default.fileExists(atPath: installed.appending(path: "sounds/wait...wav").path))
    }

    @Test func anEntryThatLeavesThePackIsSkippedAndTheRestOpens() async throws {
        let archive = TestZip.stored([
            ("/info", Self.info),
            ("/keySound", Data("1 1 1 a.wav\n".utf8)),
            ("/sounds/a.wav", Data([1])),
            ("../escaped", Data([2])),
            ("sounds/../../escaped", Data([3])),
        ])
        let (pack, installed, root) = try await Self.importArchive(archive)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!pack.criticalError)
        #expect(Self.soundName(pack, x: 0) == "a.wav")
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix("escaped") }
        #expect(leftovers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installed.appending(path: "escaped").path))
    }

    // MARK: Backslash separators

    @Test(arguments: ["MyPack\\", ""])
    func backslashesSeparateFolders(top: String) async throws {
        let archive = TestZip.stored([
            ("\(top)info", Self.info),
            ("\(top)keySound", Data("1 1 1 a.wav\n".utf8)),
            ("\(top)sounds\\a.wav", Data([1])),
            ("\(top)keyLED\\1 1 1", Data("o 1 1 FF0000\n".utf8)),
        ])
        let (pack, installed, root) = try await Self.importArchive(archive)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!pack.criticalError)
        #expect(pack.errorDetail == nil)
        #expect(Self.soundName(pack, x: 0) == "a.wav")
        #expect(pack.ledAnimationTable?[0][0][0]?.count == 1)
        #expect(FileManager.default.fileExists(atPath: installed.appending(path: "sounds/a.wav").path))
    }

    // Distinct ZIP entries can have canonically equivalent names even though APFS cannot store
    // them beside each other. Assert the selected entry's contents after installation and reload.
    @Test(arguments: [false, true])
    func canonicallyEquivalentEntriesKeepTheirOwnContents(reverse: Bool) async throws {
        let nfc = "한.wav"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        var sounds = [("Pack/sounds/\(nfc)", Data([1])), ("Pack/sounds/\(nfd)", Data([2]))]
        if reverse { sounds.reverse() }
        let archive = TestZip.stored([
            ("Pack/info", Self.info),
            ("Pack/keySound", Data("1 1 1 \(nfc)\n1 2 1 \(nfd)\n".utf8)),
        ] + sounds)
        let (pack, installed, root) = try await Self.importArchive(archive)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(pack.errorDetail == nil)
        for (pad, expected) in [(0, Data([1])), (1, Data([2]))] {
            let sound = try #require(pack.soundTable?[0][pad][0]?.first)
            #expect(try Data(contentsOf: sound.file) == expected)
        }
        let reloaded = UniPackFolder(rootFolder: installed)
        reloaded.load()
        reloaded.loadDetail()
        for (pad, expected) in [(0, Data([1])), (1, Data([2]))] {
            let sound = try #require(reloaded.soundTable?[0][pad][0]?.first)
            #expect(try Data(contentsOf: sound.file) == expected)
        }
    }

    @Test(arguments: [false, true])
    func canonicalFallbackUsesOriginalUTF16Order(reverse: Bool) async throws {
        let nfc = "한.wav"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        // Neither entry matches the mixed normalization of the request exactly.
        let request = "한".decomposedStringWithCanonicalMapping + "글.wav"
        var sounds = [("sounds/한글.wav", Data([1])),
                      ("sounds/" + "한글.wav".decomposedStringWithCanonicalMapping, Data([2]))]
        if reverse { sounds.reverse() }
        let archive = TestZip.stored([
            ("info", Self.info), ("keySound", Data("1 1 1 \(request)\n".utf8)),
        ] + sounds)
        let (pack, _, root) = try await Self.importArchive(archive)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(pack.errorDetail == nil)
        #expect(nfd.utf16.lexicographicallyPrecedes(nfc.utf16))
        let sound = try #require(pack.soundTable?[0][0][0]?.first)
        #expect(try Data(contentsOf: sound.file) == Data([2]))
    }

    @Test func canonicalFolderNamesKeepTheOriginalFullSoundPath() async throws {
        let nfc = "소리"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        let archive = TestZip.stored([
            ("Pack/info", Self.info),
            ("Pack/keySound", Data("1 1 1 \(nfc)/a.wav\n1 2 1 \(nfd)/a.wav\n".utf8)),
            ("Pack/sounds/\(nfc)/a.wav", Data([1])),
            ("Pack/sounds/\(nfd)/a.wav", Data([2])),
        ])
        let (pack, _, root) = try await Self.importArchive(archive)
        defer { try? FileManager.default.removeItem(at: root) }
        for (pad, expected) in [(0, Data([1])), (1, Data([2]))] {
            let sound = try #require(pack.soundTable?[0][pad][0]?.first)
            #expect(try Data(contentsOf: sound.file) == expected)
        }
    }

    @Test func aPackFileCannotReplaceTheImportedSoundIndex() async throws {
        let archive = TestZip.stored([
            ("info", Self.info),
            ("keySound", Data("1 1 1 .unipad-sound-paths.json\n1 2 1 a.wav\n1 3 1 .unipad-sound-paths.json/b.wav\n".utf8)),
            ("sounds/.unipad-sound-paths.json", Data([1])),
            ("sounds/a.wav", Data([2])),
            ("sounds/a.wav", Data([3])),
            ("sounds/.unipad-sound-paths.json/b.wav", Data([4])),
        ])
        let (pack, _, root) = try await Self.importArchive(archive)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(pack.errorDetail == nil)
        for (pad, expected) in [(0, Data([1])), (1, Data([3])), (2, Data([4]))] {
            let sound = try #require(pack.soundTable?[0][pad][0]?.first)
            #expect(try Data(contentsOf: sound.file) == expected)
        }
    }

    // MARK: Name encodings

    @Test func aCP949NameMarkedUTF8IsReadAsCP949() async throws {
        // C7 D1 is '한' in CP949 and not valid UTF-8; the entry still carries the UTF-8 flag.
        let archive = TestZip.storedRawNames([
            (Data("info".utf8), Self.info),
            (Data("keySound".utf8), Data("1 1 1 한.wav\n".utf8)),
            (Data("sounds/".utf8) + Data([0xC7, 0xD1]) + Data(".wav".utf8), Data([1])),
        ], utf8Flag: true)
        let (pack, _, root) = try await Self.importArchive(archive)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(pack.errorDetail == nil)
        #expect(Self.soundName(pack, x: 0)?.precomposedStringWithCanonicalMapping == "한.wav")
    }

    @Test func theUnicodePathFieldNamesTheEntry() async throws {
        // 89 B9 is '音' in Shift-JIS; the Info-ZIP Unicode Path field gives the name in UTF-8.
        let shiftJIS = Data("sounds/".utf8) + Data([0x89, 0xB9]) + Data(".wav".utf8)
        let mismatched = Data("sounds/".utf8) + Data([0x8A, 0x79]) + Data(".wav".utf8)
        let archive = TestZip.storedRawNames([
            (Data("info".utf8), Self.info),
            (Data("keySound".utf8), Data("1 1 1 音.wav\n1 2 1 楽.wav\n".utf8)),
            (shiftJIS, Data([1])),
            (mismatched, Data([2])),
        ], utf8Flag: false, extras: [
            Data(), Data(),
            TestZip.unicodePathExtra("sounds/音.wav", rawName: shiftJIS),
            // A field whose CRC belongs to another name was left by a renaming tool and is ignored.
            TestZip.unicodePathExtra("sounds/楽.wav", rawName: mismatched, crcOf: Data("other".utf8)),
        ])
        let (pack, _, root) = try await Self.importArchive(archive)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Self.soundName(pack, x: 0)?.precomposedStringWithCanonicalMapping == "音.wav")
        #expect(Self.soundName(pack, x: 1) == nil)
        #expect(pack.errorDetail == "keySound : [1 2 1 楽.wav] sound was not found")
    }
}

/// Folders spelled in two letter cases are two folders only on a case-sensitive disk, as on an iPhone;
/// the simulator's Mac disk usually is not.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["UNIPACK_CASE_ROOT"] != nil,
                "Requires an explicitly configured case-sensitive volume"))
struct CaseSensitiveArchiveEntryTests {
    @Test func foldersSpelledInTwoCasesBecomeOne() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UNIPACK_CASE_ROOT"] ?? "/", isDirectory: true)
        let archive = TestZip.stored([
            ("Pack/info", UniPackArchiveEntryTests.info),
            ("Pack/keySound", Data("1 1 1 a.wav\n1 2 1 b.wav\n".utf8)),
            ("Pack/Sounds/a.wav", Data([1])),
            ("pack/sounds/b.wav", Data([2])),
        ])
        let (pack, installed, root) = try await UniPackArchiveEntryTests.importArchive(archive, base: base)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(pack.errorDetail == nil)
        #expect(UniPackArchiveEntryTests.soundName(pack, x: 0) == "a.wav")
        #expect(UniPackArchiveEntryTests.soundName(pack, x: 1) == "b.wav")
        #expect(try FileManager.default.contentsOfDirectory(atPath: installed.path).sorted() == ["Sounds", "info", "keySound"])
    }
}
