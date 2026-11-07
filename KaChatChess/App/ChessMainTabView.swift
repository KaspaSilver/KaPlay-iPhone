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

    /// KaPay's (and KaPosts') wallet symbol; it only exists from iOS 17, so iOS 16 gets the
    /// pass-style wallet.
    private static var walletIcon: String {
        if #available(iOS 17, *) { return "wallet.bifold" }
        return "wallet.pass"
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
            .fixedScreenTitle(Text("Leaderboard"), showsBackupBanner: true)
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
