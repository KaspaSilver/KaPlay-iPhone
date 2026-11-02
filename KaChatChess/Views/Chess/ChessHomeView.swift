import SwiftUI

/// The Play tab: choose your game. 1v1 or a tournament, each its own screen
/// (`ChessTournamentsView`), or the bots (`ChessBotsView`). If the player is
/// already waiting or playing somewhere, that is offered first.
struct ChessHomeView: View {
    @ObservedObject private var service = ChessTournamentService.shared
    @EnvironmentObject private var walletManager: WalletManager
    @State private var openMode: ChessTournamentsView.Mode?
    @State private var openBots = false
    @ObservedObject private var links = ChessBotLinkRouter.shared
    /// A challenge from a KaPost being shown (`ChessBotLinks`).
    @State private var openChallenge: ChessBotChallenge?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        ChessTabIcon.view(side: 64)
                            .foregroundColor(.accentColor)
                        Text("Choose your game")
                            .font(.title2.weight(.bold))
                        Text("Online, five minutes a side and every move is a Kaspa transaction. Bot games stamp their result on Kaspa when they end.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 8)

                    if let mine = service.myActiveTournament {
                        Button {
                            openMode = mine.isDuel ? .duel : .tournament
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: mine.status == .open ? "hourglass" : "play.fill")
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mine.status == .open ? "You're waiting in \(mine.name)" : "You're playing in \(mine.name)")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Tap to go back to it").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }

                    gameCard(
                        icon: "person.2.fill",
                        title: "1v1",
                        detail: "Play the next person who joins, or a friend by code. One game, winner takes the leaderboard point."
                    ) { openMode = .duel }
                    gameCard(
                        icon: "trophy.fill",
                        title: "Tournament",
                        detail: "Eight players, single elimination: quarterfinals, semifinals, final. Public rooms fill as players arrive; private ones by code."
                    ) { openMode = .tournament }
                    gameCard(
                        icon: "cpu",
                        title: "Bots",
                        detail: "Five bots, level 1 to 5, from Kaspa Silver to Yonatan Sompolinsky. Beat one to unlock the next. The result goes on Kaspa."
                    ) { openBots = true }
                }
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Play")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { ConnectionStatusIndicator() }
                ToolbarItem(placement: .principal) { ScreenTitleToolbarLabel(title: Text("Play")) }
            }
            .navigationDestination(isPresented: Binding(
                get: { openMode != nil },
                set: { if !$0 { openMode = nil } }
            )) {
                if let openMode {
                    ChessTournamentsView(mode: openMode)
                }
            }
            .navigationDestination(isPresented: $openBots) {
                ChessBotsView()
            }
            .navigationDestination(isPresented: Binding(
                get: { openChallenge != nil },
                set: { if !$0 { openChallenge = nil } }
            )) {
                if let openChallenge {
                    // A bot still locked: the ladder, which says who to beat first.
                    if ChessBotProgress.shared.isUnlocked(openChallenge.bot) {
                        ChessBotDetailView(bot: openChallenge.bot, challenge: openChallenge)
                    } else {
                        ChessBotsView(challenge: openChallenge)
                    }
                }
            }
            .onAppear {
                service.acquire()
                takeChallenge()
            }
            .onChange(of: links.challenge) { _ in takeChallenge() }
            .onDisappear { service.release() }
        }
    }

    private func takeChallenge() {
        guard let challenge = links.challenge else { return }
        links.challenge = nil
        openChallenge = challenge
    }

    private func gameCard(icon: String, title: String, detail: String, open: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            open()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.scaled(size: 28))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.bold))
                    Text(detail)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}
