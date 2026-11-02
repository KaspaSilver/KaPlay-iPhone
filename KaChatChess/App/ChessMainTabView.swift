import SwiftUI

/// KaChat Chess's dock: Play, Leaderboard, Wallet, Settings. Fixed - unlike KaChat's dock there
/// is nothing to rearrange, so none of KaChat's dock machinery (Kaspa Hub, Customize Dock) comes
/// along.
struct ChessMainTabView: View {
    enum Tab: Hashable { case play, leaderboard, wallet, settings }

    @EnvironmentObject private var chatService: ChatService
    @State private var selection: Tab = .play
    @ObservedObject private var links = ChessBotLinkRouter.shared

    /// KaPay's (and KaPosts') wallet symbol; it only exists from iOS 17, so iOS 16 gets the
    /// pass-style wallet.
    private static var walletIcon: String {
        if #available(iOS 17, *) { return "wallet.bifold" }
        return "wallet.pass"
    }

    var body: some View {
        TabView(selection: $selection) {
            ChessHomeView()
                .tabItem { Label("Play", systemImage: "checkerboard.rectangle") }
                .tag(Tab.play)
            ChessLeaderboardTabView()
                .tabItem { Label("Leaderboard", systemImage: "trophy.fill") }
                .tag(Tab.leaderboard)
            ChessWalletView()
                .tabItem { Label("Wallet", systemImage: Self.walletIcon) }
                .tag(Tab.wallet)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        // A challenge from a KaPost: Play opens it.
        .onChange(of: links.challenge) { challenge in
            if challenge != nil { selection = .play }
        }
        .onAppear {
            // What KaChat's dock did on appearing: connect to the node pool and subscribe to
            // this address's coins (`ChatService.startPolling`; its chat phases are off, see
            // `syncsChats`). A hold left from onboarding is lifted first, or nothing would start.
            if chatService.onboardingSyncHeld {
                chatService.releaseSyncForOnboarding()
            }
            chatService.startPolling()
        }
    }
}

/// The Leaderboard tab: three squares. 1v1 and Tournaments switch the board under them, each for
/// this month or all time (`ChessLeaderboardRows`); Bots opens its own screen, a board per bot
/// (`ChessBotLeaderboardsView`).
struct ChessLeaderboardTabView: View {
    @ObservedObject private var service = ChessTournamentService.shared
    @State private var mode: ChessTournamentsView.Mode = .duel
    @State private var openBots = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ChessLeaderboardSquare(title: "1v1", icon: "person.2.fill", selected: mode == .duel) {
                        mode = .duel
                    }
                    ChessLeaderboardSquare(title: "Tournaments", icon: "trophy.fill", selected: mode == .tournament) {
                        mode = .tournament
                    }
                    ChessLeaderboardSquare(title: "Bots", icon: "cpu", selected: false, opensScreen: true) {
                        openBots = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                List {
                    ChessLeaderboardRows(mode: mode)
                }
                .listStyle(.insetGrouped)
                .refreshable { service.refreshIndexerLeaderboards() }
            }
            .background(Color(.systemGroupedBackground))
            .navigationDestination(isPresented: $openBots) {
                ChessBotLeaderboardsView()
            }
            .navigationTitle("Leaderboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { ConnectionStatusIndicator() }
                ToolbarItem(placement: .principal) { ScreenTitleToolbarLabel(title: Text("Leaderboard")) }
            }
            // Reads the arena while the board is up, the same as the Play screens do.
            .onAppear { service.acquire() }
            .onDisappear { service.release() }
        }
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
                    }
            }
        }
    }
}
