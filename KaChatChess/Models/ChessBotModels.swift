import SwiftUI

/// A bot to play in Play > Bots: five characters, one per level. Level 1 is open from the
/// start; each one after opens when the one before it is beaten.
struct ChessBot: Identifiable, Hashable {
    let level: Int
    let name: String
    let title: String
    let bio: String
    let initials: String
    /// The avatar's gradient, top to bottom.
    let colors: [Color]
    let settings: ChessBotEngine.Settings

    var id: Int { level }

    static func == (lhs: ChessBot, rhs: ChessBot) -> Bool { lhs.level == rhs.level }
    func hash(into hasher: inout Hasher) { hasher.combine(level) }

    /// The search for the move at `ply` (0 = the game's first). The master varies its opening
    /// a little so no two games start the same; past the opening it plays its best.
    func searchSettings(atPly ply: Int) -> ChessBotEngine.Settings {
        guard settings.noise == 0, ply < 8 else { return settings }
        return ChessBotEngine.Settings(
            depth: settings.depth, quiescence: settings.quiescence, noise: 12,
            randomChance: settings.randomChance, timeLimit: settings.timeLimit
        )
    }

    static let all: [ChessBot] = [
        ChessBot(
            level: 1, name: "Kaspa Silver", title: "Beginner",
            bio: "Here for the fun of it. Moves fast and sometimes leaves a piece hanging.",
            initials: "KS",
            colors: [Color(red: 0.78, green: 0.80, blue: 0.84), Color(red: 0.50, green: 0.53, blue: 0.58)],
            settings: .init(depth: 1, quiescence: false, noise: 250, randomChance: 0.35, timeLimit: 1)
        ),
        ChessBot(
            level: 2, name: "Izio Dev", title: "Novice",
            bio: "Knows how every piece moves and loves grabbing free material. Watch your loose pawns.",
            initials: "ID",
            colors: [Color(red: 0.36, green: 0.80, blue: 0.86), Color(red: 0.12, green: 0.52, blue: 0.66)],
            settings: .init(depth: 1, quiescence: true, noise: 100, randomChance: 0.12, timeLimit: 1)
        ),
        ChessBot(
            level: 3, name: "Coderofstuff", title: "Intermediate",
            bio: "Looks a couple of moves ahead before committing. Steady and hard to trick.",
            initials: "CS",
            colors: [Color(red: 0.44, green: 0.78, blue: 0.73), Color(red: 0.16, green: 0.55, blue: 0.47)],
            settings: .init(depth: 2, quiescence: true, noise: 40, randomChance: 0.04, timeLimit: 2)
        ),
        ChessBot(
            level: 4, name: "Michael Sutton", title: "Advanced",
            bio: "Calculates carefully and punishes mistakes. Come with a plan.",
            initials: "MS",
            colors: [Color(red: 0.55, green: 0.55, blue: 0.95), Color(red: 0.32, green: 0.25, blue: 0.72)],
            settings: .init(depth: 3, quiescence: true, noise: 12, randomChance: 0, timeLimit: 3)
        ),
        ChessBot(
            level: 5, name: "Yonatan Sompolinsky", title: "Master",
            bio: "Thinks deep and sees far. Beat this one and you have climbed the whole ladder.",
            initials: "YS",
            colors: [Color(red: 0.98, green: 0.80, blue: 0.36), Color(red: 0.85, green: 0.52, blue: 0.10)],
            settings: .init(depth: 6, quiescence: true, noise: 0, randomChance: 0, timeLimit: 4)
        )
    ]
}

/// The player's colour choice before a bot game.
enum ChessBotSidePreference: String, CaseIterable, Identifiable {
    case white = "White"
    case random = "Random"
    case black = "Black"

    var id: String { rawValue }

    func resolve() -> ChessColor {
        switch self {
        case .white: return .white
        case .black: return .black
        case .random: return Bool.random() ? .white : .black
        }
    }
}

// MARK: - On chain (ONLINE_CHESS.md §7)

/// A finished bot game's stamp: plaintext broadcast JSON in `#chess-bots`, signed by the player's
/// address, sent once when the game ends.
struct ChessBotMessage: Codable, Equatable {
    var type: String = "chess_bot"
    var v: Int = 2
    /// Game id: a lowercase UUID chosen by the player's phone.
    let g: String
    var a: String = "result"
    /// The bot's level, 1...5.
    let bot: Int
    /// The player's colour, "w" or "b".
    let c: String
    /// How it ended for the player: won, lost, drawn.
    let r: String
    /// Why: checkmate, resignation, stalemate, insufficient material, the fifty-move rule,
    /// threefold repetition.
    let why: String
    /// Every move of the game, both sides, space separated: "e2e4 e7e5", a promotion "e7e8q".
    let m: String
}

