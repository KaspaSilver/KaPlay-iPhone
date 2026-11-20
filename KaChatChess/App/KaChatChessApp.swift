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
        // Renewal reminders are KaPay's (owner's call, 2026-11-20): the ones an older build set
        // are taken off once, so none fires. Never asks for notification permission.
        Task { @MainActor in await KachatNameReminders.removeLegacyOnce() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
                .environmentObject(contactsManager)
                .environmentObject(chatService)
                .environmentObject(settingsViewModel)
                .environmentObject(publicChatService)
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

    @MainActor
    private func handleScenePhaseChange(to newPhase: ScenePhase) {
        guard newPhase == .active else { return }
        let shouldResync = lastActiveResyncAt.map { Date().timeIntervalSince($0) > activeResyncDebounce } ?? true
        guard shouldResync else { return }
        lastActiveResyncAt = Date()
        // gRPC connections can die silently while the app is suspended: reconnect the dead ones
        // now rather than letting the next move discover it.
        Task { await NodePoolService.shared.reconnectStaleConnections() }
        Task { @MainActor in
            await KachatNamesRegistry.shared.refreshIfStale()
            // A .kachat claim an older build started (commit sent, register pending) finishes
            // in the background; nothing new is claimed here (that's KaPay's).
            KachatNamesActions.shared.resume()
        }
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    /// No third-party keyboards anywhere in the app, as in KaPost and KaPay: the passphrase, the
    /// card PIN and the backup's word check are typed on the system keyboard, so a keyboard with
    /// Full Access never sees them. They're offered the system's.
    func application(_ application: UIApplication, shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        extensionPointIdentifier != .keyboard
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task.detached(priority: .utility) { CacheManager.sweepStaleTempFiles() }
        return true
    }
}
