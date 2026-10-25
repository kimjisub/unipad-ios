#if canImport(UIKit)
import Foundation
import Testing
@testable import unipad

/// What the play screen does when a controller is connected, unplugged, or held while the option
/// window opens. The controller's messages go through the same `MidiController` the MIDI manager
/// calls, and its lights are recorded in place of a connected device.
extension PlayUsageRecordTests {
    @MainActor
    struct PlayLaunchpadConnectionTests {
        typealias LaunchpadRecorder = PlayScreenReturnTests.LaunchpadRecorder

        /// One pad with an endless sound and an endless light, so a held pad stays audible and lit
        /// until it is released.
        static let endlessKeySound = "1 1 1 a.wav 0\n"
        static let endlessKeyLed = ["1 1 1 0": "on 1 1 a 5\ndelay 50\noff 1 1\ndelay 50\n"]

        private func withLaunchpad(_ body: (LaunchpadRecorder, MidiController) async throws -> Void) async throws {
            let launchpad = LaunchpadRecorder()
            MidiManager.shared.overrideDriver(launchpad)
            defer { MidiManager.shared.overrideDriver(NotingDriver()) }
            // Replacing the driver reports the previous one as disconnected; let that arrive first.
            try await settle()
            let controller = try #require(MidiManager.shared.controller, "the play screen did not take the controller")
            try await body(launchpad, controller)
        }

        /// The controller's messages reach the play screen on the main actor, as from CoreMIDI.
        private func settle() async throws { try await Task.sleep(for: .milliseconds(50)) }

        private func soundsAndLightsStopped(_ s: PlayUsageScenario) async throws -> Bool {
            let engine = try #require(s.vm.soundEngine)
            let runner = try #require(s.vm.ledRunner)
            try await s.waitWhile(timeout: 2) { engine.activeVoiceCount > 0 || runner.isEventExist(x: 0, y: 0) }
            return engine.activeVoiceCount == 0 && !runner.isEventExist(x: 0, y: 0)
        }

        private func holdPadOnTheController(_ s: PlayUsageScenario, _ controller: MidiController) async throws {
            controller.onPadTouch(x: 0, y: 0, upDown: true, velocity: 127)
            let engine = try #require(s.vm.soundEngine)
            try await s.waitWhile(timeout: 2) { engine.activeVoiceCount == 0 }
            try #require(engine.activeVoiceCount > 0, "the held pad never sounded")
            try #require(s.vm.ledRunner?.isEventExist(x: 0, y: 0) == true, "the held pad never lit")
        }

        // MARK: - Connecting

        /// A pad with three sounds is played twice; connecting a Launchpad then is not a chain change,
        /// so the next press plays the third sound, not the first again.
        @Test func connectingAControllerKeepsEachPadsPlaceInItsSounds() async throws {
            try await PlayUsageScenario.run(keySound: "1 1 1 a.wav\n1 1 1 a.wav\n1 1 1 a.wav\n") { s in
                try await s.loadReady()
                let pack = try #require(s.vm.unipack)
                s.press(0, 0); s.release(0, 0)
                s.press(0, 0); s.release(0, 0)
                try await s.waitWhile(timeout: 2) { pack.soundGet(c: 0, x: 0, y: 0)?.num != 2 }
                try #require(pack.soundGet(c: 0, x: 0, y: 0)?.num == 2, "two presses did not move to the third sound")

                try await withLaunchpad { launchpad, controller in
                    controller.onAttach()
                    try await settle()
                    #expect(launchpad.sent.first == .clear, "the connected Launchpad was not drawn")
                    #expect(pack.soundGet(c: 0, x: 0, y: 0)?.num == 2, "connecting went back to the first sound")
                }
            }
        }

