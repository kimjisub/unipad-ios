import Foundation
import Testing

/// An explicitly requested, partial baseline observation. Known app defects are failures, not
/// fixture updates. Keeping this separate preserves the existing shared corpus and observations.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["UNIPACK_SOUND_IDENTITY_OBSERVE"] == "1",
                             "Opt-in baseline observation of original archive names and contents"))
struct SoundIdentityObservationTests {
    @Test(arguments: ["KS-G601", "KS-G602", "KS-G603", "KS-G604", "KS-G620", "KS-G621", "KS-G622", "KS-G623", "KS-G624", "KS-G625"])
    func originalEntryAndContents(id: String) async throws {
        let corpus = try ConformanceCorpus.load(name: "sound-identity-corpus")
        let sample = try #require(corpus.cases.first { $0.id == id })
        try corpus.verifyFingerprint(of: sample)
        let observed: ConformanceActual
        do { observed = try await ConformanceHarness.actual(for: sample, corpus: corpus, identityReport: .shared) }
        catch { observed = .failed(String(describing: error)) }
        let result = observed.classified(for: sample)
        ConformanceReport.shared.record(sample, outcome: result.outcome, actual: result.actual, corpus: corpus)
        #expect(!result.outcome.unexpected, "\(id): \(result.outcome.detail)\nactual: \(result.actual.serialized())")
    }
}
