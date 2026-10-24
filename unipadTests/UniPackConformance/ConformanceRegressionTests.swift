import Foundation
import Darwin
import Testing
@testable import unipad

@MainActor
@Suite(.serialized)
struct ConformanceRegressionTests {
    @Test func caseSensitivityMatchesDistinctFileStorage() throws {
        let root = ProcessInfo.processInfo.environment["UNIPACK_CASE_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("case-storage-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Exclusive creation measures the namespace itself, independently of Foundation's lookup.
        let first = directory.appendingPathComponent("a").path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        try #require(first >= 0, "the first probe file can be created")
        _ = Darwin.close(first)
        let second = directory.appendingPathComponent("A").path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        let creationError = errno
        if second >= 0 {
            _ = Darwin.close(second)
        } else if creationError != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: creationError) ?? .EIO)
        }
        #expect(ConformanceHarness.caseSensitiveFileSystem == (second >= 0),
                "the report must describe distinct file storage, not exact-spelling lookup")
    }

    @Test(arguments: ["RUN-L-006", "RUN-L-007", "RUN-A-001", "RUN-A-002", "RUN-RP-003", "RUN-RP-004", "RUN-RP-005", "RUN-S-008", "RUN-S-009", "RUN-S-010", "RUN-S-012", "RUN-S-013"])
    func playbackCasesAreMeasured(id: String) async throws {
        let corpus = try ConformanceCorpus.load()
        let sample = try #require(corpus.cases.first { $0.id == id })
        let actual = try await ConformanceHarness.actual(for: sample, corpus: corpus)
        guard case .value(let value) = actual else {
            Issue.record("\(id) was not measured: \(actual)")
            return
        }
        #expect(sample.classify(value).status == "pass", "\(id): \(value.serialized())")
    }

    @Test(arguments: ["RUN-S-008", "RUN-S-009"])
    func omittingSoundOffFailsTheReleaseCase(id: String) async throws {
        let corpus = try ConformanceCorpus.load()
        let sample = try #require(corpus.cases.first { $0.id == id })
        var deps = ConformanceDeps()
        deps.soundOff = { _, _, _ in }
        let actual = try await ConformanceHarness.actual(for: sample, corpus: corpus, deps: deps)
        guard case .value(let value) = actual else {
            Issue.record("\(id) was not measured: \(actual)")
            return
        }
        #expect(sample.classify(value).status == "fail", "a release must stop the voice its press started")
    }

    @Test(arguments: ["RUN-S-012", "RUN-S-013"])
    func omittingTheChainObserverFailsTheQueueResetCase(id: String) async throws {
        let corpus = try ConformanceCorpus.load()
        let sample = try #require(corpus.cases.first { $0.id == id })
        var deps = ConformanceDeps()
        deps.setupChainObserver = { _ in }
        let actual = try await ConformanceHarness.actual(for: sample, corpus: corpus, deps: deps)
        guard case .value(let value) = actual else {
            Issue.record("\(id) was not measured: \(actual)")
            return
        }
        #expect(sample.classify(value).status == "fail", "the play screen must reset both queues on a chain change")
    }

    @Test(arguments: ["RUN-L-006", "RUN-L-007"])
    func omittingTheMainScreenAttachFailsTheExitCase(id: String) async throws {
        let corpus = try ConformanceCorpus.load()
        let sample = try #require(corpus.cases.first { $0.id == id })
        var deps = ConformanceDeps()
        deps.returnToMain = {}
        let actual = try await ConformanceHarness.actual(for: sample, corpus: corpus, deps: deps)
        guard case .value(let value) = actual else {
            Issue.record("\(id) was not measured: \(actual)")
            return
        }
        #expect(sample.classify(value).status == "fail", "runner shutdown alone must not stand in for screen cleanup")
    }

    @Test func omittingAutoplayStopFailsTheExitCase() async throws {
        let corpus = try ConformanceCorpus.load()
        let sample = try #require(corpus.cases.first { $0.id == "RUN-A-002" })
        var deps = ConformanceDeps()
        deps.stopAutoPlay = { _ in }
        let actual = try await ConformanceHarness.actual(for: sample, corpus: corpus, deps: deps)
        guard case .value(let value) = actual else {
            Issue.record("autoplay stop was not measured: \(actual)")
            return
        }
        #expect(sample.classify(value).status == "fail", "an uncancelled task must emit later presses on virtual time")
    }

    @Test func omittingAutoplayOffFailsTheHeldLoopCase() async throws {
        let corpus = try ConformanceCorpus.load()
        let sample = try #require(corpus.cases.first { $0.id == "RUN-RP-005" })
        var deps = ConformanceDeps()
        deps.turnOffAutoPlay = { _ in }
        let actual = try await ConformanceHarness.actual(for: sample, corpus: corpus, deps: deps)
        guard case .value(let value) = actual else {
            Issue.record("autoplay off was not measured: \(actual)")
            return
        }
        #expect(sample.classify(value).status == "fail", "omitting the screen's autoplay-off action must leave its endless sound playing")
    }

    @Test func anEmptyCaseFilterIsNotAPartialRun() {
        // This check runs with TEST_RUNNER_UNIPACK_CONFORMANCE_ONLY set to an empty string.
        if ProcessInfo.processInfo.environment["UNIPACK_CONFORMANCE_ONLY"] == "" {
            #expect(ConformanceReport.onlyPrefix == nil)
            #expect(ConformanceReport.assertions == "checked")
        }
    }

    @Test func aCopyThatDoesNotHashToItsCorpusSha256OrHasNoneIsRefused() throws {
        let data = Data(#"{"cases":[{"id":"KS-001"}]}"#.utf8)
        let digest = ConformanceCorpus.sha256Hex(data) + "  corpus.json\n"
        #expect(try ConformanceCorpus.verifyDigest(of: data, digestFile: digest) == ConformanceCorpus.sha256Hex(data))
        var changed = data
        changed[changed.firstIndex(of: UInt8(ascii: "K"))!] ^= 1
        #expect(throws: ConformanceCorpus.LoadError.self) { try ConformanceCorpus.verifyDigest(of: changed, digestFile: digest) }
        #expect(throws: ConformanceCorpus.LoadError.self) { try ConformanceCorpus.verifyDigest(of: data, digestFile: nil) }
        #expect(throws: ConformanceCorpus.LoadError.self) {
            try ConformanceCorpus.verifyDigest(of: data, digestFile: digest.trimmingCharacters(in: .whitespacesAndNewlines))
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

    @Test func distinctInputSourcesAreNeverReportedAsVerified() async throws {
        for flags in [#""screenInputs":true,"scenario":[]"#,
                      #""scenario":[{"do":"press","input":"pointer:1"}]"#] {
            let data = Data((#"{"assets":{},"cases":[{"id":"inputs","layer":"run","title":"inputs","files":[],"fingerprint":"test","expectation":"determined","expected":{},"#
                + flags + "}]}").utf8)
            let corpus = try ConformanceCorpus.parse(data, source: "test")
            let sample = try #require(corpus.cases.first)
            guard case .unverified = try await ConformanceHarness.actual(for: sample, corpus: corpus) else {
                Issue.record("a scenario whose screen input sources are not driven must be unverified")
                continue
            }
        }
    }

    @Test func archiveIdentityComparesCodePointsAndContents() throws {
        let data = Data(#"{"assets":{},"cases":[{"id":"identity","layer":"parse","title":"identity","files":[],"fingerprint":"test","expectation":"determined","soundIdentity":true,"expected":{"archiveEntry":"sounds/한.wav","sha256":"first"}}]}"#.utf8)
        let sample = try #require(ConformanceCorpus.parse(data, source: "test").cases.first)
        let exact: JSONValue = ["archiveEntry": .string("sounds/한.wav"), "sha256": "first"]
        let otherName: JSONValue = ["archiveEntry": .string("sounds/한.wav".decomposedStringWithCanonicalMapping), "sha256": "first"]
        let otherContents: JSONValue = ["archiveEntry": .string("sounds/한.wav"), "sha256": "second"]
        #expect(sample.classify(exact).status == "pass")
        #expect(sample.classify(otherName).status == "fail")
        #expect(sample.classify(otherContents).status == "fail")
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
