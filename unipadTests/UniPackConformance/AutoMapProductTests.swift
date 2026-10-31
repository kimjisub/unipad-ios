import Foundation
import Testing
@testable import unipad

/// The five mapping cases from the public reference, separate from the full corpus copy. They run
/// the app's mapper on a parsed pack, with the case's sound lengths as its input, and observe the
/// commands in the saved file.
@MainActor
@Suite(.serialized)
struct AutoMapProductTests {
    @Test(arguments: ["MAP-P001", "MAP-P002", "MAP-P003", "MAP-P004", "MAP-P005"])
    func mappedCommandsMatchTheProductCase(id: String) async throws {
        let corpus = try ConformanceCorpus.load(name: "auto-map-product-cases", sourceFile: #filePath)
        let sample = try #require(corpus.cases.first { $0.id == id })
        try corpus.verifyFingerprint(of: sample)
        let observed = try await ConformanceHarness.actual(for: sample, corpus: corpus)
        let (outcome, actual) = observed.classified(for: sample)
        print("AUTO-MAP \(id) actual=\(actual.serialized())")
        #expect(outcome.status == "pass", "\(id): \(outcome.detail); actual=\(actual.serialized())")
    }
}
