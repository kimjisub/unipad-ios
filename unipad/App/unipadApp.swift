import SwiftUI
import SwiftData
import Combine
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = AppRouter()
    @State private var showMidiBanner = false
    @State private var midiBannerMessage = ""
    @State private var midiBannerToken = 0
    @State private var announceMidiOnNextActive = false
    @State private var lastAnnouncedMidiDeviceName: String?
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
            .overlay(alignment: .top) {
                if showMidiBanner {
                    midiConnectionBanner
                        .padding(.top, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onOpenURL { url in
                router.handleDeepLink(url)
            }
            .onAppear {
                MidiManager.shared.start()
            }
            .onReceive(MidiManager.shared.$isConnected.removeDuplicates()) { connected in
                if connected {
                    if scenePhase == .active {
                        presentMidiConnectionBanner(force: false)
                    } else {
                        announceMidiOnNextActive = true
                    }
                } else {
                    announceMidiOnNextActive = false
                    lastAnnouncedMidiDeviceName = nil
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showMidiBanner = false
                    }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    MidiManager.shared.scanForDevices()
                    if announceMidiOnNextActive && MidiManager.shared.isConnected {
                        presentMidiConnectionBanner(force: true)
                    }
                    announceMidiOnNextActive = false
                case .inactive, .background:
                    if MidiManager.shared.isConnected {
                        announceMidiOnNextActive = true
                    }
                @unknown default:
                    break
                }
            }
        }
        .modelContainer(sharedModelContainer)
    }

    private var midiConnectionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "pianokeys.inverse")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)

            Text(midiBannerMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(String(localized: "midi_open_panel")) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showMidiBanner = false
                }
                if !router.isShowingMidiSelect {
                    router.navigate(to: .midiSelect)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppColors.blue)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showMidiBanner = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 24, height: 24)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.88))
        .clipShape(Capsule())
        .padding(.horizontal, 20)
    }

    private func presentMidiConnectionBanner(force: Bool) {
        guard !router.isShowingMidiSelect else { return }

        let deviceName = MidiManager.shared.connectedDeviceName ?? String(localized: "launchpadConnecting")
        if !force && lastAnnouncedMidiDeviceName == deviceName {
            return
        }

        midiBannerMessage = String(
            format: String(localized: "midi_connected_banner %@"),
            deviceName
        )
        lastAnnouncedMidiDeviceName = deviceName
        midiBannerToken += 1
        let token = midiBannerToken

        withAnimation(.easeInOut(duration: 0.2)) {
            showMidiBanner = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard token == midiBannerToken else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showMidiBanner = false
            }
        }
    }
}
