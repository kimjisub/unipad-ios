import SwiftUI

@Observable
final class SettingsViewModel {

    enum Category {
        case info
        case storage
    }

    struct CommunityLink: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let url: String
        let iconName: String
    }

    var selectedCategory: Category = .info

    @ObservationIgnored private let messaging: FCMServiceProtocol
    @ObservationIgnored private let copyToPasteboard: (String) -> Void

    convenience init() {
        self.init(messaging: FirebaseManager.shared.messaging) { PlatformPasteboard.copyString($0) }
    }

    init(messaging: FCMServiceProtocol, copyToPasteboard: @escaping (String) -> Void) {
        self.messaging = messaging
        self.copyToPasteboard = copyToPasteboard
    }

    var appVersionInfo: String {
        let appName = "UniPad"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(appName) \(version) (\(build))"
    }

    let communityLinks: [CommunityLink] = [
        CommunityLink(title: String(localized: "officialHomepage"), subtitle: String(localized: "officialHomepage_"), url: "https://unipad.io", iconName: "globe"),
        CommunityLink(title: String(localized: "officialFacebook"), subtitle: String(localized: "officialFacebook_"), url: "https://www.facebook.com/playunipad", iconName: "person.2"),
        CommunityLink(title: String(localized: "facebookCommunity"), subtitle: String(localized: "facebookCommunity_"), url: "https://www.facebook.com/groups/playunipad", iconName: "person.3"),
        CommunityLink(title: String(localized: "naverCafe"), subtitle: String(localized: "naverCafe_"), url: "https://cafe.naver.com/unipad", iconName: "cup.and.saucer"),
        CommunityLink(title: String(localized: "discord"), subtitle: String(localized: "discord_"), url: "https://discord.gg/ESDgyNs", iconName: "message"),
        CommunityLink(title: String(localized: "kakaotalk"), subtitle: String(localized: "kakaotalk_"), url: "https://qr.kakao.com/talk/R4p8KwFLXRZsqEjA1FrAnACDyfc-", iconName: "bubble.left"),
        CommunityLink(title: String(localized: "email"), subtitle: String(localized: "email_"), url: "mailto:0226unipad@gmail.com", iconName: "envelope"),
    ]

    // MARK: - Storage

    var workspacePath: String {
        WorkspaceManager.shared.downloadWorkspace.url.path
    }

    var unipackCount: Int = 0
    var storageUsed: String = ""

    func refreshStorageInfo() {
        let workspaceManager = WorkspaceManager.shared
        var totalCount = 0
        for workspace in workspaceManager.availableWorkspaces {
            totalCount += workspaceManager.getUnipackCount(workspace: workspace)
        }
        unipackCount = totalCount

        Task { @MainActor in
            let sizeBytes = await workspaceManager.getAvailableWorkspacesSize()
            storageUsed = FileManagerExtensions.byteToMB(sizeBytes) + " MB"
        }
    }

    // MARK: - Actions

    func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        PlatformHelpers.openURL(url)
    }

    func openGitHub() {
        openURL("https://github.com/kimjisub/unipad-android")
    }

    var pushIdentifierTitle: String {
        messaging.usesInstallationID
            ? String(localized: "FCMInstallationID", defaultValue: "FCM Installation ID")
            : String(localized: "FCMToken")
    }

    private var pushIdentifierUnavailableMessage: String {
        messaging.usesInstallationID
            ? String(localized: "fcm_installation_id_unavailable", defaultValue: "FCM installation ID unavailable")
            : String(localized: "fcm_token_unavailable")
    }

    /// Copies the identifier FCM delivers to in the configured model and returns the message to
    /// show. When there is none, the unavailable notice is copied in its place.
    func copyPushIdentifier() async -> String {
        do {
            let registration = try await messaging.register()
            copyToPasteboard(registration.identifier)
            return String(localized: "copied")
        } catch {
            let unavailable = pushIdentifierUnavailableMessage
            copyToPasteboard(unavailable)
            return unavailable
        }
    }
}
