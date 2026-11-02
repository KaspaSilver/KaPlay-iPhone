import SwiftUI

/// A game against a bot. Play again starts a fresh game (and a fresh `ChessBotGame`) in place.
struct ChessBotGameView: View {
    let bot: ChessBot
    let side: ChessBotSidePreference
    @State private var round = 0

    var body: some View {
        ChessBotMatchView(bot: bot, playerColor: side.resolve()) { round += 1 }
            .id(round)
    }
}

/// The board against the bot, laid out like the online board: who you play and where the game
/// stands, the board, then where the game's stamp on chain stands and the moves so far.
private struct ChessBotMatchView: View {
    @StateObject private var game: ChessBotGame
    let onPlayAgain: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedSquare: ChessSquare?
    @State private var pendingPromotion: ChessMove?
    @State private var showResignConfirm = false
    /// The back button while the game is on: leaving means resigning, and it asks.
    @State private var showLeaveWarning = false
    @State private var showEnd = false

    init(bot: ChessBot, playerColor: ChessColor, onPlayAgain: @escaping () -> Void) {
        _game = StateObject(wrappedValue: ChessBotGame(bot: bot, playerColor: playerColor))
        self.onPlayAgain = onPlayAgain
    }

    private var bot: ChessBot { game.bot }
    /// Drawn from the player's side: playing black puts black at the bottom.
    private var flipped: Bool { game.playerColor == .black }
    private var isLockedIn: Bool { !game.isOver }

