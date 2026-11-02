import SwiftUI

/// KaChat Chess's dock: Play, Leaderboard, Wallet, Settings. Fixed - unlike KaChat's dock there
/// is nothing to rearrange, so none of KaChat's dock machinery (Kaspa Hub, Customize Dock) comes
/// along.
struct ChessMainTabView: View {
    enum Tab: Hashable { case play, leaderboard, wallet, settings }

    @EnvironmentObject private var chatService: ChatService
    @EnvironmentObject private var walletManager: WalletManager
    @State private var selection: Tab = .play
    @ObservedObject private var links = ChessBotLinkRouter.shared
    @ObservedObject private var backupStatus = AccountBackupStatus.shared

    /// KaPay's (and KaPosts') wallet symbol; it only exists from iOS 17, so iOS 16 gets the
    /// pass-style wallet.
    private static var walletIcon: String {
        if #available(iOS 17, *) { return "wallet.bifold" }
        return "wallet.pass"
    }

    /// The Wallet tab is showing a backup card (`accountBackupSection`): its dock icon has a yellow
    /// dot until the card's steps are done.
    private var owesBackup: Bool {
        let address = walletManager.currentWallet?.publicAddress
        return backupStatus.isPending(address) || backupStatus.isHygieneDue(address)
    }

    var body: some View {
        TabView(selection: $selection) {
            GamesView()
                .tabItem { Label("Play", image: "ControllerTabIcon") }
                .tag(Tab.play)
            ChessLeaderboardTabView()
                .tabItem { Label("Leaderboard", systemImage: "trophy.fill") }
                .tag(Tab.leaderboard)
            ChessWalletView()
                .tabItem { Label("Wallet", systemImage: Self.walletIcon) }
                // UIKit draws a dot for an empty badge.
                .badge(owesBackup ? Text(verbatim: "") : nil)
                .tag(Tab.wallet)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        // A challenge from a KaPost: Play opens it.
        .onChange(of: links.challenge) { challenge in
            if challenge != nil { selection = .play }
        }
        .onChange(of: selection) { _ in colorDockBadges() }
        .onChange(of: owesBackup) { _ in colorDockBadges() }
        .onAppear {
            colorDockBadges()
            // What KaChat's dock did on appearing: connect to the node pool and subscribe to
            // this address's coins (`ChatService.startPolling`; its chat phases are off, see
            // `syncsChats`). A hold left from onboarding is lifted first, or nothing would start.
            if chatService.onboardingSyncHeld {
                chatService.releaseSyncForOnboarding()
            }
            chatService.startPolling()
        }
    }

    /// SwiftUI's `.badge` has no color, so it goes straight on the tab bar's items. The dock's only
    /// badge is the backup dot, so every item gets yellow.
    private func colorDockBadges() {
        DispatchQueue.main.async {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    var queue: [UIViewController] = window.rootViewController.map { [$0] } ?? []
                    while let controller = queue.popLast() {
                        if let tabs = controller as? UITabBarController {
                            tabs.tabBar.items?.forEach { $0.badgeColor = .systemYellow }
                            return
                        }
                        queue.append(contentsOf: controller.children)
                    }
                }
            }
        }
    }
}

/// The Leaderboard tab: three squares, each opening its own page. 1v1 and Tournaments are a board
/// for this month or all time (`ChessLeaderboardPage`); Bots is a board per bot
/// (`ChessBotLeaderboardsView`).
struct ChessLeaderboardTabView: View {
    @State private var openMode: ChessTournamentsView.Mode?
    @State private var openBots = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ChessLeaderboardSquare(title: "1v1", icon: "person.2.fill") { openMode = .duel }
                    ChessLeaderboardSquare(title: "Tournaments", icon: "trophy.fill") { openMode = .tournament }
                    ChessLeaderboardSquare(title: "Bots", icon: "cpu") { openBots = true }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Spacer(minLength: 0)
            }
            .fixedScreenTitle(Text("Leaderboard"))
            .background(Color(.systemGroupedBackground))
            .navigationDestination(isPresented: Binding(
                get: { openMode != nil },
                set: { if !$0 { openMode = nil } }
            )) {
                if let openMode {
                    ChessLeaderboardPage(mode: openMode)
                }
            }
            .navigationDestination(isPresented: $openBots) {
                ChessBotLeaderboardsView()
            }
            .navigationTitle("Leaderboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { ConnectionStatusIndicator() }
                ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
            }
        }
    }
}

/// Leaderboard > 1v1 or Tournaments: that board, on a page of its own.
private struct ChessLeaderboardPage: View {
    let mode: ChessTournamentsView.Mode
    @ObservedObject private var service = ChessTournamentService.shared

    private var title: Text { mode == .duel ? Text("1v1") : Text("Tournaments") }

    var body: some View {
        List {
            ChessLeaderboardRows(mode: mode)
        }
        .listStyle(.insetGrouped)
        .refreshable { service.refreshIndexerLeaderboards() }
        .fixedScreenTitle(title)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
        }
        // Reads the arena while the board is up, the same as the Play screens do.
        .onAppear { service.acquire() }
        .onDisappear { service.release() }
    }
}

/// The Wallet tab: the one address every move is signed by - its balance, history, Receive
/// and Send.
struct ChessWalletView: View {
    @EnvironmentObject private var walletManager: WalletManager

    var body: some View {
        NavigationStack {
            if let address = walletManager.currentWallet?.publicAddress {
                ChattingAddressManageView(address: address)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) { ConnectionStatusIndicator() }
                        ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
                    }
            }
        }
    }
}
