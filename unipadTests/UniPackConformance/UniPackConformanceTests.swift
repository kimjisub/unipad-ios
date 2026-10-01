import Foundation
import Testing
@testable import unipad

/// Runs the shared conformance corpus (unipad.io meta/unipack-conformance) through iOS's real
/// UniPackFolder parser and the LED and sound runners, and reports one result per case.
///
/// Switches are environment variables of the test process. xcodebuild passes a variable on only when
/// it is given with the TEST_RUNNER_ prefix (`TEST_RUNNER_UNIPACK_CONFORMANCE_OUT=/path xcodebuild test …`):
/// - UNIPACK_CONFORMANCE_OUT: the directory ios.json is written to. Without it, the simulator's
///   temporary directory; the path is printed as UNIPACK-CONFORMANCE-OUT.
/// - UNIPACK_CONFORMANCE_ONLY: run only the cases whose id starts with this.
/// - UNIPACK_CONFORMANCE_DUMP: exactly `1` makes a record-only run (see ConformanceReport.recordOnly).
/// - UNIPACK_CONFORMANCE_REPRO_DESTROY: exactly `1` enables `destroyWhileARepeatedSoundIsCycling`.
@MainActor
@Suite(.serialized)
struct UniPackConformanceTests {
    static let corpus: ConformanceCorpus? = try? ConformanceCorpus.load()
    static let caseIDs: [String] = corpus?.cases.map(\.id) ?? []

    private func loadCorpus() throws -> ConformanceCorpus {
        try ConformanceCorpus.load()
    }

    private func find(_ id: String, in corpus: ConformanceCorpus) throws -> ConformanceCase {
        try #require(corpus.cases.first { $0.id == id }, "case \(id) is in the corpus")
    }

    private func value(_ actual: ConformanceActual) throws -> JSONValue {
        guard case .value(let json) = actual else { throw ConformanceHarness.ConformanceError.harness("case could not be observed: \(actual)") }
        return json
    }

    @Test func corpusIsIntact() throws {
        let corpus = try loadCorpus()
        #expect(Set(corpus.cases.map(\.id)).count == corpus.cases.count, "case ids are unique")
        for conformanceCase in corpus.cases {
            try corpus.verifyFingerprint(of: conformanceCase)
            if conformanceCase.determined {
                #expect(conformanceCase.expected != nil, "\(conformanceCase.id) states its expected result")
            } else {
                #expect(conformanceCase.question != nil, "\(conformanceCase.id) states the open question")
            }
        }
        #expect(!corpus.cases.isEmpty)
    }

    @Test(arguments: caseIDs)
    func conformanceCase(id: String) async throws {
        if let only = ProcessInfo.processInfo.environment["UNIPACK_CONFORMANCE_ONLY"], !id.hasPrefix(only) { return }
        let corpus = try loadCorpus()
        let conformanceCase = try find(id, in: corpus)
        try corpus.verifyFingerprint(of: conformanceCase)

        let outcome: ConformanceOutcome
        let recorded: JSONValue
        switch try await ConformanceHarness.actual(for: conformanceCase, corpus: corpus) {
        case .unverified(let reason):
            outcome = ConformanceOutcome(status: ConformanceStatus.unverified.rawValue, unexpected: false, detail: reason)
            recorded = .null
        case .value(let actual):
            outcome = conformanceCase.classify(actual)
            recorded = actual
        }
        ConformanceReport.shared.record(conformanceCase, outcome: outcome, actual: recorded, corpus: corpus)

        if ConformanceReport.recordOnly { return }
        #expect(!outcome.unexpected, "\(id): \(outcome.detail)\nactual: \(recorded.serialized())\nexpected: \(conformanceCase.expected?.serialized() ?? "-")")
    }

    @Test func thisRunAssertedEveryCase() {
        #expect(!ConformanceReport.recordOnly, "\(ConformanceReport.recordOnlyNotice)")
    }

    /// Reproduces unipad.io meta/unipack-conformance/RESULTS.md, "iOS: destroy() while a repeated sound
    /// is cycling": the engine is destroyed 0 to 29 ms after a press whose sound repeats. Loop 3 is the
    /// corpus value (RUN-S-005: two repeats of 10 ms); loop 50 keeps the sound cycling for half a
    /// second. A destroy() that does not return ends the process after 20 s. Off by default because it
    /// fails until SoundEngine is fixed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["UNIPACK_CONFORMANCE_REPRO_DESTROY"] == "1"))
    func destroyWhileARepeatedSoundIsCycling() async throws {
        let corpus = try loadCorpus()
        for round in 0..<30 {
            let keySound = round % 2 == 0 ? "1 1 1 a.wav 3" : "1 1 1 a.wav 50"
            let took = try await ConformanceHarness.destroyDuration(keySound: keySound, delayNanoseconds: UInt64(round) * 1_000_000, corpus: corpus)
            print("UNIPACK-CONFORMANCE-REPRO-DESTROY round \(round), keySound \(keySound), destroy() \(round) ms after the press took \(took.map { String(format: "%.1f ms", $0) } ?? "no time: no sound started")")
            #expect(try #require(took, "the audio engine started no sound") < 1000)
        }
    }

