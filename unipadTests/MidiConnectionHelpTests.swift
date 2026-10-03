import Foundation
import Testing
@testable import unipad

struct MidiConnectionHelpTests {
    @Test func openingAndClosingHelpPermanentlyCancelsAutorun() {
        var state = MidiSelectState()
        let started = state.startAutorun()
        #expect(started)
        let notDue = state.tickAutorun()
        #expect(!notDue)
        state.openHelp()
        #expect(state.remainingSeconds == nil)
        #expect(state.isHelpPresented)
        for _ in 0..<6 {
            let due = state.tickAutorun()
            #expect(!due)
        }
        state.isHelpPresented = false
        let restarted = state.startAutorun()
        #expect(!restarted)
        for _ in 0..<6 {
            let due = state.tickAutorun()
            #expect(!due)
        }
        #expect(state.remainingSeconds == nil)
    }

    @Test func unusedHelpStillConfirmsOnTheFifthTick() {
        var state = MidiSelectState()
        let started = state.startAutorun()
        #expect(started)
        for _ in 0..<4 {
            let due = state.tickAutorun()
            #expect(!due)
        }
        let due = state.tickAutorun()
        #expect(due)
        let notDue = state.tickAutorun()
        #expect(!notDue)
    }

    @Test func selectingAModelCancelsAutorun() {
        var state = MidiSelectState()
        let started = state.startAutorun()
        #expect(started)
        state.selectModel(4)
        #expect(state.remainingSeconds == nil)
        #expect(state.selectedIndex == 4)
        #expect(state.helpSupplement == .miniMK3)
    }

    @Test func detectedMiniDoesNotEnableDedicatedHelp() {
        var state = MidiSelectState()
        state.detectedModel(4)
        #expect(state.helpSupplement == .none)
        state.selectModel(4)
        #expect(state.helpSupplement == .miniMK3)
        state.openHelp()
        state.detectedModel(4)
        #expect(state.isHelpPresented)
        #expect(state.helpSupplement == .none)
        #expect(state.selectedIndex == 4)
    }

    @Test func storedChoicesKeepModelGuidanceButMiniRequiresATap() {
        var state = MidiSelectState()
        state.restoreModel(4)
        #expect(state.helpSupplement == .none)
        state.restoreModel(2)
        #expect(state.helpSupplement == .pro)
        state.restoreModel(9)
        #expect(state.helpSupplement == .other)
        state.detectedModel(nil)
        #expect(state.selectedIndex == 9)
        #expect(state.helpSupplement == .none)
    }

    @Test(arguments: Array(0...10))
    func explicitModelUsesOnlyItsApprovedSupplement(_ index: Int) {
        var state = MidiSelectState()
        state.selectModel(index)
        let expected: MidiHelpSupplement = switch index {
        case 4: .miniMK3
        case 2, 5: .pro
        case 0, 1, 3: .none
        default: .other
        }
        #expect(state.helpSupplement == expected)
    }

    @MainActor @Test func readingHelpKeepsSelectionPreferencesAndDriver() {
        let saved = PreferenceManager.shared.launchpadConnectMethod
        let driver = MidiManager.shared.driver
        let log = MidiManager.shared.debugLog
        var state = MidiSelectState()
        state.selectModel(4)
        state.openHelp()
        state.isHelpPresented = false
        #expect(state.selectedIndex == 4)
        #expect(state.isExplicitSelection)
        #expect(PreferenceManager.shared.launchpadConnectMethod == saved)
        #expect(MidiManager.shared.driver === driver)
        #expect(MidiManager.shared.debugLog == log)
    }

    @Test(arguments: ["en", "ko"])
    func allApprovedStringsArePresent(_ language: String) throws {
        let table = try #require(LocalizationBundleTests.strings(for: language))
        let help = table.filter { $0.key.hasPrefix("midi_help_") }
        #expect(help.count == 15)
        #expect(help.values.allSatisfy { !$0.isEmpty })
        #expect(table["settings_ok"] == (language == "ko" ? "확인" : "OK"))
    }

    @Test func untranslatedHelpUsesEnglishPerKey() throws {
        let english = try #require(LocalizationBundleTests.strings(for: "en"))
        let languages = Bundle.main.localizations.filter { !["Base", "en", "ko"].contains($0) }
        for language in languages {
            let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: url))
            for (key, expected) in english where key.hasPrefix("midi_help_") {
                #expect(MidiHelpText.text(key, bundle: bundle) == expected, "\(language).\(key)")
            }
        }
    }
}
