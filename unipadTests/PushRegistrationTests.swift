import Foundation
import Testing
@testable import unipad

/// The FCM registration flow in both models, checked against a scripted client instead of Firebase.
@MainActor
struct PushRegistrationTests {
    struct ScriptedError: Error {}

    final class ScriptedClient: MessagingRegistrationClient, @unchecked Sendable {
        let isInstallationIdEnabled: Bool
        var token: Result<String?, Error> = .success(nil)
        var registerResult: Result<Void, Error> = .success(())
        var fid: Result<String?, Error> = .success(nil)
        private(set) var tokenRequests = 0
        private(set) var registerRequests = 0
        private(set) var fidRequests = 0

        init(installationIdEnabled: Bool) {
            isInstallationIdEnabled = installationIdEnabled
        }

        func registrationToken() async throws -> String? {
            tokenRequests += 1
            return try token.get()
        }

        func registerInstallation() async throws {
            registerRequests += 1
            try registerResult.get()
        }

        func installationID() async throws -> String? {
            fidRequests += 1
            return try fid.get()
        }
    }

    // MARK: - Legacy token model

    @Test func tokenModelReturnsTheTokenWithoutTouchingInstallationRegistration() async throws {
        let client = ScriptedClient(installationIdEnabled: false)
        client.token = .success("token-a")

        let registration = try await PushRegistrar(client: client).register()

        #expect(registration == .registrationToken("token-a"))
        #expect(client.registerRequests == 0)
        #expect(client.fidRequests == 0)
    }

    @Test func tokenModelPropagatesFailure() async {
        let client = ScriptedClient(installationIdEnabled: false)
        client.token = .failure(ScriptedError())

        await #expect(throws: ScriptedError.self) {
            try await PushRegistrar(client: client).register()
        }
    }

    @Test(arguments: [nil, ""] as [String?])
    func tokenModelRejectsEmptyToken(_ empty: String?) async {
        let client = ScriptedClient(installationIdEnabled: false)
        client.token = .success(empty)

        await #expect(throws: PushRegistrationError.emptyIdentifier) {
            try await PushRegistrar(client: client).register()
        }
    }

    // MARK: - Installation ID model

    @Test func installationModelRegistersThenReturnsTheInstallationID() async throws {
        let client = ScriptedClient(installationIdEnabled: true)
        client.fid = .success("fid-a")

        let registration = try await PushRegistrar(client: client).register()

        #expect(registration == .installationID("fid-a"))
        #expect(client.registerRequests == 1)
        #expect(client.tokenRequests == 0)
    }

    @Test func installationModelDoesNotReadTheIDWhenRegistrationFails() async {
        let client = ScriptedClient(installationIdEnabled: true)
        client.registerResult = .failure(ScriptedError())
        client.fid = .success("fid-a")

        await #expect(throws: ScriptedError.self) {
            try await PushRegistrar(client: client).register()
        }
        #expect(client.fidRequests == 0)
    }

    @Test func installationModelPropagatesIDLookupFailure() async {
        let client = ScriptedClient(installationIdEnabled: true)
        client.fid = .failure(ScriptedError())

        await #expect(throws: ScriptedError.self) {
            try await PushRegistrar(client: client).register()
        }
    }

    @Test(arguments: [nil, ""] as [String?])
    func installationModelRejectsEmptyID(_ empty: String?) async {
        let client = ScriptedClient(installationIdEnabled: true)
        client.fid = .success(empty)

        await #expect(throws: PushRegistrationError.emptyIdentifier) {
            try await PushRegistrar(client: client).register()
        }
    }

    @Test func reRegistrationReturnsTheRefreshedInstallationID() async throws {
        let client = ScriptedClient(installationIdEnabled: true)
        let registrar = PushRegistrar(client: client)
        client.fid = .success("fid-a")
        let first = try await registrar.register()
        let again = try await registrar.register()

        client.fid = .success("fid-b")
        let refreshed = try await registrar.register()

        #expect(first == .installationID("fid-a"))
        #expect(again == first)
        #expect(refreshed == .installationID("fid-b"))
        #expect(client.registerRequests == 3)
    }

    @Test func reRegistrationRecoversAfterAFailedAttempt() async throws {
        let client = ScriptedClient(installationIdEnabled: true)
        let registrar = PushRegistrar(client: client)
        client.registerResult = .failure(ScriptedError())
        client.fid = .success("fid-a")
        await #expect(throws: ScriptedError.self) { try await registrar.register() }

        client.registerResult = .success(())

        #expect(try await registrar.register() == .installationID("fid-a"))
    }

    // MARK: - Local-only runtime

    @Test func localOnlyStubReportsRegistrationUnavailable() async {
        await #expect(throws: PushRegistrationError.unavailable) {
            try await FCMServiceStub().register()
        }
    }
}
