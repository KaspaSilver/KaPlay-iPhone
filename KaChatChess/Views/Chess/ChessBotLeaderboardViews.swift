import SwiftUI

/// A square on the Leaderboard tab, in place of tabs: it opens that board's own page.
struct ChessLeaderboardSquare: View {
    let title: LocalizedStringKey
    let icon: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .foregroundColor(.primary)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.secondary)
                    .padding(10)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

/// Leaderboard > Bots: the bots that have been played, each opening its own board.
struct ChessBotLeaderboardsView: View {
    @ObservedObject private var service = ChessBotLeaderboardService.shared
    @ObservedObject private var progress = ChessBotProgress.shared

    private var playedBots: [ChessBot] {
        ChessBot.all.filter { service.hasBeenPlayed($0) }
    }

    var body: some View {
        List {
            if service.serverUnreachable {
                Section { ChessServerDownNote(text: "Chess server unreachable. Showing what this phone has.") }
            }
            Section {
                if playedBots.isEmpty {
                    Text("No bot has been played yet.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                ForEach(playedBots) { bot in
                    NavigationLink {
                        ChessBotLeaderboardView(bot: bot)
                    } label: {
                        row(bot)
                    }
                }
            } footer: {
                Text("Ranked by the fewest moves to win.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { service.refresh(force: true) }
        .onAppear { service.refresh() }
        .fixedScreenTitle(Text("Bots"))
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Bots")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
        }
    }

    private func row(_ bot: ChessBot) -> some View {
        let best = service.rows(for: bot, period: .allTime).first
        return HStack(spacing: 12) {
            ChessBotAvatar(bot: bot, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: best.map { ChessText.format("Best: %lld moves", $0.moves) } ?? ChessText.string("Not beaten yet"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// One bot's board: each player's fewest moves to beat it, this month or all time.
struct ChessBotLeaderboardView: View {
    let bot: ChessBot

    @ObservedObject private var service = ChessBotLeaderboardService.shared
    @ObservedObject private var progress = ChessBotProgress.shared
    @ObservedObject private var knsService = KNSService.shared
    @EnvironmentObject private var walletManager: WalletManager
    @State private var period: ChessLeaderboardPeriod = .month
    /// The address whose row was tapped, for their card (`ChessPlayerView`). KaPlay has no
    /// contacts: nothing is saved for it.
    @State private var profileAddress: String?

    private var rows: [ChessBotBoardRow] { service.rows(for: bot, period: period) }

    var body: some View {
        List {
            if service.serverUnreachable {
                Section { ChessServerDownNote(text: "Chess server unreachable. Showing what this phone has.") }
            }
            Section {
                Picker("Leaderboard period", selection: $period) {
                    Text("This month").tag(ChessLeaderboardPeriod.month)
                    Text("All time").tag(ChessLeaderboardPeriod.allTime)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                if period == .month {
                    Text("Resets on the 1st of every month (UTC).")
                }
            }
            Section {
                if rows.isEmpty {
                    Text(period == .month ? "Nobody has beaten \(bot.name) this month yet." : "Nobody has beaten \(bot.name) yet.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Button {
                        profileAddress = row.address
                    } label: {
                        rowLabel(row, rank: index + 1)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(row.address == walletManager.currentWallet?.publicAddress ? Color.accentColor.opacity(0.12) : nil)
                }
            } header: {
                Text("Fewest moves to beat \(bot.name)")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { service.refresh(force: true) }
        .onAppear { service.refresh() }
        .fixedScreenTitle(Text(bot.name))
        .background(Color(.systemGroupedBackground))
        .navigationTitle(bot.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
        }
        .sheet(isPresented: Binding(
            get: { profileAddress != nil },
            set: { if !$0 { profileAddress = nil } }
        )) {
            if let address = profileAddress {
                NavigationStack {
                    ChessPlayerView(address: address)
                }
            }
        }
    }

    private func rowLabel(_ row: ChessBotBoardRow, rank: Int) -> some View {
        let isMe = row.address == walletManager.currentWallet?.publicAddress
        return HStack(spacing: 12) {
            Text(verbatim: "\(rank)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .trailing)
            KNSAvatarView(
                avatarURLString: knsService.profileCache[row.address]?.avatarURL,
                fallbackText: ContactsManager.shared.displayName(for: row.address),
                size: 36,
                contactAddress: row.address
            )
            Text(ContactsManager.shared.displayName(for: row.address))
                .font(.subheadline.weight(isMe ? .bold : .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("\(row.moves) moves")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundColor(.green)
                .fixedSize()
                .layoutPriority(1)
        }
        .contentShape(Rectangle())
    }
}
