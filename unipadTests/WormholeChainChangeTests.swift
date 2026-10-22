import Foundation
import Testing
@testable import unipad

extension PlayUsageRecordTests {
    /// A sound with a wormhole moves the chain a moment after the press. The tests hold that moment
    /// open instead of waiting it out, and act inside it: a chain the player picks in the meantime
    /// stays picked, and a closed screen's chain stays where it was.
    @MainActor
    struct WormholeChainChangeTests {
        /// Pad (1,1) of chain 1 plays once and moves to chain 2; the pack has three chains.
        private static let keySound = "1 1 1 a.wav 1 2\n2 1 1 a.wav\n3 1 1 a.wav\n"

        @MainActor
        private final class HeldDelay {
            private var waiters: [CheckedContinuation<Void, Never>] = []
            var waiting: Int { waiters.count }
            func wait() async { await withCheckedContinuation { waiters.append($0) } }
            func end() {
                let ended = waiters
                waiters.removeAll()
                for waiter in ended { waiter.resume() }
            }
        }

        private static func run(_ body: (PlayUsageScenario, HeldDelay) async throws -> Void) async throws {
            try await PlayUsageScenario.run(keySound: keySound, chains: 3) { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let delay = HeldDelay()
                engine.wormholeDelay = { await delay.wait() }
                s.press(0, 0)
                s.release(0, 0)
                try await s.waitWhile(timeout: 2) { delay.waiting == 0 }
                try #require(delay.waiting == 1, "the press did not start a wormhole")
                try #require(s.vm.chain.value == 0, "the chain moved before the wormhole's delay ended")
                try await body(s, delay)
            }
        }

        /// The wormhole's chain change is queued on the main actor when the delay ends; anything
        /// queued after it, such as this sleep's end, runs after it.
        private static func settle() async throws {
            try await Task.sleep(for: .milliseconds(50))
        }

        @Test func theChainMovesWhenTheDelayEnds() async throws {
            try await Self.run { s, delay in
                delay.end()
                try await s.waitWhile(timeout: 2) { s.vm.chain.value == 0 }
                #expect(s.vm.chain.value == 1)
            }
        }

        @Test func aChainPickedOnScreenDuringTheDelayStays() async throws {
            try await Self.run { s, delay in
                s.vm.selectChain(2)
                delay.end()
                try await Self.settle()
                #expect(s.vm.chain.value == 2, "the wormhole replaced the chain the player picked")
            }
        }

        @Test func aChainPickedOnTheLaunchpadDuringTheDelayStays() async throws {
            try await Self.run { s, delay in
                try await s.midi(cmd: 9, note: 69, velocity: 100) // Chain 3 on a Launchpad MK2.
                try await s.midi(cmd: 9, note: 69, velocity: 0)
                try #require(s.vm.chain.value == 2, "the Launchpad chain key did not select chain 3")
                delay.end()
                try await Self.settle()
                #expect(s.vm.chain.value == 2, "the wormhole replaced the chain the player picked")
            }
        }

        @Test func aClosedScreenKeepsItsChain() async throws {
            try await Self.run { s, delay in
                s.vm.cleanup()
                delay.end()
                try await Self.settle()
                #expect(s.vm.chain.value == 0, "the wormhole moved the chain of a closed screen")
            }
        }
    }
}