        /// The chain's light is drawn on the connected device.
        @Test func connectingAControllerDrawsTheChainLight() async throws {
            try await PlayUsageScenario.run(grid: .init(chain: 2)) { s in
                try await s.loadReady()
                try await withLaunchpad { launchpad, controller in
                    controller.onAttach()
                    try await settle()
                    let chainLight = LaunchpadRecorder.Command.functionKey(f: PlayViewModel.chainIndexOffset, velocity: 3)  // red, the selected chain
                    #expect(launchpad.sent.contains(chainLight), "chain 1's light was not drawn: \(launchpad.sent.filter { if case .functionKey = $0 { true } else { false } })")
                }
            }
        }

        @Test func proLiveModeRedrawsWithoutRestartingTheSoundSequence() async throws {
            try await PlayUsageScenario.run(keySound: "1 1 1 a.wav\n1 1 1 a.wav\n1 1 1 a.wav\n") { s in
                try await s.loadReady()
                let pack = try #require(s.vm.unipack)
                s.press(0, 0); s.release(0, 0)
                s.press(0, 0); s.release(0, 0)
                try await s.waitWhile(timeout: 2) { pack.soundGet(c: 0, x: 0, y: 0)?.num != 2 }
                try #require(pack.soundGet(c: 0, x: 0, y: 0)?.num == 2)
                try await withLaunchpad { launchpad, controller in
                    let decoder = MidiInputDecoder()
                    let events = decoder.decode([0x30160020, 0x2902102E, 0x30310000, 0], portIndex: 0)
                    try #require(events.count == 1)
                    for event in events {
                        controller.onUnknownEvent(cmd: event.cmd, sig: event.sig, note: event.note, velocity: event.velocity)
                    }
                    try await settle()
                    #expect(launchpad.sent.first == .clear)
                    #expect(launchpad.sent.contains(.functionKey(f: 8, velocity: 3)))
                    #expect(pack.soundGet(c: 0, x: 0, y: 0)?.num == 2)
                }
            }
        }

        // MARK: - Holding a pad

        @Test func releasingAHeldPadWithTheOptionWindowOpenStopsIt() async throws {
            try await PlayUsageScenario.run(keySound: Self.endlessKeySound, keyLed: Self.endlessKeyLed) { s in
                try await s.loadReady()
                try await withLaunchpad { _, controller in
                    try await holdPadOnTheController(s, controller)
                    s.vm.toggleOptionWindow(true)
                    controller.onPadTouch(x: 0, y: 0, upDown: false, velocity: 0)
                    #expect(try await soundsAndLightsStopped(s), "the endless sound or light went on after the release")
                }
            }
        }

        /// A press with the option window open changes settings, not a pad: its release plays nothing either.
        @Test func aPadPressedWithTheOptionWindowOpenStaysSilent() async throws {
            try await PlayUsageScenario.run(keySound: Self.endlessKeySound, keyLed: Self.endlessKeyLed) { s in
                try await s.loadReady()
                try await withLaunchpad { _, controller in
                    s.vm.toggleOptionWindow(true)
                    controller.onPadTouch(x: 0, y: 0, upDown: true, velocity: 127)
                    controller.onPadTouch(x: 0, y: 0, upDown: false, velocity: 0)
                    try await settle()
                    #expect(s.vm.soundEngine?.playsStarted == 0)
                }
            }
        }

        /// Unplugged, the controller never sends the release of the pad it was holding.
        @Test func unpluggingTheControllerReleasesThePadItHeld() async throws {
            try await PlayUsageScenario.run(keySound: Self.endlessKeySound, keyLed: Self.endlessKeyLed) { s in
                try await s.loadReady()
                try await withLaunchpad { _, controller in
                    try await holdPadOnTheController(s, controller)
                    controller.onDetach()
                    #expect(try await soundsAndLightsStopped(s), "the endless sound or light went on after the controller was unplugged")
                }
            }
        }

