import Foundation
import Testing
@testable import unipad

/// How entries are unpacked: every byte of an entry whatever size the archive declares for it,
/// ordinary names with dots kept, nothing written outside the destination, and an archive whose
/// list of entries is cut short refused rather than imported in part.
@MainActor
struct UniPackArchiveExtractionTests {
    private let root: URL
    private let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "UniPackArchiveExtractionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        destination = root.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func unzip(_ archive: Data) throws {
        let source = root.appending(path: "archive.zip")
        try archive.write(to: source)
        try FileManager.default.unzipItem(at: source, to: destination)
    }

    private func size(of file: URL) throws -> Int {
        try #require(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    /// The first and last bytes, without reading an entry of hundreds of megabytes into memory.
    private func ends(of file: URL) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let first = try handle.read(upToCount: 1) ?? Data()
        try handle.seek(toOffset: UInt64(try size(of: file) - 1))
        let last = try handle.read(upToCount: 1) ?? Data()
        return Array(first + last)
    }

    private func relativePaths(under folder: URL) -> [String] {
        (FileManager.default.subpaths(atPath: folder.path) ?? []).sorted()
    }

    // MARK: - Sizes

    /// An entry exactly as large as the archive says used to fill the buffer sized from that
    /// number, which was read as "maybe truncated" and decoded again into a buffer twice as large.
    @Test(arguments: [65_536, 1_000_000, 50_000_000])
    func entryOfItsDeclaredSizeIsUnpackedWhole(size: Int) throws {
        defer { cleanUp() }

        try unzip(TestZip.deflatedRepeating(0x5A, count: size, name: "sounds/long.wav"))

        let file = destination.appending(path: "sounds/long.wav")
        #expect(try self.size(of: file) == size)
        #expect(try ends(of: file) == [0x5A, 0x5A])
    }

    /// Doubling that buffer for an entry over half the 512 MB limit went past the limit, so a
    /// valid 300 MB sound failed the whole import.
    @Test func entryOverHalfTheLimitIsUnpacked() throws {
        defer { cleanUp() }
        let size = 300_000_000

        try unzip(TestZip.deflatedRepeating(0x00, count: size, name: "sounds/huge.wav"))

        let file = destination.appending(path: "sounds/huge.wav")
        #expect(try self.size(of: file) == size)
        #expect(try ends(of: file) == [0, 0])
    }

    /// The limit stays: an entry that decodes to more than 512 MB is refused even when the archive
    /// claims it is small.
    @Test func entryDecodingPastTheLimitIsRefused() throws {
        defer { cleanUp() }
        let archive = TestZip.deflatedRepeating(0x00, count: 512 * 1024 * 1024 + 1, name: "bomb.wav")
        var claimingSmall = archive
        let eocd = archive.count - 22
        let centralDirectory = Int(archive[eocd + 16]) | Int(archive[eocd + 17]) << 8
            | Int(archive[eocd + 18]) << 16 | Int(archive[eocd + 19]) << 24
        claimingSmall.replaceSubrange(centralDirectory + 24..<centralDirectory + 28, with: [0x00, 0x04, 0, 0])

        for archive in [archive, claimingSmall] {
            #expect(throws: UniPackImporter.ImportError.self) { try unzip(archive) }
        }
    }

    /// The archive's own size for an entry is only a claim; the entry's data says how much it holds.
    @Test(arguments: [0, 10, 2_000_000] as [UInt32])
    func entryIsUnpackedWholeWhateverSizeIsDeclared(declared: UInt32) throws {
        defer { cleanUp() }
        let content = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 * 7) })

        try unzip(TestZip.deflated([(name: "keySound", data: content)], declaringUncompressedSize: declared))

        #expect(try Data(contentsOf: destination.appending(path: "keySound")) == content)
    }

    // MARK: - Names

    @Test func namesWithDotsAreKeptAndNoEntryLeavesTheDestination() throws {
        defer { cleanUp() }
        let files: [(name: String, data: Data)] = [
            ("My Pack.../info", Data("title=Dots\n".utf8)),
            ("My Pack.../sounds/Hey...wav", Data("hey".utf8)),
            ("My Pack.../sounds/..hidden..wav", Data("hidden".utf8)),
            ("../escaped.txt", Data("out".utf8)),
            ("sounds/../../escaped-nested.txt", Data("out".utf8)),
            ("/escaped-absolute-\(UUID().uuidString).txt", Data("out".utf8)),
        ]

        try unzip(TestZip.stored(files))

        #expect(relativePaths(under: destination) == [
            "My Pack...", "My Pack.../info", "My Pack.../sounds", "My Pack.../sounds/..hidden..wav", "My Pack.../sounds/Hey...wav",
        ])
        #expect(relativePaths(under: root) == ["archive.zip", "out"] + relativePaths(under: destination).map { "out/\($0)" })
        #expect(try Data(contentsOf: destination.appending(path: "My Pack.../sounds/Hey...wav")) == Data("hey".utf8))
    }

    // MARK: - Damaged archives

    /// The end record promises more entries than the list holds: the archive was cut or damaged,
    /// and importing the entries that happen to be readable would install half a pack.
    @Test func archiveWithAShortEntryListIsRefused() async throws {
        defer { cleanUp() }
        var archive = TestZip.stored(Self.packFiles)
        let eocd = archive.count - 22
        archive.replaceSubrange(eocd + 8..<eocd + 12, with: [UInt8(Self.packFiles.count + 1), 0, UInt8(Self.packFiles.count + 1), 0])
        let source = root.appending(path: "short.zip")
        try archive.write(to: source)
        let workspace = root.appending(path: "packs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        await #expect(throws: UniPackImporter.ImportError.self) {
            try await UniPackImporter(stagingRoot: root.appending(path: "staging"))
                .importPack(from: source, to: workspace, delegate: nil)
        }
        #expect(relativePaths(under: workspace).isEmpty)
        #expect(relativePaths(under: root.appending(path: "staging")).isEmpty)
    }

    // MARK: - Importing a picked file

    /// The picker and "Open in UniPad" hand over the file itself; importing it copies what it needs
    /// and leaves the file as it was, and a second import of the same name gets the next free name.
    @Test func importingAFileKeepsItAndTakesTheNextFreeName() async throws {
        defer { cleanUp() }
        let archive = TestZip.deflated(Self.packFiles)
        let source = root.appending(path: "My Pack.zip")
        try archive.write(to: source)
        let workspace = root.appending(path: "packs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let importer = UniPackImporter(stagingRoot: root.appending(path: "staging"))

        let first = try await importer.importPack(from: source, to: workspace, delegate: nil)
        let second = try await importer.importPack(from: source, to: workspace, delegate: nil)

        #expect([first.lastPathComponent, second.lastPathComponent] == ["My Pack", "My Pack (2)"])
        #expect(try Data(contentsOf: source) == archive)
        #expect(try Data(contentsOf: second.appending(path: "keySound")) == Self.packFiles[1].data)
        #expect(relativePaths(under: root.appending(path: "staging")).isEmpty)
    }

    /// A cancelled import stops between entries and leaves neither a pack nor its staging folder.
    @Test func cancelledImportLeavesNothing() async throws {
        defer { cleanUp() }
        let source = root.appending(path: "Cancelled.zip")
        try TestZip.stored(Self.packFiles).write(to: source)
        let workspace = root.appending(path: "packs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let stagingRoot = root.appending(path: "staging")

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await UniPackImporter(stagingRoot: stagingRoot).importPack(from: source, to: workspace, delegate: nil)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(relativePaths(under: workspace).isEmpty)
        #expect(relativePaths(under: stagingRoot).isEmpty)
    }

    private static let packFiles: [(name: String, data: Data)] = [
        ("info", Data("title=Picked\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\n".utf8)),
        ("keySound", Data("1 1 1 a.wav\n".utf8)),
        ("sounds/a.wav", Data(repeating: 1, count: 4096)),
    ]
}
