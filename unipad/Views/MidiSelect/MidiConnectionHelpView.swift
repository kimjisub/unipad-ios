import SwiftUI

/// Pending UI state only. Persisting and sending MIDI remain in applySelection().
struct MidiSelectState {
    private(set) var selectedIndex = 0
    private(set) var isExplicitSelection = false
    private(set) var isDetectedSelection = false
    private(set) var remainingSeconds: Int?
    private(set) var hasStartedAutorun = false
    var isHelpPresented = false

    mutating func restoreModel(_ index: Int) {
        selectedIndex = index
        isExplicitSelection = false
        isDetectedSelection = false
    }

    mutating func detectedModel(_ index: Int?) {
        if let index { selectedIndex = index }
        isExplicitSelection = false
        isDetectedSelection = true
    }

    mutating func selectModel(_ index: Int) {
        cancelAutorun()
        selectedIndex = index
        isExplicitSelection = true
        isDetectedSelection = false
    }

    mutating func startAutorun() -> Bool {
        guard !hasStartedAutorun else { return false }
        hasStartedAutorun = true
        remainingSeconds = 5
        return true
    }

    /// Returns true only when the existing automatic confirmation is due.
    mutating func tickAutorun() -> Bool {
        guard let seconds = remainingSeconds, seconds > 0 else { return false }
        remainingSeconds = seconds - 1
        return remainingSeconds == 0
    }

    mutating func cancelAutorun() {
        remainingSeconds = nil
    }

    mutating func openHelp() {
        cancelAutorun()
        isHelpPresented = true
    }

    var helpSupplement: MidiHelpSupplement {
        guard !isDetectedSelection else { return .none }
        switch selectedIndex {
        case 4: return isExplicitSelection ? .miniMK3 : .none
        case 2, 5: return .pro
        case 0, 1, 3: return .none
        default: return .other
        }
    }
}

nonisolated enum MidiHelpSupplement: Equatable {
    case none, miniMK3, pro, other
}

/// The approved help is translated in English and Korean. Missing translations
/// fall back per key to the English table without adding other language files.
enum MidiHelpText {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        let english = Bundle.main.url(forResource: "en", withExtension: "lproj")
            .flatMap { Bundle(url: $0) }?
            .localizedString(forKey: key, value: nil, table: nil)
        return bundle.localizedString(forKey: key, value: english, table: nil)
    }
}

struct MidiConnectionHelpView: View {
    @Environment(\.openURL) private var openURL
    let modelName: String
    let supplement: MidiHelpSupplement
    let onClose: () -> Void
    @State private var linkOpenFailed = false
    @AccessibilityFocusState private var titleFocused: Bool

    private static let manufacturerGuide = URL(string:
        "https://userguides.novationmusic.com/hc/en-gb/articles/23731330721682-Launchpad-Mini-MK3-s-Settings-menu"
    )!

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(MidiHelpText.text("midi_help_title"))
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("midi.help.title")
                            .accessibilityFocused($titleFocused)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(MidiHelpText.text("midi_help_close"), action: closeHelp)
                            .font(.body)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 44)
                            .fixedSize(horizontal: false, vertical: true)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("midi.help.close")
                    }
                    Text(String(format: MidiHelpText.text("midi_help_selected_model"), modelName))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("midi.help.model")
                }
                // Keep the fixed header readable on a short landscape screen;
                // the scrolling body still follows the full accessibility size.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .padding(16)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(MidiHelpText.text("midi_help_common"))
                        section("midi_help_not_listed_title", "midi_help_not_listed_body")
                        section("midi_help_no_lights_title", "midi_help_no_lights_body")
                        section("midi_help_crash_title", "midi_help_crash_body")
                        switch supplement {
                        case .miniMK3:
                            Text(MidiHelpText.text("midi_help_mini_mk3"))
                            Button(MidiHelpText.text("midi_help_manufacturer")) {
                                manufacturerGuideOpener(Self.manufacturerGuide) { accepted in
                                    linkOpenFailed = !accepted
                                }
                            }
                            .frame(minHeight: 44)
                            if linkOpenFailed {
                                Text(MidiHelpText.text("midi_help_link_failed"))
                                    .accessibilityIdentifier("midi.help.linkFailed")
                            }
                        case .pro:
                            Text(MidiHelpText.text("midi_help_pro"))
                        case .other:
                            Text(MidiHelpText.text("midi_help_other"))
                        case .none:
                            EmptyView()
                        }
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .accessibilityIdentifier("midi.help.body")
            }
            .foregroundStyle(AppColors.textPrimary)
            .background(AppColors.darkSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(width: min(640, geometry.size.width - 24), height: geometry.size.height - 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, closeHelp)
            .onAppear { titleFocused = true }
            .onChange(of: supplement) { _, _ in linkOpenFailed = false }
        }
    }

    private var manufacturerGuideOpener: OpenURLAction {
        #if DEBUG || UNIPAD_RELEASE_TESTS
        // Exercise SwiftUI's rejected-open completion in local and release-check
        // UI tests only. Store builds always use the system opener; a failed web
        // request is deliberately not treated as a rejected external open.
        if UserDefaults.standard.bool(forKey: "UniPadFirebaseLocalOnly"),
           ProcessInfo.processInfo.arguments.contains("-UniPadHelpRejectExternalURL") {
            return OpenURLAction { _ in .discarded }
        }
        #endif
        return openURL
    }

    private func closeHelp() {
        titleFocused = false
        onClose()
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(MidiHelpText.text(title))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(MidiHelpText.text(body))
        }
    }
}
