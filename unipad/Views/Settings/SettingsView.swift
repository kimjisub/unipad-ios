import SwiftUI

struct SettingsView: View {
    @Environment(AppRouter.self) private var router
    @ObservedObject private var midiManager = MidiManager.shared
    @State private var vm = SettingsViewModel()
    @State private var showCommunityDialog = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    /// The MIDI log is a support tool, not a setting. It stays reachable because
    /// the two issues that have run longest in this repo were both someone's
    /// Launchpad not being recognised, and a log from the person holding the
    /// device is the only thing that resolves those. It starts closed because a
    /// wall of `MidiManager.start()` in the middle of Settings is not a setting.
    @State private var showMidiLog = false
    @AppStorage(PreferenceManager.Keys.traceLogClassic) private var traceLogClassic = false

    var initialCategory: SettingsViewModel.Category = .info

    var body: some View {
        GeometryReader { geometry in
            let navWidth = min(max(geometry.size.width * 0.3, 180), 260)
            HStack(spacing: 0) {
                categoryNav
                    .frame(width: navWidth)

                contentArea
                    .frame(maxWidth: .infinity)
            }
        }
        .background(AppColors.background1)
        .platformNavigationBarHidden(true)
        .onAppear {
            vm.selectedCategory = initialCategory
            vm.refreshStorageInfo()
        }
        .sheet(isPresented: $showCommunityDialog) {
            communitySheet
        }
        .alert(String(localized: "settings_info"), isPresented: $showAlert) {
            Button(String(localized: "accept")) {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - Category Nav

    private var categoryNav: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { router.pop() } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(AppColors.textPrimary)
                }
                .padding(.trailing, 4)

                Text(String(localized: "setting"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
            }
            .padding(.bottom, 24)

            navItem(
                icon: "info.circle",
                title: String(localized: "settings_info"),
                isSelected: vm.selectedCategory == .info
            ) {
                vm.selectedCategory = .info
            }

            navItem(
                icon: "externaldrive",
                title: String(localized: "settings_storage"),
                isSelected: vm.selectedCategory == .storage
            ) {
                vm.selectedCategory = .storage
            }

            navItem(
                icon: "paintpalette",
                title: String(localized: "settings_theme"),
                isSelected: false,
                showChevron: true
            ) {
                router.navigate(to: .theme)
            }

            Spacer()
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
        .background(AppColors.background1)
    }

    private func navItem(
        icon: String,
        title: String,
        isSelected: Bool,
        showChevron: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? AppColors.blue : AppColors.textSecondary)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textSecondary)
                if showChevron {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18))
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppColors.navItemSelected : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        switch vm.selectedCategory {
        case .info:
            infoContent
        case .storage:
            storageContent
        }
    }

    // MARK: - Info Content

    private var infoContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Device
                sectionLabel(String(localized: "settings_device"))
                settingsCard {
                    VStack(spacing: 0) {
                        settingsRow(title: String(localized: "reconnect_launchpad")) {
                            router.navigate(to: .midiSelect)
                        }
                        cardDivider
                        settingsRow(
                            title: "MIDI",
                            subtitle: MidiManager.shared.isConnected
                                ? "Connected: \(MidiManager.shared.connectedDeviceName ?? "?")"
                                : "Not connected"
                        )
                    }
                }

                // Play
                sectionLabel(String(localized: "settings_play"))
                settingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "trace_log_classic"))
                                .font(.system(size: 14))
                                .foregroundStyle(AppColors.textPrimary)
                            Text(String(localized: "trace_log_classic_desc"))
                                .font(.system(size: 12))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: $traceLogClassic)
                            .labelsHidden()
                            .tint(AppColors.blue)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                // MIDI support log, collapsed.
                sectionLabel(String(localized: "settings_midi_report"))
                settingsCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showMidiLog.toggle() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(localized: "settings_midi_report_title"))
                                        .font(.system(size: 15))
                                        .foregroundStyle(AppColors.textPrimary)
                                    Text(String(localized: "settings_midi_report_desc"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(AppColors.textSecondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Image(systemName: showMidiLog ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppColors.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)

                        if showMidiLog {
                            if midiManager.debugLog.isEmpty {
                                Text("No logs yet")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppColors.textSecondary)
                                    .padding(.vertical, 4)
                            } else {
                                ScrollViewReader { proxy in
                                    ScrollView {
                                        LazyVStack(alignment: .leading, spacing: 2) {
                                            ForEach(Array(midiManager.debugLog.enumerated()), id: \.offset) { index, line in
                                                Text(line)
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(AppColors.textSecondary)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .id(index)
                                            }
                                        }
                                        .padding(6)
                                    }
                                    .frame(maxHeight: 140)
                                    .background(AppColors.background1.opacity(0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .onChange(of: midiManager.debugLog.count) { _, newCount in
                                        if newCount > 0 {
                                            proxy.scrollTo(newCount - 1, anchor: .bottom)
                                        }
                                    }
                                }
                            }
                            HStack(spacing: 12) {
                                Button(String(localized: "settings_midi_rescan")) {
                                    midiManager.scanForDevices()
                                }
                                Button(String(localized: "settings_midi_copy_log")) {
                                    #if canImport(UIKit)
                                    UIPasteboard.general.string = midiManager.debugLog.joined(separator: "\n")
                                    #endif
                                }
                                Button(String(localized: "settings_midi_clear_log")) {
                                    midiManager.clearDebugLog()
                                }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppColors.blue)
                            .padding(.top, 4)
                        }
                    }
                    .padding(12)
                }

                // App Info
                sectionLabel(String(localized: "settings_info"))
                settingsCard {
                    VStack(spacing: 0) {
                        settingsRow(title: vm.appVersionInfo, subtitle: String(localized: "copyright"))
                        cardDivider
                        settingsRow(title: String(localized: "language"), subtitle: String(localized: "translated_by"))
                        cardDivider
                        settingsRow(title: String(localized: "community")) {
                            showCommunityDialog = true
                        }
                    }
                }

                // Developer
                sectionLabel(String(localized: "settings_developer"))
                settingsCard {
                    VStack(spacing: 0) {
                        settingsRow(title: String(localized: "github")) {
                            vm.openGitHub()
                        }
                        cardDivider
                        settingsRow(title: String(localized: "openSourceLicense")) {
                            vm.openURL("https://github.com/kimjisub/unipad-android/blob/main/LICENSE")
                        }
                        cardDivider
                        settingsRow(title: String(localized: "FCMToken"), subtitle: String(localized: "tap_to_copy")) {
                            Task {
                                let token = await vm.copyFcmToken()
                                alertMessage = token == String(localized: "fcm_token_unavailable")
                                    ? token
                                    : String(localized: "copied")
                                showAlert = true
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Storage Content

    private var storageContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sectionLabel(String(localized: "settings_storage"))
                settingsCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(vm.unipackCount) UniPacks")
                            .font(.system(size: 14))
                            .foregroundStyle(AppColors.textPrimary)
                        if !vm.storageUsed.isEmpty {
                            Text(vm.storageUsed)
                                .font(.system(size: 12))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                    .padding(16)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Community Sheet

    private var communitySheet: some View {
        NavigationStack {
            List(vm.communityLinks) { link in
                Button {
                    vm.openURL(link.url)
                    showCommunityDialog = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: link.iconName)
                            .font(.system(size: 20))
                            .foregroundStyle(AppColors.blue)
                            .frame(width: 36, height: 36)

                        VStack(alignment: .leading) {
                            Text(link.title)
                                .font(.system(size: 14))
                                .foregroundStyle(AppColors.textPrimary)
                            Text(link.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.darkSurface)
            .navigationTitle(String(localized: "community"))
            .platformNavigationBarTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("OK") { showCommunityDialog = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Reusable Components

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppColors.blue)
            .tracking(0.5)
            .padding(.leading, 4)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.darkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func settingsRow(
        title: String,
        subtitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            action?()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                Spacer()
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20))
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .disabled(action == nil)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(AppColors.divider)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

}
