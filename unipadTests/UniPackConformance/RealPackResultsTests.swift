import Foundation
import Testing
@testable import unipad

/// Reads real pack folders with the same parser call and normalized result as the conformance cases,
/// for unipad.io meta/unipack-conformance/real-packs to compare with Android and the web. It runs only
/// when given a folder; an ordinary test run skips it.
///
/// Environment variables of the test process (give them to xcodebuild with the TEST_RUNNER_ prefix):
/// - UNIPACK_REAL_PACKS: a folder holding one folder per pack, named by its id.
/// - UNIPACK_REAL_PACKS_OUT: where `ios/<id>.json` and `ios.run.json` are written (default: the
///   simulator's temporary directory, printed as UNIPACK-REAL-PACKS-OUT).
/// - UNIPACK_REAL_PACKS_ONLY: comma separated ids to read; every pack folder without it.
@Suite(.serialized)
struct RealPackResultsTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static let idPattern = /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/

    /// The pack folders under `directory` in id order, the same selection as real-packs/packs.mjs listPacks.
    static func packFolders(in directory: URL, only: Set<String>?) throws -> [URL] {
        let all = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent.wholeMatch(of: idPattern) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let only else { return all }
        let missing = only.subtracting(all.map(\.lastPathComponent))
        if !missing.isEmpty { throw ConformanceHarness.ConformanceError.harness("no pack folder for \(missing.sorted().joined(separator: ", ")) in \(directory.path)") }
        return all.filter { only.contains($0.lastPathComponent) }
    }

    @Test func soundsBelowACapitalisedSoundsFolderAreNamedFromInsideIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("real-pack-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sounds/kick"), withIntermediateDirectories: true)
        try Data("title=t\nproducerName=p\nbuttonX=2\nbuttonY=2\nchain=1".utf8).write(to: root.appendingPathComponent("info"))
        try Data("1 1 1 kick/a.wav".utf8).write(to: root.appendingPathComponent("keySound"))
        try Data(count: 4).write(to: root.appendingPathComponent("Sounds/kick/a.wav"))
        let result = ConformanceHarness.parseResult(ConformanceDeps().load(root), root: root)
        guard case .array(let sounds)? = result.object?["sounds"], case .array(let queue)? = sounds.first?.object?["queue"] else {
            Issue.record("no sounds in \(result.serialized())"); return
        }
        #expect(queue.first?.object?["file"] == "kick/a.wav")
    }

    @Test(.enabled(if: environment["UNIPACK_REAL_PACKS"] != nil))
    func readEveryPack() throws {
        let packsDirectory = URL(fileURLWithPath: Self.environment["UNIPACK_REAL_PACKS"]!, isDirectory: true)
        let out = Self.environment["UNIPACK_REAL_PACKS_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("unipack-real-packs", isDirectory: true)
        let only = Self.environment["UNIPACK_REAL_PACKS_ONLY"].map {
            Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        print("UNIPACK-REAL-PACKS-OUT \(out.path)")

        let packs = try Self.packFolders(in: packsDirectory, only: only)
        let directory = out.appendingPathComponent(ConformanceCorpus.platform, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for folder in packs {
            let id = folder.lastPathComponent
            let pack = ConformanceDeps().load(folder)
            let line: JSONValue = ["platform": .string(ConformanceCorpus.platform), "id": .string(id), "actual": ConformanceHarness.parseResult(pack, root: folder)]
            try Data((line.serialized() + "\n").utf8).write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
            print("UNIPACK-REAL-PACK \(id) ok")
        }
        let run: JSONValue = [
            "platform": .string(ConformanceCorpus.platform), "generatedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "packs": .array(packs.map { .string($0.lastPathComponent) }),
        ]
        try Data((run.serialized() + "\n").utf8).write(to: out.appendingPathComponent("\(ConformanceCorpus.platform).run.json"), options: .atomic)
    }
}
