import SwiftUI
import Testing
@testable import unipad

extension PlayUsageRecordTests {
    @MainActor
    struct PlaybackOptionParityTests {
        @Test(arguments: [false, true])
        func rectangularPadsKeepTheirDefaultLights(_ hasLED: Bool) async throws {
            try await PlayUsageScenario.run(keyLed: hasLED ? ["1 1 1": "on 1 1 00FF00\nd 100\n"] : [:],
                                            grid: .init(squareButton: false)) { s in
                try await s.loadReady()
                #expect(!s.vm.scbFeedbackLight.visible)
                #expect(s.vm.scbFeedbackLight.checked == !hasLED)
                #expect(s.vm.scbLed.checked == hasLED)
                #expect(s.vm.ledRunner?.active == (hasLED ? true : nil))
            }
        }

        @Test func startingAutoplayRestoresPlaybackLights() async throws {
            try await PlayUsageScenario.run(keyLed: ["1 1 1": "on 1 1 00FF00\nd 100\n"]) { s in
                try await s.loadReady()
                s.vm.scbLed.setChecked(false)
                s.vm.scbFeedbackLight.setChecked(true)
                s.vm.switchPlayMode(.autoPlay)
                #expect(s.vm.scbLed.checked)
                #expect(!s.vm.scbFeedbackLight.checked)
                #expect(s.vm.ledRunner?.active == true)
            }
        }

        @Test func unavailableScreenAndControllerChainsDoNothing() async throws {
            try await PlayUsageScenario.run(keySound: "1 1 1 a.wav\n1 1 1 a.wav\n", grid: .init(chain: 4)) { s in
                try await s.loadReady()
                s.press(); s.release()
                let pack = try #require(s.vm.unipack)
                try #require(pack.soundGet(c: 0, x: 0, y: 0)?.num == 1)
                var changes = 0
                let observer = s.vm.chain.addObserver { _, _ in changes += 1 }
                defer { s.vm.chain.removeObserver(id: observer) }
                for chain in [-1, 6, Int.max] { s.vm.selectChain(chain) }
                // MK2 chain seven, outside this pack's four chains.
                try await s.midi(cmd: 9, note: 29, velocity: 100)
                #expect(s.vm.chain.value == 0)
                #expect(changes == 0)
                #expect(pack.soundGet(c: 0, x: 0, y: 0)?.num == 1)
            }
        }

        @Test func pressedFeedbackHidesPackLightsUntilRelease() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                let cm = try #require(s.vm.channelManager)
                cm.add(x: 0, y: 0, channel: .led, color: 0xFF00FF00, code: 5)
                s.vm.refreshPadFromChannel(x: 0, y: 0)
                #expect(s.vm.padLedColors[0][0] != .clear)
                s.press()
                #expect(s.vm.padItems[0][0]?.channel == .pressed)
                #expect(s.vm.padLedColors[0][0] == .clear)
                s.release()
                #expect(s.vm.padItems[0][0]?.channel == .led)
                #expect(s.vm.padLedColors[0][0] != .clear)
                cm.add(x: 0, y: 0, channel: .guide, color: 0xFFFF0000, code: 3)
                s.press()
                #expect(s.vm.padItems[0][0]?.channel == .guide)
                #expect(s.vm.padLedColors[0][0] != .clear)
            }
        }

        @Test func autoplayDoesNotScheduleASoundsSecondChainChange() async throws {
            try await PlayUsageScenario.run(keySound: "1 1 1 a.wav 1 2\n", autoPlay: "on 1 1\nd 50\nc 3\nd 1000\n",
                                            grid: .init(chain: 3)) { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                var scheduled = 0
                engine.wormholeDelay = { scheduled += 1; await Task.yield() }
                var chains: [Int] = []
                let observer = s.vm.chain.addObserver { c, _ in chains.append(c) }
                defer { s.vm.chain.removeObserver(id: observer) }
                s.vm.switchPlayMode(.autoPlay)
                try await s.waitWhile { s.vm.chain.value != 2 }
                try #require(s.vm.chain.value == 2)
                #expect(scheduled == 0)
                #expect(chains == [1, 2], "only the parsed wormhole and explicit chain may change the chain")
            }
        }

        @Test func stoppingAutoplayCancelsPendingChainChanges() async throws {
            try await PlayUsageScenario.run(keySound: "1 1 1 a.wav 1 2\n", autoPlay: "d 1000\non 1 1\n",
                                            grid: .init(chain: 2)) { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                var waiting: CheckedContinuation<Void, Never>?
                engine.wormholeDelay = { await withCheckedContinuation { waiting = $0 } }
                s.vm.switchPlayMode(.autoPlay)
                s.press(); s.release()
                try await s.waitWhile(timeout: 2) { waiting == nil }
                try #require(waiting != nil)
                s.vm.switchPlayMode(.none)
                waiting?.resume()
                try await Task.sleep(for: .milliseconds(50))
                #expect(s.vm.chain.value == 0)
            }
        }
    }
}
