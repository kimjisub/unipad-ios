import Foundation
import Combine
import os
#if canImport(FirebaseAnalytics)
import FirebaseAnalytics
#endif
#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif
#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif
#if canImport(FirebaseRemoteConfig)
import FirebaseRemoteConfig
#endif

// MARK: - Firebase Protocols

/// Protocol for Firebase Firestore data fetching.
/// Implement with actual Firebase SDK when integrated.
protocol FirestoreServiceProtocol: Sendable {
    func fetchStoreItems() async throws -> [FirestoreStoreItem]
    func fetchStoreItemCount() async throws -> Int
    func incrementDownloadCount(for itemId: String) async throws
}

/// Protocol for Firebase Cloud Messaging token management.
protocol FCMServiceProtocol: Sendable {
    func getToken() async throws -> String
    func subscribeToTopic(_ topic: String) async throws
    func unsubscribeFromTopic(_ topic: String) async throws
}

/// Protocol for Firebase Analytics.
protocol AnalyticsServiceProtocol: Sendable {
    func logEvent(name: String, parameters: [String: Any]?)
    func setUserProperty(value: String?, forName name: String)
}

/// Protocol for Firebase Crashlytics.
protocol CrashlyticsServiceProtocol: Sendable {
    func setCrashlyticsCollectionEnabled(_ enabled: Bool)
    func log(_ message: String)
    func record(_ error: Error)
}

/// Protocol for Firebase Remote Config.
protocol RemoteConfigServiceProtocol: Sendable {
    func configureForAppLaunch() async
}

// MARK: - Store Item Model

struct FirestoreStoreItem: Identifiable, Sendable {
    let id: String
    let title: String
    let producer: String
    let downloadURL: String
    let fileSize: Int64
    let downloadCount: Int
    let isLED: Bool
    let isAutoPlay: Bool
    let timestamp: Date?
}

// MARK: - Realtime Database Implementation

private struct RealtimeStoreItemDTO: Decodable {
    let code: String?
    let title: String?
    let producerName: String?
    let isAutoPlay: Bool?
    let isLED: Bool?
    let downloadCount: Int?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case code, title, producerName, isAutoPlay, isLED, downloadCount
        case url = "URL"
    }
}

/// Firebase Realtime Database service matching Android store source.
final class RealtimeDatabaseService: FirestoreServiceProtocol {
    private let session: URLSession
    private let databaseBaseCandidates: [URL] = [
        URL(string: "https://unipad-e41ab.firebaseio.com")!,
        URL(string: "https://unipad-e41ab-default-rtdb.firebaseio.com")!
    ]
    private let legacyDownloadBaseURL = "https://us-central1-unipad-e41ab.cloudfunctions.net/downloadUniPackLegacy"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchStoreItems() async throws -> [FirestoreStoreItem] {
        let data = try await fetchRealtimeData(path: "store.json")

        let root = try JSONDecoder().decode([String: RealtimeStoreItemDTO].self, from: data)
        let orderedEntries = root.sorted { $0.key < $1.key }.reversed()
        return orderedEntries.compactMap { key, value in
            let resolvedId = value.code?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? value.code!
                : key
            let title = value.title ?? resolvedId
            let producer = value.producerName ?? ""

            let downloadURL: String
            if let remoteURL = value.url, remoteURL.hasPrefix("http") {
                downloadURL = remoteURL
            } else {
                let encodedCode = resolvedId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resolvedId
                downloadURL = "\(legacyDownloadBaseURL)?code=\(encodedCode)"
            }

            return FirestoreStoreItem(
                id: resolvedId,
                title: title,
                producer: producer,
                downloadURL: downloadURL,
                fileSize: 0,
                downloadCount: value.downloadCount ?? 0,
                isLED: value.isLED ?? false,
                isAutoPlay: value.isAutoPlay ?? false,
                timestamp: nil
            )
        }
    }

    func fetchStoreItemCount() async throws -> Int {
        let data = try await fetchRealtimeData(path: "storeCount.json")

        if let count = try? JSONDecoder().decode(Int.self, from: data) {
            return count
        }
        if let count = try? JSONDecoder().decode(Double.self, from: data) {
            return Int(count)
        }
        return 0
    }

    func incrementDownloadCount(for itemId: String) async throws {
        // Store download count updates are handled by backend download endpoint in current architecture.
    }

    private func fetchRealtimeData(path: String) async throws -> Data {
        for baseURL in databaseBaseCandidates {
            let endpoint = baseURL.appendingPathComponent(path)
            do {
                let (data, response) = try await session.data(from: endpoint)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    continue
                }
                return data
            } catch {
                continue
            }
        }
        throw URLError(.badServerResponse)
    }
}

/// Stub FCM service. Replace with real Firebase implementation.
final class FCMServiceStub: FCMServiceProtocol {
    func getToken() async throws -> String {
        // TODO: Implement with Firebase Messaging SDK
        // return try await Messaging.messaging().token()
        return ""
    }

