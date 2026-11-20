import SwiftUI

/// The tournament as a bracket - quarterfinals, semifinals, final, champion - with the pairs
/// joined by lines, every game a card you can tap to watch. Live games carry a LIVE pill and
/// the running clock; finished ones mark the winner; a pair not yet decided shows who it is
/// waiting on. Your own games get the accent border.
struct ChessBracketView: View {
    let tournament: ChessTournament
    let me: String?
    let now: Int64
    let onOpenGame: (String) -> Void

    // Scaled with the text size: fixed heights clipped the names at large Dynamic Type sizes.
    @ScaledMetric(relativeTo: .caption) private var cardWidth: CGFloat = 164
    @ScaledMetric(relativeTo: .caption) private var cardHeight: CGFloat = 66
    @ScaledMetric(relativeTo: .caption) private var labelHeight: CGFloat = 26
    private static let rowGap: CGFloat = 14
    private static let columnGap: CGFloat = 40

    private var columnX: [CGFloat] { (0..<4).map { CGFloat($0) * (cardWidth + Self.columnGap) } }
    private var round1Y: [CGFloat] { (0..<4).map { CGFloat($0) * (cardHeight + Self.rowGap) } }
    private var semiY: [CGFloat] { [midpoint(round1Y[0], round1Y[1]), midpoint(round1Y[2], round1Y[3])] }
    private var finalY: CGFloat { midpoint(semiY[0], semiY[1]) }
    private func midpoint(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + b) / 2 }
    private var contentHeight: CGFloat { round1Y[3] + cardHeight }
    private var contentWidth: CGFloat { columnX[3] + cardWidth }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(([ "Quarterfinals", "Semifinals", "Final", "Champion"] as [LocalizedStringKey]).enumerated()), id: \.offset) { index, title in
                        Text(title)
                            .font(.caption.weight(.bold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                            .frame(width: cardWidth, alignment: .leading)
                        if index < 3 { Spacer().frame(width: Self.columnGap) }
                    }
                }
                .frame(height: labelHeight)
                ZStack(alignment: .topLeading) {
                    connectors
                    ForEach(0..<4, id: \.self) { index in
                        matchCard(gameId: "1-\(index)", placeholder: (ChessText.format("Seed %lld", seedPair(index).0), ChessText.format("Seed %lld", seedPair(index).1)))
                            .offset(x: columnX[0], y: round1Y[index])
                    }
                    ForEach(0..<2, id: \.self) { index in
                        matchCard(gameId: "2-\(index)", placeholder: (ChessText.format("Winner of QF%lld", index * 2 + 1), ChessText.format("Winner of QF%lld", index * 2 + 2)))
                            .offset(x: columnX[1], y: semiY[index])
                    }
                    matchCard(gameId: "3-0", placeholder: (ChessText.format("Winner of SF%lld", 1), ChessText.format("Winner of SF%lld", 2)))
                        .offset(x: columnX[2], y: finalY)
                    championCard
                        .offset(x: columnX[3], y: finalY)
                }
                .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
            }
            .padding(16)
        }
    }

    /// Round 1 pairs by seed: 1v8, 2v7, 3v6, 4v5.
    private func seedPair(_ index: Int) -> (Int, Int) { (index + 1, 8 - index) }

    // MARK: - Lines

    private var connectors: some View {
        Path { path in
            let w = cardWidth, h = cardHeight / 2, gap = Self.columnGap / 2
            func join(fromX: CGFloat, fromYs: [CGFloat], toX: CGFloat, toY: CGFloat) {
                for y in fromYs {
                    path.move(to: CGPoint(x: fromX + w, y: y + h))
                    path.addLine(to: CGPoint(x: fromX + w + gap, y: y + h))
                    path.addLine(to: CGPoint(x: fromX + w + gap, y: toY + h))
                }
                path.move(to: CGPoint(x: fromX + w + gap, y: toY + h))
                path.addLine(to: CGPoint(x: toX, y: toY + h))
            }
            join(fromX: columnX[0], fromYs: [round1Y[0], round1Y[1]], toX: columnX[1], toY: semiY[0])
            join(fromX: columnX[0], fromYs: [round1Y[2], round1Y[3]], toX: columnX[1], toY: semiY[1])
            join(fromX: columnX[1], fromYs: [semiY[0], semiY[1]], toX: columnX[2], toY: finalY)
            join(fromX: columnX[2], fromYs: [finalY], toX: columnX[3], toY: finalY)
        }
        .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Cards

    private func matchCard(gameId: String, placeholder: (String, String)) -> some View {
        let game = tournament.games[gameId]
        let mine = game.map { me != nil && ($0.white == me || $0.black == me) } ?? false
        return Button {
            if let game { onOpenGame(game.id) }
        } label: {
            VStack(spacing: 0) {
                if let game {
                    playerRow(address: game.white, game: game)
                    Divider().padding(.horizontal, 8)
                    playerRow(address: game.black, game: game)
                } else {
                    placeholderRow(placeholder.0)
                    Divider().padding(.horizontal, 8)
                    placeholderRow(placeholder.1)
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(mine ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: mine ? 1.6 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if let game { statusPill(game) }
            }
        }
        .buttonStyle(.plain)
        .disabled(game == nil)
    }

    /// Decided at `now`, as the other screens judge it: a game lost on time with no claim on
    /// chain yet already has its winner, and nobody to move.
    private func playerRow(address: String, game: ChessTournamentGame) -> some View {
        let winner = game.decidedWinner(at: now)
        let isWinner = winner == address
        let isLoser = winner != nil && !isWinner
        let toMove = !game.isDecided(at: now) && game.address(of: game.sideToMove) == address
        return HStack(spacing: 6) {
            KNSAvatarView(
                avatarURLString: KNSService.shared.profileCache[address]?.avatarURL,
                fallbackText: ContactsManager.shared.displayName(for: address),
                size: 20,
                contactAddress: address
            )
            Text(ContactsManager.shared.displayName(for: address))
                .font(.caption.weight(isWinner ? .bold : .semibold))
                .lineLimit(1)
                .foregroundColor(isLoser ? .secondary : .primary)
            Spacer(minLength: 2)
            if isWinner {
                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
            } else if toMove {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: cardHeight / 2 - 0.5)
        .opacity(isLoser ? 0.55 : 1)
    }

    private func placeholderRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3]))
                .frame(width: 20, height: 20)
            Text(verbatim: text)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 8)
        .frame(height: cardHeight / 2 - 0.5)
    }

    @ViewBuilder
    private func statusPill(_ game: ChessTournamentGame) -> some View {
        // Not once the clock has decided it: that read "LIVE 0:00" with no winner forever.
        if !game.isDecided(at: now) {
            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 5, height: 5)
                // The running clock alone observes the arena's clock (`ChessLiveClockText`).
                ChessLiveClockText(game: game, format: { ChessText.format("LIVE %@", $0) })
                    .font(.scaled(size: 9, weight: .bold).monospacedDigit())
            }
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red.opacity(0.85)))
            .offset(x: -6, y: -8)
        }
    }

    private var championCard: some View {
        let champion = tournament.champion
        return HStack(spacing: 8) {
            if let champion {
                KNSAvatarView(
                    avatarURLString: KNSService.shared.profileCache[champion]?.avatarURL,
                    fallbackText: ContactsManager.shared.displayName(for: champion),
                    size: 28,
                    contactAddress: champion
                )
                VStack(alignment: .leading, spacing: 2) {
                    // Orange: yellow text can't be read on the light card.
                    Label("Champion", systemImage: "trophy.fill")
                        .font(.scaled(size: 9, weight: .bold))
                        .foregroundColor(.orange)
                    Text(ContactsManager.shared.displayName(for: champion))
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                }
            } else {
                Image(systemName: "trophy")
                    .font(.title3)
                    .foregroundColor(.orange.opacity(0.7))
                Text("To be decided")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: cardWidth, height: cardHeight)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.yellow.opacity(champion == nil ? 0.06 : 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.5), lineWidth: 1))
    }
}
