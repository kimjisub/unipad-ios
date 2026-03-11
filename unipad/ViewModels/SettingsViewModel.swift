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

    var appVersionInfo: String {
        let appName = "UniPad"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(appName) \(version) (\(build))"
    }

    let communityLinks: [CommunityLink] = [
        CommunityLink(title: String(localized: "officialHomepage"), subtitle: "unipad.io", url: "https://unipad.io", iconName: "globe"),
        CommunityLink(title: String(localized: "officialFacebook"), subtitle: "Technical Support", url: "https://www.facebook.com/playunipad", iconName: "person.2"),
        CommunityLink(title: String(localized: "facebookCommunity"), subtitle: "English", url: "https://www.facebook.com/groups/playunipad", iconName: "person.3"),
        CommunityLink(title: String(localized: "naverCafe"), subtitle: "Korean", url: "https://cafe.naver.com/unipad", iconName: "cup.and.saucer"),
        CommunityLink(title: String(localized: "discord"), subtitle: "Discord", url: "https://discord.gg/ESDgyNs", iconName: "message"),
        CommunityLink(title: String(localized: "kakaotalk"), subtitle: "Dev. kimjisub", url: "https://qr.kakao.com/talk/R4p8KwFLXRZsqEjA1FrAnACDyfc-", iconName: "bubble.left"),
        CommunityLink(title: String(localized: "email"), subtitle: "0226unipad@gmail.com", url: "mailto:0226unipad@gmail.com", iconName: "envelope"),
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

    func copyFcmToken() async -> String {
        do {
            let token = try await FirebaseManager.shared.messaging.getToken()
            let resolved = token.isEmpty ? String(localized: "fcm_token_unavailable") : token
            PlatformPasteboard.copyString(resolved)
            return resolved
        } catch {
            let fallback = String(localized: "fcm_token_unavailable")
            PlatformPasteboard.copyString(fallback)
            return fallback
        }
    }
}
