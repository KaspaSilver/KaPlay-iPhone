import SwiftUI

/// A square on the Leaderboard tab, in place of tabs: it switches the board under the squares, or
/// opens a screen of its own (`opensScreen`, marked with a chevron).
struct ChessLeaderboardSquare: View {
    let title: String
    let icon: String
    let selected: Bool
    var opensScreen = false
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
            .foregroundColor(selected ? .accentColor : .primary)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .overlay(alignment: .topTrailing) {
                if opensScreen {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                        .padding(10)
                }
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
        .navigationTitle("Bots")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { ScreenTitleToolbarLabel(title: Text("Bots")) }
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
                Text(best.map { "Best: \($0.moves) moves" } ?? "Not beaten yet")
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
    /// The player whose row was tapped, for their card (`ChessPlayerView`).
    @State private var profileContact: Contact?

    private var rows: [ChessBotBoardRow] { service.rows(for: bot, period: period) }

    var body: some View {
        List {
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
                        let contacts = ContactsManager.shared
                        profileContact = contacts.getContact(byAddress: row.address) ?? contacts.getOrCreateContact(address: row.address)
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
        .navigationTitle(bot.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { ScreenTitleToolbarLabel(title: Text(bot.name)) }
        }
        .sheet(isPresented: Binding(
            get: { profileContact != nil },
            set: { if !$0 { profileContact = nil } }
        )) {
            if let contact = profileContact {
                NavigationStack {
                    ChessPlayerView(address: contact.address)
                }
            }
        }
    }

    private func rowLabel(_ row: ChessBotBoardRow, rank: Int) -> some View {
        let isMe = row.address == walletManager.currentWallet?.publicAddress
        return HStack(spacing: 12) {
            Text("\(rank)")
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
