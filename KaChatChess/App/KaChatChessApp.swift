import SwiftUI
import UIKit

/// KaChat Chess's entry point. KaChat's own (`KaChatApp`) also ran chats, calls, push, Siri,
/// the share sheet and link routing; none of that is here - only the wallet, the node pool,
/// the services Chess Online reads the arena and sends its moves through, and the bot challenge
/// link (`ChessBotLinks`).
@main
struct KaChatChessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var walletManager = WalletManager.shared
    @StateObject private var contactsManager = ContactsManager.shared
    @StateObject private var chatService = ChatService.shared
    @StateObject private var settingsViewModel = SettingsViewModel()
    @StateObject private var publicChatService = PublicChatService.shared
    /// The blur over the app in the App Switcher and behind system prompts: the balance and the
    /// seed screen would otherwise sit in iOS's snapshot of the app in plain view.
    @State private var showPrivacyCover = false
    @State private var lastActiveResyncAt: Date?
    @Environment(\.scenePhase) private var scenePhase

    /// Below this, becoming active again skips the node pool's reconnect sweep: a glance at the
    /// App Switcher shouldn't redo it.
    private let activeResyncDebounce: TimeInterval = 15

    init() {
        // A Testnet/Mainnet switch chosen in Settings takes effect here, before any service
        // reads the settings, so the whole app starts on one network.
        PendingNetworkSwitch.applyAtLaunch()
        // Players shown as their address are asked again for a .kachat name, once a minute.
        KachatNamesRegistry.shared.startUnnamedIdentitySweep()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
                .environmentObject(contactsManager)
                .environmentObject(chatService)
                .environmentObject(settingsViewModel)
                .environmentObject(publicChatService)
                .overlay {
                    if showPrivacyCover {
                        PrivacyCoverView()
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: showPrivacyCover)
                .onAppear {
                    ChatService.shared.settingsViewModel = settingsViewModel
                    applyWindowAppearanceOverride()
                }
                .onOpenURL { url in
                    if let challenge = ChessBotLinks.challenge(from: url) {
                        ChessBotLinkRouter.shared.challenge = challenge
                    }
                }
                .preferredColorScheme(settingsViewModel.settings.appearance.colorScheme)
                .onChange(of: settingsViewModel.settings.appearance) { _ in
                    applyWindowAppearanceOverride()
                }
                .environment(\.locale, settingsViewModel.settings.language.locale ?? .autoupdatingCurrent)
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(to: newPhase)
        }
    }

    /// `.preferredColorScheme` only themes SwiftUI content; the UIKit layer underneath (sheet
    /// edges, the keyboard, share sheets) follows the device. Overriding the windows'
    /// interface style makes the whole window match.
    private func applyWindowAppearanceOverride() {
        let style: UIUserInterfaceStyle
        switch settingsViewModel.settings.appearance {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    private func handleScenePhaseChange(to newPhase: ScenePhase) {
        // Covered the moment the app stops being the thing in front, uncovered when it is again.
        showPrivacyCover = newPhase != .active
        guard newPhase == .active else { return }
        let shouldResync = lastActiveResyncAt.map { Date().timeIntervalSince($0) > activeResyncDebounce } ?? true
        guard shouldResync else { return }
        lastActiveResyncAt = Date()
        // gRPC connections can die silently while the app is suspended: reconnect the dead ones
        // now rather than letting the next move discover it.
        Task { await NodePoolService.shared.reconnectStaleConnections() }
        Task { @MainActor in await KachatNamesRegistry.shared.refreshIfStale() }
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task.detached(priority: .utility) { CacheManager.sweepStaleTempFiles() }
        return true
    }
}

extension Notification.Name {
    static let openChat = Notification.Name("openChat")
    static let openPublicChat = Notification.Name("openBroadcast")
}

/// What the App Switcher and a system prompt see instead of the app's contents.
private struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            // The app's own icon, shaped like it is on the Home Screen.
            Image("KaChatChessLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .ignoresSafeArea()
    }
}
