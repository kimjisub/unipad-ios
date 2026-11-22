import SwiftUI

/// Pending UI state only. Persisting and sending MIDI remain in applySelection().
struct MidiSelectState {
    private(set) var selectedIndex = 0
    /// Where the selected model came from; nil while no device is connected or its model is unknown.
    private(set) var modelSource: MidiModelSource?
    private(set) var remainingSeconds: Int?
    private(set) var hasStartedAutorun = false
    var isHelpPresented = false

    /// No device is connected: show the saved model without a source.
    mutating func restoreModel(_ index: Int) {
        selectedIndex = index
        modelSource = nil
    }

    mutating func detectedModel(_ index: Int?) {
        if let index { selectedIndex = index }
        modelSource = .automatic
    }

    /// The device connected, but no model matched it.
    mutating func unrecognisedModel(_ index: Int?) {
        if let index { selectedIndex = index }
        modelSource = nil
    }

    /// The connected device runs on a model chosen before this screen opened.
    mutating func earlierChoice(_ index: Int) {
        selectedIndex = index
        modelSource = .manual
    }

    mutating func selectModel(_ index: Int) {
        cancelAutorun()
        selectedIndex = index
        modelSource = .manual
    }

    mutating func deviceLeft() {
        modelSource = nil
    }

    /// Starts the existing five-second confirmation once per screen, and only for a connected device
    /// whose model was recognised automatically.
    mutating func startAutorun(for status: MidiConnectionStatus) -> Bool {
        guard !hasStartedAutorun else { return false }
        hasStartedAutorun = true
        guard status.allowsAutomaticConfirmation, modelSource == .automatic else { return false }
        remainingSeconds = 5
        return true
    }

    /// Returns true only when the existing automatic confirmation is due.
    mutating func tickAutorun() -> Bool {
        guard let seconds = remainingSeconds, seconds > 0 else { return false }
        remainingSeconds = seconds - 1
        return remainingSeconds == 0
    }

    mutating func statusChanged(to status: MidiConnectionStatus) {
        if !status.allowsAutomaticConfirmation || modelSource != .automatic { cancelAutorun() }
    }

    mutating func cancelAutorun() {
        remainingSeconds = nil
    }

    mutating func openHelp() {
        cancelAutorun()
        isHelpPresented = true
    }
}

/// The device help and status texts are translated in English and Korean. Missing translations
/// fall back per key to the English table without adding other language files.
nonisolated enum MidiHelpText {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        let english = Bundle.main.url(forResource: "en", withExtension: "lproj")
            .flatMap { Bundle(url: $0) }?
            .localizedString(forKey: key, value: nil, table: nil)
        return bundle.localizedString(forKey: key, value: english, table: nil)
    }
}

struct MidiConnectionHelpView: View {
    @Environment(\.openURL) private var openURL
    let statusTitle: String
    let modelName: String
    let modelSource: MidiModelSource?
    let onClose: () -> Void
    @State private var expanded: Set<MidiHelpQuestion>
    @State private var failedLink: URL?
    @AccessibilityFocusState private var titleFocused: Bool

    init(statusTitle: String, modelName: String, modelSource: MidiModelSource?,
         firstQuestion: MidiHelpQuestion, onClose: @escaping () -> Void) {
        self.statusTitle = statusTitle
        self.modelName = modelName
        self.modelSource = modelSource
        self.onClose = onClose
        _expanded = State(initialValue: [firstQuestion])
    }

    private var selectedModelLine: String {
        let model = [modelName, modelSource?.text].compactMap { $0 }.joined(separator: " · ")
        return String(format: MidiHelpText.text("midi_help_selected_model"), model)
    }

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
                    Text(String(format: MidiHelpText.text("midi_help_now"), statusTitle))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("midi.help.status")
                    Text(selectedModelLine)
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
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(MidiHelpQuestion.allCases) { question in
                            questionRow(question)
                            Divider()
                        }
                        if MidiHelpLinks.isEnabled {
                            link("midi_help_web", to: MidiHelpLinks.guide, identifier: "midi.help.web")
                                .padding(.top, 12)
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
        }
    }

    private func questionRow(_ question: MidiHelpQuestion) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(question) },
            set: { open in
                if open { expanded.insert(question) } else { expanded.remove(question) }
            }
        )) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(question.lines, id: \.key) { line in
                    Text(MidiHelpText.text(line.key))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, line.continuation ? 20 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if question == .customFirmware, MidiHelpLinks.isEnabled {
                    link("midi_help_cfw_link", to: MidiHelpLinks.customFirmware, identifier: "midi.help.cfwLink")
                }
            }
            .padding(.bottom, 12)
        } label: {
            Text(MidiHelpText.text(question.titleKey))
                .font(.headline)
                .foregroundStyle(expanded.contains(question) ? AppColors.orange : AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                // On the label, not the group: a group passes its identifier to every row and link inside it.
                .accessibilityIdentifier("midi.help.q\(question.rawValue)")
        }
        .tint(AppColors.textPrimary)
    }

    private func link(_ key: String, to url: URL, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(MidiHelpText.text(key)) {
                failedLink = nil
                externalOpener(url) { accepted in
                    if !accepted { failedLink = url }
                }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier(identifier)
            if failedLink == url {
                Text(MidiHelpText.text("midi_help_link_failed"))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("midi.help.linkFailed")
            }
        }
    }

    private var externalOpener: OpenURLAction {
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
}
