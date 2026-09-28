import Foundation
#if canImport(FirebaseMessaging)
import FirebaseMessaging
import FirebaseInstallations
#endif

/// How FCM can address this app install. The two identifiers are not interchangeable:
/// a registration token is only issued in the legacy model, and an installation ID only
/// becomes a delivery target once `FirebaseMessagingInstallationIdEnabled` is `YES`.
enum PushRegistration: Equatable, Sendable {
    case registrationToken(String)
    case installationID(String)

    var identifier: String {
        switch self {
        case .registrationToken(let value), .installationID(let value):
            return value
        }
    }
}

enum PushRegistrationError: Error, Equatable {
    case emptyIdentifier
    case unavailable
}

/// The Firebase Messaging calls the registration flow depends on, kept apart so the flow
/// can be exercised without Firebase.
protocol MessagingRegistrationClient: Sendable {
    var isInstallationIdEnabled: Bool { get }
    func registrationToken() async throws -> String?
    func registerInstallation() async throws
    func installationID() async throws -> String?
}

struct PushRegistrar: Sendable {
    let client: MessagingRegistrationClient

    /// Registers with FCM in whichever model the app is configured for and returns the
    /// identifier the sender has to target. Safe to call again: FCM returns the existing
    /// registration, or the refreshed one if it changed.
    func register() async throws -> PushRegistration {
        if client.isInstallationIdEnabled {
            try await client.registerInstallation()
            return .installationID(try Self.nonEmpty(await client.installationID()))
        }
        return .registrationToken(try Self.nonEmpty(await client.registrationToken()))
    }

    private static func nonEmpty(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else { throw PushRegistrationError.emptyIdentifier }
        return value
    }
}

/// Records FCM registration callbacks for either model. Only whether an identifier arrived is
/// written, never the identifier itself.
struct PushRegistrationCallbackRecorder {
    let analytics: AnalyticsServiceProtocol
    let log: (String) -> Void

    func registrationTokenRefreshed(_ token: String?) {
        analytics.logEvent(name: "fcm_token_refreshed", parameters: ["has_token": token != nil])
        log("FCM registration token refreshed (present: \(token != nil))")
    }

    /// Logged only: the installation-ID model must not add analytics collection.
    func installationRegistered(_ installationID: String?) {
        log("FCM installation registration refreshed (present: \(installationID != nil))")
    }
}

#if canImport(FirebaseMessaging)
struct FirebaseMessagingRegistrationClient: MessagingRegistrationClient {
    var isInstallationIdEnabled: Bool {
        Messaging.messaging().isInstallationIdEnabled
    }

    func registrationToken() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            Messaging.messaging().token { token, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: token)
                }
            }
        }
    }

    func registerInstallation() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Messaging.messaging().register { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func installationID() async throws -> String? {
        try await Installations.installations().installationID()
    }
}
#endif
