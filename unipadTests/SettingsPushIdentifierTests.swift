import Foundation
import Testing
@testable import unipad

/// The settings row that copies the push identifier, in both FCM models, backed by a scripted
/// client instead of Firebase.
@MainActor
struct SettingsPushIdentifierTests {
    typealias ScriptedClient = PushRegistrationTests.ScriptedClient

    final class ScriptedMessaging: FCMServiceProtocol, @unchecked Sendable {
        let client: ScriptedClient

        init(client: ScriptedClient) {
            self.client = client
        }

        var usesInstallationID: Bool { client.isInstallationIdEnabled }

        func register() async throws -> PushRegistration {
            try await PushRegistrar(client: client).register()
        }

        func subscribeToTopic(_ topic: String) async throws {}
        func unsubscribeFromTopic(_ topic: String) async throws {}
    }

    private func makeViewModel(_ client: ScriptedClient) -> (SettingsViewModel, () -> [String]) {
        var copied: [String] = []
        let vm = SettingsViewModel(messaging: ScriptedMessaging(client: client)) { copied.append($0) }
        return (vm, { copied })
    }

    // MARK: - Legacy token model

    @Test func tokenModelKeepsTheExistingTitle() {
        let (vm, _) = makeViewModel(ScriptedClient(installationIdEnabled: false))

        #expect(vm.pushIdentifierTitle == String(localized: "FCMToken"))
    }

    @Test func tokenModelCopiesTheToken() async {
        let client = ScriptedClient(installationIdEnabled: false)
        client.token = .success("token-a")
        let (vm, copied) = makeViewModel(client)

        let message = await vm.copyPushIdentifier()

        #expect(message == String(localized: "copied"))
        #expect(copied() == ["token-a"])
        #expect(client.registerRequests == 0)
    }

    @Test(arguments: [.success(nil), .success(""), .failure(PushRegistrationTests.ScriptedError())] as [Result<String?, Error>])
    func tokenModelCopiesTheExistingUnavailableNotice(_ token: Result<String?, Error>) async {
        let client = ScriptedClient(installationIdEnabled: false)
        client.token = token
        let (vm, copied) = makeViewModel(client)

        let message = await vm.copyPushIdentifier()

        #expect(message == String(localized: "fcm_token_unavailable"))
        #expect(copied() == [message])
    }

    // MARK: - Installation ID model

    @Test func installationModelNamesTheInstallationID() {
        let (vm, _) = makeViewModel(ScriptedClient(installationIdEnabled: true))

        #expect(vm.pushIdentifierTitle == String(localized: "FCMInstallationID", defaultValue: "FCM Installation ID"))
        #expect(vm.pushIdentifierTitle != String(localized: "FCMToken"))
    }

    @Test func installationModelRegistersAndCopiesTheInstallationID() async {
        let client = ScriptedClient(installationIdEnabled: true)
        client.fid = .success("fid-a")
        let (vm, copied) = makeViewModel(client)

        let message = await vm.copyPushIdentifier()

        #expect(message == String(localized: "copied"))
        #expect(copied() == ["fid-a"])
        #expect(client.registerRequests == 1)
        #expect(client.tokenRequests == 0)
    }

    @Test func installationModelCopiesTheRefreshedIDOnEachTap() async {
        let client = ScriptedClient(installationIdEnabled: true)
        client.fid = .success("fid-a")
        let (vm, copied) = makeViewModel(client)

        _ = await vm.copyPushIdentifier()
        client.fid = .success("fid-b")
        _ = await vm.copyPushIdentifier()

        #expect(copied() == ["fid-a", "fid-b"])
        #expect(client.registerRequests == 2)
    }

    @Test func installationModelReportsAFailedRegistrationAsUnavailable() async {
        let client = ScriptedClient(installationIdEnabled: true)
        client.registerResult = .failure(PushRegistrationTests.ScriptedError())
        client.fid = .success("fid-a")
        let (vm, copied) = makeViewModel(client)

        let message = await vm.copyPushIdentifier()

        #expect(message == String(localized: "fcm_installation_id_unavailable", defaultValue: "FCM installation ID unavailable"))
        #expect(message != String(localized: "fcm_token_unavailable"))
        #expect(copied() == [message])
        #expect(client.fidRequests == 0)
    }

    @Test(arguments: [nil, ""] as [String?])
    func installationModelReportsAnEmptyIDAsUnavailable(_ empty: String?) async {
        let client = ScriptedClient(installationIdEnabled: true)
        client.fid = .success(empty)
        let (vm, copied) = makeViewModel(client)

        let message = await vm.copyPushIdentifier()

        #expect(message == String(localized: "fcm_installation_id_unavailable", defaultValue: "FCM installation ID unavailable"))
        #expect(copied() == [message])
    }
}
