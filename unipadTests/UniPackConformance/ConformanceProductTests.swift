import Foundation
import Testing
@testable import unipad

@MainActor
@Suite(.serialized)
struct ConformanceProductTests {
    private func sample(observation: String?, files: [JSONValue]) throws -> (ConformanceCorpus, ConformanceCase) {
        let document: JSONValue = .object([
            "assets": [:],
            "cases": [[
                "id": "operation-check", "layer": "parse", "title": "operation dispatch",
                "expectation": "determined", "fingerprint": .string(String(repeating: "0", count: 64)),
                "observation": observation.map(JSONValue.string) ?? .null, "files": .array(files),
                "expected": ["cost": "0", "exclusion": nil],
            ]],
        ])
        let corpus = try ConformanceCorpus.parse(Data(document.serialized().utf8), source: "test")
        return (corpus, try #require(corpus.cases.first))
    }

    @Test func anOperationRetainsItsObservationKind() throws {
        let (_, operation) = try sample(observation: "audio-cost", files: [])
        #expect(operation.observation == "audio-cost")
    }

    @Test func aCostOperationCallsAdmissionInsteadOfThePackParser() async throws {
        let (corpus, operation) = try sample(observation: "audio-cost", files: [
            ["path": "operation.json", "text": "{\"rate\":48000,\"channels\":2,\"frames\":\"0\"}"],
        ])
        var packLoads = 0
        var deps = ConformanceDeps()
        deps.load = { root in
            packLoads += 1
            return UniPackFolder(rootFolder: root)
        }
        let actual = try await ConformanceHarness.actual(for: operation, corpus: corpus, deps: deps)
        #expect(packLoads == 0, "an operation is not a UniPack")
        guard case .value(let value) = actual else {
            Issue.record("the admission operation was not observed: \(actual)")
            return
        }
        #expect(value == operation.expected)
    }

    @Test func anUnknownObservationIsRefusedBeforeLoadingAPack() async throws {
        let (corpus, operation) = try sample(observation: "misspelled-operation", files: [])
        var packLoads = 0
        var deps = ConformanceDeps()
        deps.load = { root in
            packLoads += 1
            return UniPackFolder(rootFolder: root)
        }
        let actual = try await ConformanceHarness.actual(for: operation, corpus: corpus, deps: deps)
        #expect(packLoads == 0)
        guard case .failed = actual else {
            Issue.record("an unregistered observation was not refused: \(actual)")
            return
        }
    }

    @Test func aMissingOperationInputIsAFailure() async throws {
        let (corpus, operation) = try sample(observation: "audio-cost", files: [])
        let actual = try await ConformanceHarness.actual(for: operation, corpus: corpus)
        guard case .failed = actual else {
            Issue.record("a missing operation input was not refused: \(actual)")
            return
        }
    }

    @Test func aMalformedOperationInputIsAFailure() async throws {
        let (corpus, operation) = try sample(observation: "audio-cost", files: [
            ["path": "operation.json", "text": "{\"rate\":\"wrong\"}"],
        ])
        let actual = try await ConformanceHarness.actual(for: operation, corpus: corpus)
        guard case .failed = actual else {
            Issue.record("a malformed operation input was not refused: \(actual)")
            return
        }
    }

    @Test func anOperationWithoutItsKindIsAFailure() async throws {
        let (corpus, operation) = try sample(observation: nil, files: [
            ["path": "operation.json", "text": "{}"],
        ])
        let actual = try await ConformanceHarness.actual(for: operation, corpus: corpus)
        guard case .failed = actual else {
            Issue.record("an operation without its kind reached the pack parser: \(actual)")
            return
        }
    }

    @Test func aChangedAdmissionResultCannotPassTheOperation() async throws {
        let (corpus, operation) = try sample(observation: "audio-cost", files: [
            ["path": "operation.json", "text": "{\"rate\":48000,\"channels\":2,\"frames\":\"0\"}"],
        ])
        var deps = ConformanceDeps()
        deps.audioCost = { _ in .init(cost: 99, exclusion: nil) }
        let actual = try await ConformanceHarness.actual(for: operation, corpus: corpus, deps: deps)
        let (outcome, _) = actual.classified(for: operation)
        #expect(outcome.status == "fail")
        #expect(outcome.unexpected)
    }

    @Test func fileInspectionUsesTheAppBoundary() async throws {
        let (corpus, operation) = try sample(observation: "audio-file", files: [
            ["path": "sound.wav", "text": "not audio"],
        ])
        var calls = 0
        var deps = ConformanceDeps()
        deps.inspectAudio = { _ in calls += 1; return .rejected(.readFailure) }
        let actual = try await ConformanceHarness.actual(for: operation, corpus: corpus, deps: deps)
        #expect(calls == 1)
        guard case .value(let value) = actual else {
            Issue.record("file inspection was not observed: \(actual)")
            return
        }
        #expect(value == ["exclusion": "READ_FAILURE"])
    }

}