    var body: some View {
        VStack(spacing: 12) {
            header
            board
                .padding(.horizontal)
                .layoutPriority(1)
            chainBar
                .padding(.horizontal)
            moveList
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Level \(bot.level)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { ScreenTitleToolbarLabel(title: Text("Level \(bot.level)")) }
            if isLockedIn {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showLeaveWarning = true
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Back")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showResignConfirm = true
                    } label: {
                        Text("Resign")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(isLockedIn)
        .toolbar(isLockedIn ? .hidden : .visible, for: .tabBar)
        .sheet(isPresented: $showResignConfirm) {
            resignSheet(leaving: false)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLeaveWarning) {
            resignSheet(leaving: true)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $pendingPromotion) { move in
            promotionSheet(move)
        }
        .onAppear { game.start() }
        .onChange(of: game.result) { result in
            guard let result else { return }
            selectedSquare = nil
            switch result {
            case .won: Haptics.success()
            case .lost: Haptics.error()
            case .drawn: Haptics.impact(.medium)
            }
            withAnimation(.easeOut(duration: 0.25)) { showEnd = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ChessBotAvatar(bot: bot, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Level \(bot.level) · \(bot.title) · You play \(game.playerColor == .white ? "white" : "black")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if game.isThinking {
                    ProgressView()
                }
            }
            Text(statusText)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(game.isOver ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
    }

    private var statusText: String {
        if let result = game.result {
            switch result {
            case .won(let why): return "You won by \(why) in \(game.playerMoveCount) moves."
            case .lost(let why): return why == "resignation" ? "You resigned. \(bot.name) wins." : "\(bot.name) won by \(why)."
            case .drawn(let why): return "Draw by \(why)."
            }
        }
        if game.isThinking { return "\(bot.name) is thinking…" }
        if game.board.sideToMove == game.playerColor {
            return ChessEngine.isKingInCheck(color: game.playerColor, board: game.board) ? "Check. Your move." : "Your move"
        }
        return "\(bot.name) to move"
    }

    // MARK: - Board

    private var legalDestinations: [ChessSquare] {
        guard let selectedSquare, game.canPlayerMove else { return [] }
        return ChessEngine.legalMoves(from: selectedSquare, board: game.board).map { $0.to }
    }

    /// The king of the side to move, when it is in check - tinted red.
    private var checkedKing: ChessSquare? {
        let side = game.board.sideToMove
        guard ChessEngine.isKingInCheck(color: side, board: game.board) else { return nil }
        for rank in 0..<8 {
            for file in 0..<8 {
                let square = ChessSquare(file: file, rank: rank)
                if let piece = game.board.piece(at: square), piece.type == .king, piece.color == side { return square }
            }
        }
        return nil
    }

    private var board: some View {
        GeometryReader { proxy in
            let size = proxy.size.width / 8
            let ranks = flipped ? Array(0..<8) : Array((0..<8).reversed())
            let files = flipped ? Array((0..<8).reversed()) : Array(0..<8)
            let destinations = legalDestinations
            let checked = checkedKing
            ZStack {
                VStack(spacing: 0) {
                    ForEach(ranks, id: \.self) { rank in
                        HStack(spacing: 0) {
                            ForEach(files, id: \.self) { file in
                                square(ChessSquare(file: file, rank: rank), size: size, destinations: destinations, checked: checked)
                            }
                        }
                    }
                }
                if showEnd, let result = game.result {
                    endOverlay(result)
                        .transition(.opacity)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func square(_ sq: ChessSquare, size: CGFloat, destinations: [ChessSquare], checked: ChessSquare?) -> some View {
        let isLight = !(sq.file + sq.rank).isMultiple(of: 2)
        let last = game.moves.last?.move
        let isLast = last.map { $0.from == sq || $0.to == sq } ?? false
        return ZStack {
            Rectangle().fill(isLight ? ChessBoardThumbnail.lightSquareColor : ChessBoardThumbnail.darkSquareColor)
            if isLast { Rectangle().fill(Color.yellow.opacity(0.35)) }
            if checked == sq { Rectangle().fill(Color.red.opacity(0.45)) }
            if selectedSquare == sq { Rectangle().fill(Color.accentColor.opacity(0.35)) }
            if let piece = game.board.piece(at: sq) {
                ChessPieceGlyphView(piece: piece, fontSize: size * 0.7)
            }
            if destinations.contains(sq) {
                Circle().fill(Color.accentColor.opacity(0.55)).frame(width: size * 0.3, height: size * 0.3)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { tap(sq) }
    }

    private func tap(_ sq: ChessSquare) {
        guard game.canPlayerMove else { return }
        let mine = game.playerColor
        if let from = selectedSquare {
            if legalDestinations.contains(sq) {
                let move = ChessMove(from: from, to: sq, promotion: nil)
                selectedSquare = nil
                if game.board.piece(at: from)?.type == .pawn, sq.rank == (mine == .white ? 7 : 0) {
                    pendingPromotion = move
                } else {
                    Haptics.impact(.light)
                    game.play(move)
                }
                return
            }
            selectedSquare = game.board.piece(at: sq)?.color == mine ? sq : nil
            return
        }
        if game.board.piece(at: sq)?.color == mine { selectedSquare = sq }
    }

    private func promotionSheet(_ move: ChessMove) -> some View {
        VStack(spacing: 12) {
            Text("Promote to").font(.headline).padding(.top, 20)
            HStack(spacing: 18) {
                ForEach([ChessPieceType.queen, .rook, .bishop, .knight], id: \.self) { type in
                    Button {
                        pendingPromotion = nil
                        Haptics.impact(.light)
                        game.play(ChessMove(from: move.from, to: move.to, promotion: type))
                    } label: {
                        ChessPieceGlyphView(piece: ChessPiece(type: type, color: game.playerColor), fontSize: 44)
                            .frame(width: 60, height: 60)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .presentationDetents([.height(180)])
    }

    // MARK: - End of game

    private func endOverlay(_ result: ChessBotProgress.Result) -> some View {
        let (icon, headline, tint): (String, String, Color) = {
            switch result {
            case .won: return ("trophy.fill", "You won!", .orange)
            case .lost: return ("flag.fill", "You lost", .red)
            case .drawn: return ("equal.circle.fill", "Draw", .secondary)
            }
        }()
        let unlocked: ChessBot? = {
            guard case .won = result else { return nil }
            return ChessBot.all.first { $0.level == bot.level + 1 }
        }()
        return ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.scaled(size: 40))
                    .foregroundColor(tint)
                Text(headline)
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                if let unlocked, ChessBotProgress.shared.record(for: bot).wins == 1 {
                    Text("\(unlocked.name) is unlocked!")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.orange)
                }
                if case .won = result {
                    shareButton
                        .padding(.top, 6)
                }
                HStack(spacing: 10) {
                    Button {
                        onPlayAgain()
                    } label: {
                        Text("Play again")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.2))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                Button {
                    withAnimation { showEnd = false }
                } label: {
                    Text("See the board")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
    }

    /// Share to KaPost, once the win is on chain: what the post shows off can be looked up.
    private var shareButton: some View {
        let title: String = {
            switch game.stamp {
            case .stamped: return "Share to KaPost"
            case .failed: return "Retry the stamp"
            case .none, .sending: return "Stamping the result…"
            }
        }()
        return Button {
            switch game.stamp {
            case .stamped:
                Haptics.impact(.light)
                ChessBotLinks.shareToKaPost(bot: bot, moves: game.playerMoveCount, gameId: game.id)
            case .failed:
                game.retry()
            case .none, .sending:
                break
            }
        } label: {
            Label(title, systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.orange)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(game.stamp == .sending || game.stamp == .none)
    }

    // MARK: - Resign

    private func resignSheet(leaving: Bool) -> some View {
        let consequence = "It counts as a loss against \(bot.name), and the result goes on Kaspa in one transaction."
        return VStack(spacing: 16) {
            Image(systemName: leaving ? "rectangle.portrait.and.arrow.right" : "flag.fill")
                .font(.scaled(size: 34))
                .foregroundColor(.red)
                .padding(.top, 28)
            Text(leaving ? "Leave the game?" : "Resign this game?")
                .font(.title3.weight(.bold))
            Text(leaving ? "If you leave, you resign the game. \(consequence)" : consequence)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button {
                    showResignConfirm = false
                    showLeaveWarning = false
                    game.resign()
                    if leaving { dismiss() }
                } label: {
                    Text(leaving ? "Resign and leave" : "Resign")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                Button {
                    showResignConfirm = false
                    showLeaveWarning = false
                } label: {
                    Text(leaving ? "Stay" : "Keep playing")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    // MARK: - On chain, and the moves

    /// Where the stamp stands: a spinner while it goes out, a check once it is on chain, Retry
    /// when it failed.
    private var chainBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundColor(.accentColor)
                Text(chainText)
                    .font(.caption.weight(.semibold))
                Spacer()
                switch game.stamp {
                case .none:
                    EmptyView()
                case .sending:
                    ProgressView()
                        .scaleEffect(0.8)
                case .stamped:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                case .failed:
                    Button("Retry") { game.retry() }
                        .font(.caption.weight(.bold))
                }
            }
            if case .failed(let error) = game.stamp {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var chainText: String {
        switch game.stamp {
        case .none: return "The result goes on Kaspa when the game ends"
        case .sending: return "Stamping the result on Kaspa…"
        case .stamped: return "Result stamped on Kaspa"
        case .failed: return "Couldn't stamp the result on Kaspa"
        }
    }

    private struct MovePair: Identifiable {
        let number: Int
        let white: String
        let black: String?
        var id: Int { number }
    }

    /// The moves in short notation, numbered in pairs, following the newest.
    private var moveList: some View {
        let moves = game.moves
        let pairs: [MovePair] = stride(from: 0, to: moves.count, by: 2).map { index in
            MovePair(
                number: index / 2 + 1,
                white: notation(moves[index]),
                black: index + 1 < moves.count ? notation(moves[index + 1]) : nil
            )
        }
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    if pairs.isEmpty {
                        Text(game.playerColor == .white ? "You move first." : "\(bot.name) moves first.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(pairs) { pair in
                        HStack(spacing: 5) {
                            Text("\(pair.number).").foregroundColor(.secondary)
                            Text(pair.white)
                            if let black = pair.black { Text(black) }
                        }
                        .id(pair.number)
                    }
                }
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .padding(.horizontal)
            }
            .onChange(of: game.moves.count) { _ in
                if let last = pairs.last { withAnimation { proxy.scrollTo(last.number, anchor: .trailing) } }
            }
        }
    }

    private func notation(_ played: ChessBotGame.PlayedMove) -> String {
        let move = played.move
        if played.piece == .king && abs(move.to.file - move.from.file) == 2 {
            return move.to.file == 6 ? "O-O" : "O-O-O"
        }
        let letter: String
        switch played.piece {
        case .pawn: letter = played.captured != nil ? String(move.from.algebraic.prefix(1)) : ""
        case .knight: letter = "N"
        case .bishop: letter = "B"
        case .rook: letter = "R"
        case .queen: letter = "Q"
        case .king: letter = "K"
        }
        let promotion = move.promotion.map { "=" + ($0.promotionLetter ?? "q").uppercased() } ?? ""
        return letter + (played.captured != nil ? "x" : "") + move.to.algebraic + promotion
    }
}
