import Foundation
@testable import unipad

/// Observes the importer's output without changing its extraction or the parser's file selection.
/// Provenance comes from the actual stored ZIP payload, never an expected result or asset label.
enum ConformanceSoundIdentity {
    struct Entry {
        let path: String
        let sha256: String
    }

    enum TraceError: Error {
        case invalidStoredFixture
        case ambiguousSource(String)
    }

    /// These fixtures deliberately use stored UTF-8 ZIP entries with no data descriptors. Refuse
    /// other formats rather than applying the app's extractor again to build an observation.
    static func entries(in archive: Data) throws -> [Entry] {
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset + count <= archive.count else { throw TraceError.invalidStoredFixture }
            return (0..<count).reduce(0) { $0 | Int(archive[offset + $1]) << ($1 * 8) }
        }
        var cursor = 0
        var entries: [Entry] = []
        while try number(cursor, 4) == 0x0403_4B50 {
            guard try number(cursor + 6, 2) == 0x0800,
                  try number(cursor + 8, 2) == 0 else { throw TraceError.invalidStoredFixture }
            let count = try number(cursor + 18, 4)
            let nameLength = try number(cursor + 26, 2)
            let extraLength = try number(cursor + 28, 2)
            let nameStart = cursor + 30
            let bodyStart = nameStart + nameLength + extraLength
            let bodyEnd = bodyStart + count
            guard bodyEnd <= archive.count, nameStart + nameLength <= archive.count,
                  let name = String(data: archive.subdata(in: nameStart..<nameStart + nameLength), encoding: .utf8)
            else { throw TraceError.invalidStoredFixture }
            entries.append(Entry(path: name, sha256: ConformanceCorpus.sha256Hex(archive.subdata(in: bodyStart..<bodyEnd))))
            cursor = bodyEnd
        }
        guard !entries.isEmpty, try number(cursor, 4) == 0x0201_4B50 else { throw TraceError.invalidStoredFixture }
        return entries
    }

    /// A storage spelling alone cannot identify an archive entry on a normalization-insensitive
    /// disk. Both the selected file's bytes and its relative path must identify exactly one source.
    static func source(for file: URL, root: URL, entries: [Entry]) throws -> Entry {
        let path = relativePath(file, root: root)
        let digest = ConformanceCorpus.sha256Hex(try Data(contentsOf: file))
        let matching = entries.filter { $0.path.lowercased() == path.lowercased() && $0.sha256 == digest }
        guard matching.count == 1 else { throw TraceError.ambiguousSource(path) }
        return matching[0]
    }

    private static func relativePath(_ file: URL, root: URL) -> String {
        String(file.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))
    }

    static var observationRoot: URL {
        if let path = ProcessInfo.processInfo.environment["UNIPACK_SOUND_IDENTITY_ROOT"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    @MainActor
    /// Only an explicit report publishes diagnostics. Self-checks may mutate the imported pack
    /// and must never write those synthetic results to the shared observation folder.
    static func actual(for sample: ConformanceCase, corpus: ConformanceCorpus, deps: ConformanceDeps, report: ConformanceReport? = nil) async throws -> ConformanceActual {
        let fm = FileManager.default
        let scratch = observationRoot.appendingPathComponent("sound-identity-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let archive = scratch.appendingPathComponent("fixture.zip")
        try TestZip.stored(try sample.files.map { (name: $0.path, data: try corpus.bytes(of: $0)) }).write(to: archive)
        let archived = try entries(in: Data(contentsOf: archive))
        let workspace = scratch.appendingPathComponent("library", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let root = try await UniPackImporter(stagingRoot: scratch.appendingPathComponent("staging"))
            .importPack(from: archive, to: workspace, delegate: nil)
        let pack = deps.load(root)
        var parsed = ConformanceHarness.parseResult(pack, root: root).object ?? [:]

        let stored = try storedFiles(root: root)
        let soundEntries = archived.filter { $0.path.lowercased().hasPrefix("sounds/") }
        let lost = soundEntries.filter { original in
            !stored.contains { $0.path.lowercased() == original.path.lowercased() && $0.sha256 == original.sha256 }
        }
        var diagnostic: [String: JSONValue] = [
            "importRoot": .string(root.path),
            "archive": .array(archived.map { ["archiveEntry": .string($0.path), "sha256": .string($0.sha256)] }),
            "stored": .array(stored.map { ["storagePath": .string($0.path), "sha256": .string($0.sha256)] }),
            "lostContents": .array(lost.map { .string($0.path) }),
            "fileSystem": try fileSystem(at: scratch),
            "boundary": "UniPackImporter -> UniPackFolder -> soundGet -> selected file bytes; no speaker output observed",
        ]
        var selections: [JSONValue] = []
        var sounds: [JSONValue] = []
        do {
            for c in 0..<pack.chain {
                for x in 0..<pack.buttonX {
                    for y in 0..<pack.buttonY {
                        let count = pack.soundTable?[c][x][y]?.count ?? 0
                        guard count > 0 else { continue }
                        var queue: [JSONValue] = []
                        for index in 0..<count {
                            // SoundEngine.soundOn uses this same selection; soundGet(num:) leaves
                            // the real queue untouched while observing every selected item.
                            guard let sound = pack.soundGet(c: c, x: x, y: y, num: index) else {
                                throw TraceError.ambiguousSource("queue item disappeared")
                            }
                            let digest = ConformanceCorpus.sha256Hex(try Data(contentsOf: sound.file))
                            selections.append(["c": .int(c), "x": .int(x), "y": .int(y), "num": .int(index),
                                               "storagePath": .string(relativePath(sound.file, root: root)), "sha256": .string(digest)])
                            let original = try source(for: sound.file, root: root, entries: archived)
                            queue.append(["archiveEntry": .string(original.path), "sha256": .string(digest),
                                          "loop": .int(sound.loop), "wormhole": .int(sound.wormhole)])
                        }
                        sounds.append(["c": .int(c), "x": .int(x), "y": .int(y), "queue": .array(queue)])
                    }
                }
            }
        } catch {
            diagnostic["selections"] = .array(selections)
            diagnostic["traceError"] = .string(String(describing: error))
            try report?.writeIdentityDiagnostic(id: sample.id, value: .object(diagnostic))
            return .unverified("cannot uniquely trace the selected bytes to an original archive entry: \(error)")
        }
        if !pack.criticalError { parsed["sounds"] = .array(sounds) }
        let actual = JSONValue.object(parsed)
        diagnostic["selections"] = .array(selections)
        diagnostic["actual"] = actual
        try report?.writeIdentityDiagnostic(id: sample.id, value: .object(diagnostic))
        // Even a correct selection cannot excuse other source contents overwritten during import.
        if !lost.isEmpty { return .observedFailure(actual, "archive sound contents lost during import: \(lost.map(\.path))") }
        return .value(actual)
    }

    private static func storedFiles(root: URL) throws -> [Entry] {
        let fm = FileManager.default
        let paths = fm.subpaths(atPath: root.path) ?? []
        return try paths.sorted().compactMap { path in
            let file = root.appendingPathComponent(path)
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return Entry(path: path, sha256: ConformanceCorpus.sha256Hex(try Data(contentsOf: file)))
        }
    }

    private static func fileSystem(at root: URL) throws -> JSONValue {
        let fm = FileManager.default
        let probe = root.appendingPathComponent("filesystem-probe", isDirectory: true)
        try fm.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: probe) }
        try Data([1]).write(to: probe.appendingPathComponent("a"))
        try Data([2]).write(to: probe.appendingPathComponent("é"))
        let values = try root.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey])
        let caseAlias = try? Data(contentsOf: probe.appendingPathComponent("A"))
        let canonicalAlias = try? Data(contentsOf: probe.appendingPathComponent("e\u{301}"))
        return ["format": .string(values.volumeLocalizedFormatDescription ?? "unknown"),
                "root": .string(root.path),
                "caseSensitive": .bool(!fm.fileExists(atPath: probe.appendingPathComponent("A").path)),
                "caseAliasReadsOriginalBytes": .bool(caseAlias == Data([1])),
                "canonicalAliasReadsOriginalBytes": .bool(canonicalAlias == Data([2])),
                "canonicalSpellingsDistinct": .bool(!fm.fileExists(atPath: probe.appendingPathComponent("e\u{301}").path))]
    }
}