enum ChessBotCodec {
    static let channel = "chess-bots"

    static func result(
        id: String, bot: ChessBot, playerColor: ChessColor,
        result: ChessBotProgress.Result, moves: [ChessMove]
    ) -> ChessBotMessage {
        ChessBotMessage(
            g: id, bot: bot.level, c: playerColor == .white ? "w" : "b", r: result.code, why: result.why,
            m: moves.map(moveText).joined(separator: " ")
        )
    }

    private static func moveText(_ move: ChessMove) -> String {
        move.from.algebraic + move.to.algebraic + (move.promotion?.promotionLetter ?? "")
    }

    static func encode(_ message: ChessBotMessage) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(message), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// A stamp's fee, for the "about 0.0017 KAS" line: the same estimate the arena's Join button
    /// shows (one input), on a game of 40 moves a side. A longer game's stamp costs a little more.
    @MainActor
    static func stampFeeText() -> String? {
        guard let wallet = WalletManager.shared.currentWallet,
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else { return nil }
        let e4 = ChessMove(from: ChessSquare(file: 4, rank: 1), to: ChessSquare(file: 4, rank: 3), promotion: nil)
        let sample = result(
            id: UUID().uuidString.lowercased(), bot: ChessBot.all[0], playerColor: .white,
            result: .won("checkmate"), moves: Array(repeating: e4, count: 80)
        )
        let payload = KasiaTransactionBuilder.buildPublicChatPayload(channel: channel, content: encode(sample))
        let sompi = KasiaTransactionBuilder.estimatePublicChatFee(payload: payload, inputCount: 1, senderScriptPubKey: senderScriptPubKey)
        return String(format: "%.4f %@", Double(sompi) / 100_000_000, KaspaUnit.symbol)
    }
}

// MARK: - Record

/// The player's record against each bot, kept on this phone per address. A win against a bot
/// opens the next level.
@MainActor
final class ChessBotProgress: ObservableObject {
    static let shared = ChessBotProgress()

    struct Record: Codable, Equatable {
        var wins = 0
        var losses = 0
        var draws = 0
    }

    enum Result: Equatable {
        case won(String)
        case lost(String)
        case drawn(String)

        /// `r` in the stamp.
        var code: String {
            switch self {
            case .won: return "won"
            case .lost: return "lost"
            case .drawn: return "drawn"
            }
        }

        /// `why` in the stamp.
        var why: String {
            switch self {
            case .won(let why), .lost(let why), .drawn(let why): return why
            }
        }
    }

    /// A win that went on chain: how many moves the player took, and when (ms).
    struct StampedWin: Codable, Equatable {
        let moves: Int
        let at: Int64
    }

    /// Address -> level -> record.
    @Published private var records: [String: [Int: Record]]
    /// Address -> level -> wins, so the player's own best shows before the indexer has it.
    @Published private var stampedWins: [String: [Int: [StampedWin]]]

    private static let defaultsKey = "chessBotRecords"
    private static let stampedWinsKey = "chessBotStampedWins"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: [Int: Record]].self, from: data) {
            records = saved
        } else {
            records = [:]
        }
        if let data = UserDefaults.standard.data(forKey: Self.stampedWinsKey),
           let saved = try? JSONDecoder().decode([String: [Int: [StampedWin]]].self, from: data) {
            stampedWins = saved
        } else {
            stampedWins = [:]
        }
    }

    private var address: String { WalletManager.shared.currentWallet?.publicAddress ?? "" }

    func record(for bot: ChessBot) -> Record {
        records[address]?[bot.level] ?? Record()
    }

    func isUnlocked(_ bot: ChessBot) -> Bool {
        guard bot.level > 1, let previous = ChessBot.all.first(where: { $0.level == bot.level - 1 }) else { return true }
        return record(for: previous).wins > 0
    }

    func add(_ result: Result, against bot: ChessBot) {
        var record = record(for: bot)
        switch result {
        case .won: record.wins += 1
        case .lost: record.losses += 1
        case .drawn: record.draws += 1
        }
        records[address, default: [:]][bot.level] = record
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func addStampedWin(moves: Int, against bot: ChessBot) {
        let win = StampedWin(moves: moves, at: Int64(Date().timeIntervalSince1970 * 1000))
        stampedWins[address, default: [:]][bot.level, default: []].append(win)
        if let data = try? JSONEncoder().encode(stampedWins) {
            UserDefaults.standard.set(data, forKey: Self.stampedWinsKey)
        }
    }

    /// The player's fewest moves against `bot` since `since` (ms), the earlier win on a tie.
    func bestWin(against bot: ChessBot, since: Int64) -> StampedWin? {
        (stampedWins[address]?[bot.level] ?? [])
            .filter { $0.at >= since }
            .min { ($0.moves, $0.at) < ($1.moves, $1.at) }
    }
}
