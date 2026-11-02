import SwiftUI

/// Play > Bots: the five bots as a ladder, level 1 to 5. Each level opens when the one before
/// it is beaten; a locked bot shows who to beat first.
struct ChessBotsView: View {
    /// A challenge from a KaPost that opened here because its bot is still locked.
    var challenge: ChessBotChallenge? = nil
    @ObservedObject private var progress = ChessBotProgress.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.scaled(size: 40))
                        .foregroundColor(.accentColor)
                    Text("Climb the ladder")
                        .font(.title2.weight(.bold))
                    Text("Five bots, level 1 to 5. Beat one to unlock the next. Each game's result is stamped on Kaspa when it ends.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.top, 20)
                .padding(.bottom, 8)

                if let challenge {
                    ChessBotChallengeBanner(challenge: challenge)
                        .padding(.horizontal, 16)
                }

                ForEach(ChessBot.all) { bot in
                    let unlocked = progress.isUnlocked(bot)
                    NavigationLink {
                        ChessBotDetailView(bot: bot)
                    } label: {
                        card(bot, unlocked: unlocked)
                    }
                    .buttonStyle(.plain)
                    .disabled(!unlocked)
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 24)
        }
        .fixedScreenTitle(Text("Bots"))
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Bots")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
        }
    }

    private func card(_ bot: ChessBot, unlocked: Bool) -> some View {
        let record = progress.record(for: bot)
        return HStack(spacing: 14) {
            ChessBotAvatar(bot: bot, size: 56)
                .saturation(unlocked ? 1 : 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(bot.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("Level \(bot.level) · \(bot.title)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if unlocked {
                    ChessBotLevelStars(level: bot.level)
                    if record.wins + record.losses + record.draws > 0 {
                        ChessBotRecordLine(record: record)
                    }
                } else if let previous = ChessBot.all.first(where: { $0.level == bot.level - 1 }) {
                    Text("Beat \(previous.name) to unlock")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: unlocked ? "chevron.right" : "lock.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
        .opacity(unlocked ? 1 : 0.6)
        .contentShape(Rectangle())
    }
}

/// One bot before a game: who they are, the record against them, which side to play, what a
/// game costs on chain - then Play.
struct ChessBotDetailView: View {
    let bot: ChessBot
    /// The challenge from a KaPost that opened this screen.
    var challenge: ChessBotChallenge? = nil

    @ObservedObject private var progress = ChessBotProgress.shared
    @State private var side: ChessBotSidePreference = .white
    @State private var playing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    ChessBotAvatar(bot: bot, size: 104)
                    Text(bot.name)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Level \(bot.level) · \(bot.title)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)
                    ChessBotLevelStars(level: bot.level)
                    Text(bot.bio)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                }
                .padding(.top, 20)

                if let challenge {
                    ChessBotChallengeBanner(challenge: challenge)
                        .padding(.horizontal, 16)
                }

                let record = progress.record(for: bot)
                HStack {
                    Text("Your record")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    ChessBotRecordLine(record: record)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
                .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Play as")
                        .font(.subheadline.weight(.semibold))
                    Picker("Play as", selection: $side) {
                        ForEach(ChessBotSidePreference.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
                .padding(.horizontal, 16)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "link")
                        .foregroundColor(.accentColor)
                    Text(feeLine)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            Button {
                Haptics.impact(.medium)
                playing = true
            } label: {
                Text("Play \(bot.name)")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .fixedScreenTitle(Text(bot.name))
        .background(Color(.systemGroupedBackground))
        .navigationTitle(bot.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
        }
        .navigationDestination(isPresented: $playing) {
            ChessBotGameView(bot: bot, side: side)
        }
    }

    private var feeLine: String {
        let fee = ChessBotCodec.stampFeeText().map { "about \($0)" } ?? "one small fee"
        return "The game itself is free. When it ends, win or lose, its result is stamped on Kaspa: one transaction from your wallet, \(fee)."
    }
}

/// A bot's face: initials on its gradient, its level in a badge.
struct ChessBotAvatar: View {
    let bot: ChessBot
    var size: CGFloat = 44

    var body: some View {
        Text(bot.initials)
            .font(.scaled(size: size * 0.36, weight: .heavy))
            .foregroundColor(.white)
            .shadow(color: Color.black.opacity(0.25), radius: 1, x: 0, y: 1)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: bot.colors, startPoint: .top, endPoint: .bottom)))
            .overlay(alignment: .bottomTrailing) {
                Text("\(bot.level)")
                    .font(.scaled(size: size * 0.2, weight: .heavy))
                    .foregroundColor(.primary)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .background(Circle().fill(Color(.systemBackground)))
                    .overlay(Circle().stroke(bot.colors.last ?? .accentColor, lineWidth: 1.5))
            }
    }
}

/// Five stars, `level` of them filled.
struct ChessBotLevelStars: View {
    let level: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= level ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundColor(star <= level ? Color.orange : Color.secondary.opacity(0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level \(level) of 5")
    }
}

struct ChessBotRecordLine: View {
    let record: ChessBotProgress.Record

    var body: some View {
        HStack(spacing: 8) {
            Text("\(record.wins) W").foregroundColor(.green)
            Text("\(record.losses) L").foregroundColor(.red)
            Text("\(record.draws) D").foregroundColor(.secondary)
        }
        .font(.caption.monospacedDigit().weight(.semibold))
    }
}
