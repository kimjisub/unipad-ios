import Foundation
import Testing
@testable import unipad

@MainActor
@Suite(.serialized)
struct ConformanceRegressionTests {
    @Test func anEmptyCaseFilterIsNotAPartialRun() {
        // This check runs with TEST_RUNNER_UNIPACK_CONFORMANCE_ONLY set to an empty string.
        if ProcessInfo.processInfo.environment["UNIPACK_CONFORMANCE_ONLY"] == "" {
            #expect(ConformanceReport.onlyPrefix == nil)
            #expect(ConformanceReport.assertions == "checked")
        }
    }

    @Test(arguments: [#""\u+041""#, #""\u-000""#, #""\u00g0""#])
    func unicodeEscapesRequireFourHexDigits(text: String) {
        #expect(throws: JSONValue.ParseError.self) { try JSONValue(data: Data(text.utf8)) }
    }

    @Test(.enabled("Requires a usable audio engine") { try await ConformanceHarness.audioEngineIsUsable() })
    func undecodableSoundsProduceAResultInsteadOfThrowing() async throws {
        let corpus = try ConformanceCorpus.load()
        let original = try #require(corpus.cases.first { $0.id == "RUN-S-001" })
        let bad = ConformanceCase.replacing(original, files: original.files.map {
            $0.path.hasPrefix("sounds/") ? ConformanceFile(path: $0.path, text: "not a wav file", base64: nil, asset: nil) : $0
        })
        let actual = try await ConformanceHarness.actual(for: bad, corpus: corpus)
        guard case .failed(let reason) = actual else {
            Issue.record("undecodable sounds did not produce a failure: \(actual)")
            return
        }
        #expect(reason.hasPrefix("RUN-S-001: no sound of the pack could be loaded:"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = ConformanceReport(directory: directory)
        let result = actual.classified(for: original)
        #expect(result.outcome.status == "fail")
        #expect(result.outcome.unexpected)
        report.record(original, outcome: result.outcome, actual: result.actual, corpus: corpus)
        let saved = try JSONValue(data: Data(contentsOf: directory.appendingPathComponent("ios.json")))
        #expect(saved["cases"]?.array?.first?["id"]?.string == original.id)
        #expect(saved["cases"]?.array?.first?["status"]?.string == "fail")
        #expect(saved["cases"]?.array?.first?["detail"]?.string == reason)
    }

    @Test func caseFilterTreatsOnlyAnEmptyValueAsUnset() {
        #expect(ConformanceReport.onlyPrefix(in: [:]) == nil)
        #expect(ConformanceReport.onlyPrefix(in: ["UNIPACK_CONFORMANCE_ONLY": ""]) == nil)
        #expect(ConformanceReport.onlyPrefix(in: ["UNIPACK_CONFORMANCE_ONLY": "RUN-S-"]) == "RUN-S-")
    }

    @Test(.enabled("Requires a usable audio engine") { try await ConformanceHarness.audioEngineIsUsable() })
    func loadingTimeoutProducesAFailedResult() async throws {
        let corpus = try ConformanceCorpus.load()
        let original = try #require(corpus.cases.first { $0.id == "RUN-S-001" })
        var deps = ConformanceDeps()
        deps.soundLoadTimeout = 0
        let actual = try await ConformanceHarness.actual(for: original, corpus: corpus, deps: deps)
        guard case .failed(let reason) = actual else {
            Issue.record("loading timeout did not fail: \(actual)")
            return
        }
        #expect(reason == "sounds did not finish loading within 0.0 s")
        #expect(actual.classified(for: original).outcome.unexpected)
    }

    @Test func aCorpusErrorKeepsAnInvocationAndReplacesAStaleReport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("ios.json")
        try Data(#"{"assertions":"checked","cases":[{"id":"stale"}]}"#.utf8).write(to: output)
        let load: () throws -> ConformanceCorpus = { throw ConformanceCorpus.LoadError.missing }
        #expect(ConformanceCorpus.caseIDs(load: load, onlyPrefix: "RUN-") == ["corpus-load-failed"])
        let report = ConformanceReport(directory: directory)
        #expect(throws: ConformanceCorpus.LoadError.self) { try report.loadCorpus(using: load) }
        let saved = try JSONValue(data: Data(contentsOf: output))
        #expect(saved["assertions"]?.string == "failed")
        #expect(saved["cases"]?.array == [])
        #expect(saved["error"]?.string == String(describing: ConformanceCorpus.LoadError.missing))
    }

    @Test func loadingListenerDistinguishesEngineAndDecodeFailures() {
        let engine = TestSoundLoadListener()
        engine.onException(ConformanceHarness.ConformanceError.harness("start"))
        #expect(engine.finished)
        #expect(engine.engineFailure != nil)
        #expect(engine.loadFailure == nil)
        let decoding = TestSoundLoadListener()
        decoding.onStart(soundCount: 1)
        decoding.onException(ConformanceHarness.ConformanceError.harness("decode"))
        #expect(decoding.finished)
        #expect(decoding.engineFailure == nil)
        #expect(decoding.loadFailure != nil)
    }
}