    // A comparison that cannot fail proves nothing: each of these breaks one thing the cases rely on.

    @Test func aChangedInputFileNoLongerMatchesTheFingerprint() throws {
        let corpus = try loadCorpus()
        let original = try find("KS-001", in: corpus)
        let altered = ConformanceCase.replacing(original, files: original.files.map {
            $0.path == "keySound" ? ConformanceFile(path: $0.path, text: ($0.text ?? "") + "\n1 2 2 c.wav", base64: nil, asset: nil) : $0
        })
        #expect(try corpus.fingerprint(of: altered.files) != original.fingerprint)
        #expect(throws: (any Error).self) { try corpus.verifyFingerprint(of: altered) }
    }

    @Test func aChangedExpectedCoordinateTurnsAPassIntoAFail() async throws {
        let corpus = try loadCorpus()
        let original = try find("KS-001", in: corpus)
        let actual = try value(await ConformanceHarness.actual(for: original, corpus: corpus))
        #expect(original.classify(actual).status == "pass")

        var expected = try #require(original.expected?.object)
        var sounds = try #require(expected["sounds"]?.array)
        var first = try #require(sounds[0].object)
        first["x"] = .int(try #require(first["x"]?.int) + 1)
        sounds[0] = .object(first)
        expected["sounds"] = .array(sounds)
        let shifted = ConformanceCase.replacing(original, expected: .object(expected))
        #expect(shifted.classify(actual).status == "fail")
    }

    @Test func aChangedInputFailsAgainstTheSameExpectedResult() async throws {
        let corpus = try loadCorpus()
        let original = try find("KS-001", in: corpus)
        let altered = ConformanceCase.replacing(original, files: original.files.map {
            $0.path == "keySound" ? ConformanceFile(path: $0.path, text: "1 2 1 a.wav\n2 4 3 b.wav", base64: nil, asset: nil) : $0
        })
        let actual = try value(await ConformanceHarness.actual(for: altered, corpus: corpus))
        #expect(original.classify(actual).status == "fail")
    }

    @Test func leavingTheParserCallOutFailsAParseCase() async throws {
        let corpus = try loadCorpus()
        let original = try find("KS-001", in: corpus)
        var deps = ConformanceDeps()
        deps.load = { UniPackFolder(rootFolder: $0) }
        let actual = try value(await ConformanceHarness.actual(for: original, corpus: corpus, deps: deps))
        #expect(original.classify(actual).status == "fail")
    }

    @Test func aSilentLedRunnerFailsARunCase() async throws {
        let corpus = try loadCorpus()
        let original = try find("RUN-L-001", in: corpus)
        let real = try value(await ConformanceHarness.actual(for: original, corpus: corpus))
        #expect(original.classify(real).status == "pass")

        var deps = ConformanceDeps()
        deps.ledEventOn = { _, _, _ in }
        let silent = try value(await ConformanceHarness.actual(for: original, corpus: corpus, deps: deps))
        #expect(original.classify(silent).status == "fail")
    }

    @Test func aPinnedDifferenceThatStopsOrChangesIsUnexpected() throws {
        let corpus = try loadCorpus()
        let original = try find("KS-001", in: corpus)
        let pinned = ConformanceCase.replacing(original, known: [ConformanceCorpus.platform: ConformanceKnown(status: "fail", actual: ["loaded": false], note: "pinned")])
        let expected = try #require(original.expected)
        #expect(pinned.classify(expected).unexpected)
        #expect(pinned.classify(["loaded": true]).unexpected)
        #expect(pinned.classify(["loaded": false]) == ConformanceOutcome(status: "fail", unexpected: false, detail: "pinned"))
    }

    @Test func anUndeterminedCaseIsNeverAPass() throws {
        let corpus = try loadCorpus()
        let open = try #require(corpus.cases.first { !$0.determined })
        #expect(open.classify(["loaded": true]).status == "unverified")
    }

    @Test func aCaseTheCorpusSaysIOSCannotObserveIsUnverifiedAndNotRun() async throws {
        let corpus = try loadCorpus()
        let original = try find("KS-001", in: corpus)
        let marked = ConformanceCase.replacing(original, unobserved: [ConformanceCorpus.platform: "not observable here"])
        guard case .unverified(let reason) = try await ConformanceHarness.actual(for: marked, corpus: corpus) else {
            Issue.record("the case was run")
            return
        }
        #expect(reason == "not observable here")
    }
}

extension ConformanceCase {
    static func replacing(
        _ base: ConformanceCase, files: [ConformanceFile]? = nil, expected: JSONValue? = nil, known: [String: ConformanceKnown]? = nil,
        unobserved: [String: String]? = nil
    ) -> ConformanceCase {
        ConformanceCase(
            id: base.id, layer: base.layer, title: base.title, files: files ?? base.files, fingerprint: base.fingerprint,
            determined: base.determined, expected: expected ?? base.expected, question: base.question,
            scenario: base.scenario, known: known ?? base.known, unobserved: unobserved ?? base.unobserved
        )
    }
}
