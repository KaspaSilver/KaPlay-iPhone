import Foundation

/// One game against a bot (Play > Bots). The whole game lives on this phone and costs nothing
/// while it is played; when it ends, its result and moves go on chain in one transaction, the
/// stamp (ONLINE_CHESS.md §7). A stamp that fails holds until Retry, and only a stamped win counts
/// toward the player's best on the bot's leaderboard.
@MainActor
final class ChessBotGame: ObservableObject {
    struct PlayedMove {
        let move: ChessMove
        let color: ChessColor
        let piece: ChessPieceType
        let captured: ChessPieceType?
    }

    /// Where the result's transaction stands.
    enum Stamp: Equatable {
        /// The game is still on.
        case none
        case sending
        case stamped
        case failed(String)
    }

    let bot: ChessBot
    let playerColor: ChessColor
    let id = UUID().uuidString.lowercased()

    @Published private(set) var board = ChessEngine.initialBoard()
    @Published private(set) var moves: [PlayedMove] = []
    @Published private(set) var result: ChessBotProgress.Result?
    @Published private(set) var isThinking = false
    @Published private(set) var stamp: Stamp = .none

    private var started = false
    private var positionCounts: [String: Int] = [:]
    private var halfmoveClock = 0

    init(bot: ChessBot, playerColor: ChessColor) {
        self.bot = bot
        self.playerColor = playerColor
    }

    var botColor: ChessColor { playerColor.opposite }
    var isOver: Bool { result != nil }

    /// The player may move: their turn, the bot not thinking.
    var canPlayerMove: Bool {
        !isOver && board.sideToMove == playerColor && !isThinking
    }

    /// The moves the player made, the number a win is ranked by.
    var playerMoveCount: Int {
        moves.filter { $0.color == playerColor }.count
    }

    /// The board opened: if the bot has white it moves now.
    func start() {
        guard !started else { return }
        started = true
        positionCounts[ChessTournamentEngine.positionKey(board)] = 1
        botMoveIfDue()
    }

    func play(_ move: ChessMove) {
        guard canPlayerMove, ChessEngine.isLegal(move, in: board) else { return }
        apply(ChessEngine.normalizingPromotion(move, in: board))
    }

    func resign() {
        guard started, !isOver else { return }
        finish(.lost("resignation"))
    }

    func retry() {
        guard case .failed = stamp else { return }
        sendStamp()
    }

    // MARK: - The board

    private func apply(_ move: ChessMove) {
        guard let piece = board.piece(at: move.from) else { return }
        let isEnPassant = piece.type == .pawn && move.to == board.enPassantTarget && board.piece(at: move.to) == nil
        let captured = board.piece(at: move.to)?.type ?? (isEnPassant ? .pawn : nil)
        let mover = board.sideToMove
        board = ChessEngine.apply(move, to: board)
        moves.append(PlayedMove(move: move, color: mover, piece: piece.type, captured: captured))

        halfmoveClock = (piece.type == .pawn || captured != nil) ? 0 : halfmoveClock + 1
        let key = ChessTournamentEngine.positionKey(board)
        positionCounts[key, default: 0] += 1

        if ChessEngine.isCheckmate(board) {
            finish(mover == playerColor ? .won("checkmate") : .lost("checkmate"))
        } else if ChessEngine.isStalemate(board) {
            finish(.drawn("stalemate"))
        } else if ChessEngine.isInsufficientMaterial(board) {
            finish(.drawn("insufficient material"))
        } else if halfmoveClock >= 100 {
            finish(.drawn("the fifty-move rule"))
        } else if positionCounts[key, default: 0] >= 3 {
            finish(.drawn("threefold repetition"))
        }
        botMoveIfDue()
    }

    private func finish(_ result: ChessBotProgress.Result) {
        guard self.result == nil else { return }
        self.result = result
        ChessBotProgress.shared.add(result, against: bot)
        sendStamp()
    }

    /// The bot's turn: think off the main thread (never quicker than a beat, so a reply does not
    /// land in the same instant as the player's move), then play.
    private func botMoveIfDue() {
        guard !isOver, board.sideToMove == botColor, !isThinking else { return }
        isThinking = true
        let position = board
        let settings = bot.searchSettings(atPly: moves.count)
        let avoiding = repeatingMoves()
        let began = Date()
        Task {
            let move = await Task.detached(priority: .userInitiated) {
                ChessBotEngine.bestMove(for: position, settings: settings, avoiding: avoiding)
            }.value
            let elapsed = Date().timeIntervalSince(began)
            if elapsed < 0.8 {
                try? await Task.sleep(nanoseconds: UInt64((0.8 - elapsed) * 1_000_000_000))
            }
            isThinking = false
            guard !isOver, let move, board == position else { return }
            apply(move)
        }
    }

    /// The bot's moves that bring back a position already seen this game.
    private func repeatingMoves() -> [ChessMove] {
        ChessEngine.legalMoves(for: board).filter { move in
            positionCounts[ChessTournamentEngine.positionKey(ChessEngine.apply(move, to: board))] != nil
        }
    }

    // MARK: - On chain

    /// Goes on even if the player leaves the screen: the task holds the game until it is done.
    private func sendStamp() {
        guard let result, stamp != .sending, stamp != .stamped else { return }
        stamp = .sending
        let message = ChessBotCodec.result(
            id: id, bot: bot, playerColor: playerColor, result: result, moves: moves.map(\.move)
        )
        Task {
            if let error = await send(message) {
                stamp = .failed(error)
                return
            }
            stamp = .stamped
            if case .won = result {
                ChessBotProgress.shared.addStampedWin(moves: playerMoveCount, against: bot)
            }
        }
    }

    /// One broadcast transaction, with the retries a send needs while the change of the last
    /// transaction is not spendable yet (the arena's sends do the same). Returns the error to
    /// show, or nil once it is sent.
    private func send(_ message: ChessBotMessage) async -> String? {
        let content = ChessBotCodec.encode(message)
        var attempt = 0
        while true {
            do {
                try await PublicChatService.shared.sendPublicChat(channel: ChessBotCodec.channel, content: content)
                return nil
            } catch {
                attempt += 1
                if attempt > 5 {
                    AppLog.log("[Chess] Bot game stamp failed after retries: %@", error.localizedDescription)
                    return error.localizedDescription
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}
