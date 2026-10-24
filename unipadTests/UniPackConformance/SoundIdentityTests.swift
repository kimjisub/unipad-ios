import Foundation
import Testing
@testable import unipad

@MainActor
@Suite(.serialized)
struct SoundIdentityTests {
    @Test(arguments: ["KS-G620", "KS-G621", "KS-G622", "KS-G623", "KS-G624", "KS-G625"])
    func separatelyStoredCollisionsKeepTheirArchiveProvenance(id: String) async throws {
        let (corpus, sample) = try reference(id)
        let observed = try await ConformanceHarness.actual(for: sample, corpus: corpus)
        guard case .value(let actual) = observed else {
            Issue.record("preserved archive entries could not be traced: \(observed)")
            return
        }
        #expect(actual == sample.expected)
    }

    @Test func aCatalogCannotOverridePhysicalProvenanceOrDisambiguateEqualPayloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-catalog-\(UUID().uuidString)")
        let sounds = root.appendingPathComponent("sounds")
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("same source payload".utf8)
        try bytes.write(to: sounds.appendingPathComponent("a.wav"))
        try bytes.write(to: sounds.appendingPathComponent("separate.wav"))
        try ImportedSoundPaths.write([
            .init(name: "a.wav", stored: "a.wav", archiveEntry: "sounds/b.wav"),
            .init(name: "a.wav", stored: "separate.wav", archiveEntry: "sounds/a.wav"),
        ], in: sounds)
        let digest = ConformanceCorpus.sha256Hex(bytes)
        let entries = [ConformanceSoundIdentity.Entry(path: "sounds/a.wav", sha256: digest),
                       ConformanceSoundIdentity.Entry(path: "sounds/b.wav", sha256: digest)]
        #expect(try ConformanceSoundIdentity.source(for: sounds.appendingPathComponent("a.wav"), root: root, entries: entries).path == "sounds/a.wav")
        #expect(throws: ConformanceSoundIdentity.TraceError.self) {
            try ConformanceSoundIdentity.source(for: sounds.appendingPathComponent("separate.wav"), root: root, entries: entries)
        }
    }

    private func reference(_ id: String) throws -> (ConformanceCorpus, ConformanceCase) {
        let corpus = try ConformanceCorpus.load(name: "sound-identity-corpus")
        return (corpus, try #require(corpus.cases.first { $0.id == id }))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["UNIPACK_CONFORMANCE_OUT"] != nil &&
                   ProcessInfo.processInfo.environment["UNIPACK_SOUND_IDENTITY_OBSERVE"] != "1",
                   "Requires a shared evidence folder for ordinary unit checks"))
    func ordinaryChecksDoNotWriteIdentityDiagnosticsToSharedEvidence() async throws {
        let (corpus, sample) = try reference("KS-G601")
        let path = try #require(ProcessInfo.processInfo.environment["UNIPACK_CONFORMANCE_OUT"])
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = try await ConformanceHarness.actual(for: sample, corpus: corpus)
        let files = try FileManager.default.contentsOfDirectory(atPath: path)
        #expect(!files.contains { $0.hasSuffix("-identity.json") },
                "ordinary self-checks must not publish synthetic observations as shared evidence")
    }

    @Test func anExplicitReportKeepsDiagnosticsInItsOwnDirectory() async throws {
        let (corpus, sample) = try reference("KS-G601")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sound-identity-report-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await ConformanceHarness.actual(for: sample, corpus: corpus,
                                               identityReport: ConformanceReport(directory: directory))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["KS-G601-identity.json"])
        let diagnostic = try JSONValue(data: Data(contentsOf: directory.appendingPathComponent("KS-G601-identity.json")))
        #expect(diagnostic["selections"]?.array?.first?["sha256"]?.string ==
                "c92bf9a21f15a6d98067e19814d8c12724b8eeae3b5fda492b82391e32b11f0d")
    }

    @Test func originalArchiveSpellingIsComparedExactly() {
        let composed: JSONValue = ["archiveEntry": "sounds/caf\u{e9}.wav", "sha256": "same"]
        let decomposed: JSONValue = ["archiveEntry": "sounds/cafe\u{301}.wav", "sha256": "same"]
        #expect(composed != decomposed)
    }

    @Test func aSingleImportedSoundReportsItsOriginalEntryAndActualBytes() async throws {
        let corpus = try ConformanceCorpus.load(name: "sound-identity-corpus")
        let sample = try #require(corpus.cases.first { $0.id == "KS-G601" })
        let observed = try await ConformanceHarness.actual(for: sample, corpus: corpus)
        guard case .value(let actual) = observed else {
            Issue.record("the single archive entry could not be traced: \(observed)")
            return
        }
        let sound = try #require(actual["sounds"]?.array?.first?["queue"]?.array?.first)
        #expect(sound["archiveEntry"]?.string?.utf8.elementsEqual("sounds/소리.wav".utf8) == true)
        #expect(sound["sha256"]?.string == "c92bf9a21f15a6d98067e19814d8c12724b8eeae3b5fda492b82391e32b11f0d")
        #expect(sound["file"] == nil)
    }

    @Test func aWrongEntryWithTheSameBytesIsNotAPass() throws {
        let (_, sample) = try reference("KS-G601")
        var actual = try #require(sample.expected?.object)
        var sounds = try #require(actual["sounds"]?.array)
        var pad = try #require(sounds[0].object)
        var queue = try #require(pad["queue"]?.array)
        var sound = try #require(queue[0].object)
        sound["archiveEntry"] = "sounds/소리.wav"
        queue[0] = .object(sound); pad["queue"] = .array(queue)
        sounds[0] = .object(pad); actual["sounds"] = .array(sounds)
        #expect(sample.classify(.object(actual)).status == "fail")
    }

    @Test func aCorrectNameWithTheWrongBytesIsNotAPass() throws {
        let (_, sample) = try reference("KS-G601")
        let changed = try #require(sample.expected).serialized().replacingOccurrences(
            of: "c92bf9a21f15a6d98067e19814d8c12724b8eeae3b5fda492b82391e32b11f0d", with: "wrong-content")
        #expect(try sample.classify(JSONValue(data: Data(changed.utf8))).status == "fail")
    }

    @Test func changingTheExpectationDoesNotChangeTheObservation() async throws {
        let (corpus, sample) = try reference("KS-G601")
        let changed = ConformanceCase.replacing(sample, expected: ["loaded": false])
        let first = try await ConformanceHarness.actual(for: sample, corpus: corpus).classified(for: sample)
        let second = try await ConformanceHarness.actual(for: changed, corpus: corpus).classified(for: changed)
        #expect(first.actual == second.actual)
        #expect(first.outcome.status == "pass")
        #expect(second.outcome.status == "fail")
    }

    @Test func corruptingTheSelectedFileIsUnverifiedInsteadOfAPass() async throws {
        let (corpus, sample) = try reference("KS-G601")
        var deps = ConformanceDeps()
        let load = deps.load
        deps.load = { root in
            let pack = load(root)
            if let selected = pack.soundGet(c: 0, x: 0, y: 0) {
                // A payload that is not in the input ZIP cannot acquire provenance from its name.
                try? Data("corrupt selected bytes".utf8).write(to: selected.file)
            }
            return pack
        }
        let result = try await ConformanceHarness.actual(for: sample, corpus: corpus, deps: deps).classified(for: sample)
        #expect(result.outcome.status == "unverified")
    }

    @Test func selectingAnotherRealFileRecordsThatEntryInsteadOfTheExpectedAsset() async throws {
        let (corpus, sample) = try reference("KS-G601")
        let altered = ConformanceCase.replacing(sample, files: sample.files + [
            ConformanceFile(path: "sounds/other.wav", text: "different source bytes", base64: nil, asset: nil),
        ])
        var deps = ConformanceDeps()
        let load = deps.load
        deps.load = { root in
            let pack = load(root)
            pack.soundTable?[0][0][0] = Deque()
            pack.soundTable?[0][0][0]?.append(Sound(file: root.appendingPathComponent("sounds/other.wav"), loop: 0))
            return pack
        }
        let result = try await ConformanceHarness.actual(for: altered, corpus: corpus, deps: deps).classified(for: altered)
        #expect(result.outcome.status == "fail")
        #expect(result.actual["sounds"]?.array?.first?["queue"]?.array?.first?["archiveEntry"] == "sounds/other.wav")
    }

    @Test func overwritingUnusedContentsStillFailsWhenTheSelectionIsCorrect() async throws {
        let (corpus, sample) = try reference("KS-G620")
        // Put the desired bytes last, then explicitly overwrite the other path too. This injects
        // the same loss even on disks which preserve both canonical spellings as separate files.
        let altered = ConformanceCase.replacing(sample, files: Array(sample.files.prefix(2)) + sample.files.suffix(2).reversed())
        var deps = ConformanceDeps()
        let load = deps.load
        deps.load = { root in
            let pack = load(root)
            if let desired = pack.soundGet(c: 0, x: 0, y: 0)?.file,
               let bytes = try? Data(contentsOf: desired),
               let other = ImportedSoundPaths.files(in: root.appendingPathComponent("sounds"))
                .map({ root.appendingPathComponent("sounds").appendingPathComponent($0.stored) })
                .first(where: { $0 != desired }) {
                try? bytes.write(to: other)
            }
            return pack
        }
        let result = try await ConformanceHarness.actual(for: altered, corpus: corpus, deps: deps).classified(for: altered)
        #expect(result.actual == sample.expected)
        #expect(result.outcome.status == "fail")
    }

    @Test func identicalContentsWithAmbiguousOriginalSpellingsStayUnverified() async throws {
        let (corpus, sample) = try reference("KS-G601")
        let altered = ConformanceCase.replacing(sample, files: sample.files + [
            ConformanceFile(path: "sounds/소리.wav", text: nil, base64: nil, asset: "tone-440"),
        ])
        let result = try await ConformanceHarness.actual(for: altered, corpus: corpus).classified(for: altered)
        #expect(result.outcome.status == "unverified")
    }

    @Test func unsupportedZipFixturesAreRefused() throws {
        #expect(throws: ConformanceSoundIdentity.TraceError.self) {
            try ConformanceSoundIdentity.entries(in: TestZip.deflated([(name: "a", data: Data([1]))]))
        }
    }

    @Test(arguments: ["KS-G602", "KS-G603", "KS-G604"])
    func storageNormalizationAloneDoesNotFailASingleEntry(id: String) async throws {
        let (corpus, sample) = try reference(id)
        let result = try await ConformanceHarness.actual(for: sample, corpus: corpus).classified(for: sample)
        #expect(result.outcome.status == "pass")
    }
}