    func subscribeToTopic(_ topic: String) async throws {
        // TODO: Implement with Firebase Messaging SDK
        // try await Messaging.messaging().subscribe(toTopic: topic)
    }

    func unsubscribeFromTopic(_ topic: String) async throws {
        // TODO: Implement with Firebase Messaging SDK
        // try await Messaging.messaging().unsubscribe(fromTopic: topic)
    }
}

final class AnalyticsServiceStub: AnalyticsServiceProtocol {
    func logEvent(name: String, parameters: [String: Any]?) {
        _ = (name, parameters)
    }

    func setUserProperty(value: String?, forName name: String) {
        _ = (value, name)
    }
}

final class CrashlyticsServiceStub: CrashlyticsServiceProtocol {
    func setCrashlyticsCollectionEnabled(_ enabled: Bool) {
        _ = enabled
    }

    func log(_ message: String) {
        _ = message
    }

    func record(_ error: Error) {
        _ = error
    }
}

final class RemoteConfigServiceStub: RemoteConfigServiceProtocol {
    func configureForAppLaunch() async {}
}

#if canImport(FirebaseAnalytics)
final class AnalyticsServiceLive: AnalyticsServiceProtocol, @unchecked Sendable {
    func logEvent(name: String, parameters: [String: Any]?) {
        Analytics.logEvent(name, parameters: parameters)
    }

    func setUserProperty(value: String?, forName name: String) {
        Analytics.setUserProperty(value, forName: name)
    }
}
#endif

#if canImport(FirebaseMessaging)
final class MessagingServiceLive: NSObject, FCMServiceProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "FCM")

    func getToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Messaging.messaging().token { token, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: token ?? "")
            }
        }
    }

    func subscribeToTopic(_ topic: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Messaging.messaging().subscribe(toTopic: topic) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func unsubscribeFromTopic(_ topic: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func onNewRegistrationToken(_ token: String?) {
        logger.info("FCM registration token refreshed: \(token ?? "<nil>")")
    }
}
#endif

#if canImport(FirebaseCrashlytics)
final class CrashlyticsServiceLive: CrashlyticsServiceProtocol, @unchecked Sendable {
    func setCrashlyticsCollectionEnabled(_ enabled: Bool) {
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(enabled)
    }

    func log(_ message: String) {
        Crashlytics.crashlytics().log(message)
    }

    func record(_ error: Error) {
        Crashlytics.crashlytics().record(error: error)
    }
}
#endif

#if canImport(FirebaseRemoteConfig)
final class RemoteConfigServiceLive: RemoteConfigServiceProtocol, @unchecked Sendable {
    func configureForAppLaunch() async {
        let remoteConfig = RemoteConfig.remoteConfig()
        let settings = RemoteConfigSettings()
#if DEBUG
        settings.minimumFetchInterval = 60
#endif
        remoteConfig.configSettings = settings
        _ = try? await remoteConfig.fetchAndActivate()
    }
}
#endif

// MARK: - Firebase Manager

/// Central access point for Firebase services.
/// Switch stubs to real implementations when Firebase SDK is integrated.
@MainActor
final class FirebaseManager: ObservableObject {
    static let shared = FirebaseManager()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "Firebase")

    let firestore: FirestoreServiceProtocol
    let messaging: FCMServiceProtocol
    let analytics: AnalyticsServiceProtocol
    let crashlytics: CrashlyticsServiceProtocol
    let remoteConfig: RemoteConfigServiceProtocol

    private init() {
        self.firestore = RealtimeDatabaseService()
#if canImport(FirebaseMessaging)
        self.messaging = MessagingServiceLive()
#else
        self.messaging = FCMServiceStub()
#endif
#if canImport(FirebaseAnalytics)
        self.analytics = AnalyticsServiceLive()
#else
        self.analytics = AnalyticsServiceStub()
#endif
#if canImport(FirebaseCrashlytics)
        self.crashlytics = CrashlyticsServiceLive()
#else
        self.crashlytics = CrashlyticsServiceStub()
#endif
#if canImport(FirebaseRemoteConfig)
        self.remoteConfig = RemoteConfigServiceLive()
#else
        self.remoteConfig = RemoteConfigServiceStub()
#endif
    }

    func configureOnAppLaunch() {
        analytics.setUserProperty(value: "ios", forName: "platform")
        crashlytics.setCrashlyticsCollectionEnabled(true)
        crashlytics.log("Firebase app launch configured")
        Task { [remoteConfig] in
            await remoteConfig.configureForAppLaunch()
        }
    }

#if canImport(FirebaseMessaging)
    func onMessagingTokenRefreshed(_ token: String?) {
        (messaging as? MessagingServiceLive)?.onNewRegistrationToken(token)
        analytics.logEvent(name: "fcm_token_refreshed", parameters: ["has_token": token != nil])
        logger.info("FCM token refreshed callback received")
    }
#endif
}
