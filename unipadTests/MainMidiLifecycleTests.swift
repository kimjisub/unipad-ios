#if canImport(UIKit)
import Foundation
import Testing
@testable import unipad

extension PlayUsageRecordTests {
    @MainActor
    struct MainMidiLifecycleTests {
        /// The two notification subscribers may run in either order. Check the real manager's
        /// receiver, then send a MIDI pad through it and read the driver's feedback light.
        @Test(arguments: [true, false])
        func returningToPlayKeepsItsMidiInputAndLights(mainResumesFirst: Bool) async throws {
            try await PlayUsageScenario.run { s in
                let main = MainViewModel()
                let router = AppRouter()
                main.setupMidiController()
                defer { main.removeMidiController() }
                router.navigate(to: .play(packPath: "test"))
                try await s.loadReady()
                let device = ParserMidiDevice(driver: LaunchpadMK2Driver(), port: 0)
                defer { MidiManager.shared.overrideDriver(NotingDriver()) }
                try await Task.sleep(for: .milliseconds(50))

                main.onPause(currentRoute: router.currentRoute)
                s.vm.onPause()
                #expect(MidiManager.shared.controller == nil)
                if mainResumesFirst { main.onResume(currentRoute: router.currentRoute) }
                s.vm.onResume()
                let playController = try #require(MidiManager.shared.controller)
                if !mainResumesFirst { main.onResume(currentRoute: router.currentRoute) }
                #expect(MidiManager.shared.controller === playController, "the main screen took the play screen's MIDI receiver")

                device.clearMessages()
                try await device.send([midiWord(0x90, 81, 100)])
                try await s.waitWhile(timeout: 3) { s.firstInputSources.isEmpty }
                #expect(s.firstInputSources == ["midi"], "the MIDI pad did not reach the play screen")
                #expect(device.messages.contains([0x90, 81, 3]), "the play screen did not send the pad's feedback light")
                try await device.send([midiWord(0x90, 81, 0)])
            }
        }

        @Test func returningToMainConnectsAndLeavingMainDisconnects() {
            let main = MainViewModel()
            let router = AppRouter()
            defer { main.removeMidiController() }
            main.onResume(currentRoute: router.currentRoute)
            #expect(MidiManager.shared.controller != nil)
            main.onPause(currentRoute: router.currentRoute)
            #expect(MidiManager.shared.controller == nil)
        }

        @Test(arguments: [Route.play(packPath: "test"), .midiSelect, .settings, .store])
        func coveredMainIgnoresLifecycleNotifications(route: Route) throws {
            let main = MainViewModel()
            main.setupMidiController()
            defer { main.removeMidiController() }
            let receiver = try #require(MidiManager.shared.controller)
            main.onPause(currentRoute: route)
            #expect(MidiManager.shared.controller === receiver, "the covered main screen removed its receiver")
            main.onResume(currentRoute: route)
            #expect(MidiManager.shared.controller === receiver, "the covered main screen replaced the receiver")
        }
    }
}
#endif
