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
        // Covered the moment the app stops being the thing in front, uncovered when it is again.
        // The cover is its own window (`PrivacyCoverWindow`), so it is over every sheet too: the
        // balance, the 12 or 24 words and the private key would otherwise sit in iOS's snapshot
        // of the app in plain view.
        if newPhase == .active {
            PrivacyCoverWindow.hide()
        } else {
            PrivacyCoverWindow.show()
        }
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

extension Notification.Name {
    static let openChat = Notification.Name("openChat")
    static let openPublicChat = Notification.Name("openBroadcast")
}

/// Puts `PrivacyCoverView` in a window of its own above the app, as KaPost does. An overlay on
/// the root view sat underneath presented sheets, which is where the 12 or 24 words, the
/// passphrase and the private key are shown. Hidden, the window is gone, so it never takes a touch.
@MainActor
private enum PrivacyCoverWindow {
    private static var window: UIWindow?

    static func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        // the app's appearance (Settings' choice), which its own windows carry
        cover.overrideUserInterfaceStyle = scene.windows.first?.overrideUserInterfaceStyle ?? .unspecified
        cover.rootViewController = UIHostingController(rootView: PrivacyCoverView())
        cover.isHidden = false
        window = cover
    }

    static func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// What the App Switcher and a system prompt see instead of the app's contents.
private struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            // Solid under the blur: in its own window the material would otherwise let large
            // words on a sheet below be read through it.
            Color(.systemBackground)
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
