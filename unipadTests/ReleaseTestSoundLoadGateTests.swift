#if (DEBUG || UNIPAD_RELEASE_TESTS) && canImport(UIKit)
import Foundation
import Testing
@testable import unipad

struct ReleaseTestSoundLoadGateTests {
    nonisolated private final class WorkerCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var returned = false
        var hasReturned: Bool { lock.withLock { returned } }
        func markReturned() { lock.withLock { returned = true } }
    }

    @Test func onlyAnExplicitIsolatedSoundFailureLaunchCanHoldLoading() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ReleaseTestSoundLoadGate.configured(defaults: defaults) == nil)
        defaults.set(true, forKey: "UniPadReleaseHoldSoundLoad")
        defaults.set("sound-failure", forKey: "UniPadUITestLibrary")
        #expect(ReleaseTestSoundLoadGate.configured(defaults: defaults) == nil)
        defaults.set("not-a-token", forKey: "UniPadReleaseTest")
        #expect(ReleaseTestSoundLoadGate.configured(defaults: defaults) == nil)
        defaults.set(UUID().uuidString, forKey: "UniPadReleaseTest")
        #expect(ReleaseTestSoundLoadGate.configured(defaults: defaults) != nil)
        defaults.set(false, forKey: "UniPadReleaseHoldSoundLoad")
        #expect(ReleaseTestSoundLoadGate.configured(defaults: defaults) == nil)
        defaults.set(true, forKey: "UniPadReleaseHoldSoundLoad")
        defaults.set("standard", forKey: "UniPadUITestLibrary")
        #expect(ReleaseTestSoundLoadGate.configured(defaults: defaults) == nil)
    }

    @Test func theWorkerWaitsForHelpAndOnlyACoveredFailureCompletesTheHandshake() async throws {
        let gate = ReleaseTestSoundLoadGate()
        defer { gate.cancel() }
        let completion = WorkerCompletion()
        let worker = Task.detached {
            gate.observe(.loadStarted)
            completion.markReturned()
        }
        defer { gate.connectionHelpAppeared() }
        try await PlayUsageScenario.waitWhile(timeout: 5) { gate.status != "holding" }
        try #require(gate.status == "holding")
        #expect(!completion.hasReturned, "the worker read before help opened")
        gate.connectionHelpAppeared()
        await worker.value
        #expect(gate.status == "released-under-help")
        gate.completed(failed: true, covered: true)
        #expect(gate.status == "failed-under-cover")
    }

    @Test(arguments: [(false, true), (true, false)])
    func aSuccessfulOrUncoveredLoadCannotEstablishTheRequiredFailure(failed: Bool, covered: Bool) async throws {
        let gate = ReleaseTestSoundLoadGate()
        defer { gate.cancel() }
        let worker = Task.detached { gate.observe(.loadStarted) }
        try await PlayUsageScenario.waitWhile(timeout: 5) { gate.status != "holding" }
        try #require(gate.status == "holding")
        gate.connectionHelpAppeared()
        await worker.value
        gate.completed(failed: failed, covered: covered)
        #expect(gate.status == "unexpected-completion")
    }

    @Test func aFailureBeforeHelpCannotCountAsACoveredLoad() {
        let gate = ReleaseTestSoundLoadGate()
        gate.connectionHelpAppeared()
        gate.observe(.loadStarted)
        gate.completed(failed: true, covered: true)
        #expect(gate.status == "unexpected-completion")
    }

    @Test func closingThePackReleasesAHeldWorker() async throws {
        let gate = ReleaseTestSoundLoadGate()
        defer { gate.cancel() }
        let worker = Task.detached { gate.observe(.loadStarted) }
        try await PlayUsageScenario.waitWhile(timeout: 5) { gate.status != "holding" }
        try #require(gate.status == "holding")
        gate.cancel()
        await worker.value
        #expect(gate.status == "cancelled")
    }
}
#endif
