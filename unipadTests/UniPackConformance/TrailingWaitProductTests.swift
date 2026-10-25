import Foundation
import Testing
@testable import unipad

/// Two unchanged product cases from the public reference, separate from the full corpus copy.
/// They observe the production runner's end callback, liveness and suspended song clock.
@MainActor
@Suite(.serialized)
struct TrailingWaitProductTests {
    @Test(arguments: ["RUN-P001", "RUN-P002"])
    func trailingWaitMatchesTheProductCase(id: String) async throws {
        let corpus = try ConformanceCorpus.load(name: "trailing-wait-product-cases", sourceFile: #filePath)
        let sample = try #require(corpus.cases.first { $0.id == id })
        try corpus.verifyFingerprint(of: sample)
        let observed = try await ConformanceHarness.actual(for: sample, corpus: corpus)
        let (outcome, actual) = observed.classified(for: sample)
        print("TRAILING-WAIT \(id) actual=\(actual.serialized())")
        #expect(outcome.status == "pass", "\(id): \(outcome.detail); actual=\(actual.serialized())")
    }
}