        /// The play screen stops taking the controller's messages while the app is away, so the release
        /// of a pad held then would never arrive.
        @Test func leavingTheAppReleasesThePadTheControllerHeld() async throws {
            try await PlayUsageScenario.run(keySound: Self.endlessKeySound, keyLed: Self.endlessKeyLed) { s in
                try await s.loadReady()
                try await withLaunchpad { _, controller in
                    try await holdPadOnTheController(s, controller)
                    s.vm.onPause()
                    #expect(try await soundsAndLightsStopped(s), "the endless sound or light went on after the app was left")
                    s.vm.onResume()
                }
            }
        }

        /// A finger on the screen is not the controller's: unplugging leaves that pad held.
        @Test func unpluggingTheControllerLeavesAScreenPressHeld() async throws {
            try await PlayUsageScenario.run(keySound: Self.endlessKeySound, keyLed: Self.endlessKeyLed) { s in
                try await s.loadReady()
                try await withLaunchpad { _, controller in
                    s.press(0, 0)
                    let engine = try #require(s.vm.soundEngine)
                    try await s.waitWhile(timeout: 2) { engine.activeVoiceCount == 0 }
                    controller.onDetach()
                    try await settle()
                    #expect(engine.activeVoiceCount > 0, "the screen press was released with the controller")
                    s.release(0, 0)
                }
            }
        }

        @Test func unpluggingTheControllerKeepsTheSamePadsScreenPressVisible() async throws {
            try await PlayUsageScenario.run(keySound: Self.endlessKeySound) { s in
                try await s.loadReady()
                try await withLaunchpad { _, controller in
                    let finger = UUID()
                    let channels = try #require(s.vm.channelManager)
                    let engine = try #require(s.vm.soundEngine)
                    controller.onPadTouch(x: 0, y: 0, upDown: true, velocity: 127)
                    try await s.waitWhile(timeout: 2) { engine.activeVoiceCount == 0 }
                    try #require(engine.activeVoiceCount > 0, "the controller's press must arrive first")
                    try #require(channels.get(x: 0, y: 0, channel: .pressed) != nil)
                    s.vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen), inputID: finger)
                    try #require(channels.get(x: 0, y: 0, channel: .pressed) != nil)

                    controller.onDetach()
                    try await settle()
                    #expect(engine.activeVoiceCount > 0, "the screen's sound must remain held")
                    #expect(channels.get(x: 0, y: 0, channel: .pressed) != nil,
                            "unplugging must not clear a finger's pressed feedback on the same pad")

                    s.vm.padTouch(x: 0, y: 0, isDown: false, trigger: .pad(.screen), inputID: finger)
                    #expect(channels.get(x: 0, y: 0, channel: .pressed) == nil)
                }
            }
        }

        // MARK: - Logo

        /// A pack lights the logo; after a reconnection the logo shows the same light again.
        @Test func theLogoLightIsDrawnAgainOnConnecting() async throws {
            try await PlayUsageScenario.run(keySound: Self.endlessKeySound, keyLed: ["1 1 1": "on l a 9\n"]) { s in
                try await s.loadReady()
                s.vm.scbProLightMode.setChecked(true)
                try await withLaunchpad { launchpad, controller in
                    s.press(0, 0); s.release(0, 0)
                    let logo = LaunchpadRecorder.Command.functionKey(f: 32, velocity: 9)
                    try await s.waitWhile(timeout: 2) { !launchpad.sent.contains(logo) }
                    try #require(launchpad.sent.contains(logo), "the logo never lit")

                    launchpad.forget()
                    controller.onAttach()
                    try await settle()
                    #expect(launchpad.sent.last(where: { if case .functionKey(32, _) = $0 { true } else { false } }) == logo,
                            "the logo was not drawn again: \(launchpad.sent.filter { if case .functionKey(32, _) = $0 { true } else { false } })")

                    launchpad.forget()
                    s.vm.scbProLightMode.setChecked(false)
                    controller.onAttach()
                    try await settle()
                    #expect(!launchpad.sent.contains(logo), "the logo was drawn with the pro light mode off")
                }
            }
        }
    }
}
#endif
