import SwiftUI
import SwiftData
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

#if canImport(UIKit) && canImport(FirebaseCore)
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        FirebaseManager.shared.configureOnAppLaunch()
#if canImport(FirebaseMessaging) && canImport(UserNotifications)
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        application.registerForRemoteNotifications()
#endif
        return true
    }

#if canImport(FirebaseMessaging)
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }
#endif
}
#endif

#if canImport(UIKit) && canImport(FirebaseMessaging) && canImport(UserNotifications)
extension AppDelegate: UNUserNotificationCenterDelegate, MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        FirebaseManager.shared.onMessagingTokenRefreshed(fcmToken)
    }
}
#endif

@main
struct unipadApp: App {
    @State private var router = AppRouter()
    #if canImport(UIKit) && canImport(FirebaseCore)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    #endif

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            UnipackEntity.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ZStack {
                NavigationStack(path: $router.path) {
                    MainView()
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .play(let path):
                                PlayView(packPath: path)
                            case .store:
                                StoreView()
                            case .settings:
                                SettingsView()
                            case .settingsStorage:
                                SettingsView(initialCategory: .storage)
                            case .theme:
                                ThemeView()
                            case .midiSelect:
                                MidiSelectView()
                            case .transfer(let config):
                                TransferView(config: config)
                            case .importByUrl(let code):
                                ImportByUrlView(code: code)
                            case .main:
                                MainView()
                            }
                        }
                }

                if router.showSplash {
                    SplashView()
                        .transition(.opacity)
                }
            }
            .environment(router)
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                router.handleDeepLink(url)
            }
        }
        .modelContainer(sharedModelContainer)
    }
}
