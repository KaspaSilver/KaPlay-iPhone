import Foundation

/// A player's best game against one bot: the fewest moves they beat it in.
struct ChessBotBoardRow: Identifiable, Equatable {
    var id: String { address }
    let address: String
    let moves: Int
    /// Block time of the win (ms).
    let at: Int64
}

/// The bots' boards, from the indexer's `/chess/bots/leaderboard` (ONLINE_CHESS.md §7) with the
/// player's own stamped wins merged in, so a win shows the moment it is stamped. Any failure
/// leaves what is there in place.
@MainActor
final class ChessBotLeaderboardService: ObservableObject {
    static let shared = ChessBotLeaderboardService()

    private struct Board {
        var games = 0
        var rows: [ChessBotBoardRow] = []
    }

    private struct Response: Decodable {
        struct Bot: Decodable {
            struct Player: Decodable {
                let address: String
                let moves: Int
                let at: Int64
            }
            let level: Int
            let games: Int
            let players: [Player]
        }
        let period: String?
        let bots: [Bot]
    }

    /// Period -> level -> board.
    @Published private var boards: [ChessLeaderboardPeriod: [Int: Board]] = [:]

    /// The last refresh got no board at all: what's shown is what the phone already had.
    @Published private(set) var serverUnreachable = false

    private var lastFetch: Date?
    private var task: Task<Void, Never>?
    private var availabilityObserver: NSObjectProtocol?

    init() {
        // The chess server came back: the boards too, without waiting for a pull.
        availabilityObserver = NotificationCenter.default.addObserver(forName: .indexerAvailabilityChanged, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?["down"] as? Bool) == false else { return }
            Task { @MainActor [weak self] in
                self?.serverUnreachable = false
                self?.refresh(force: true)
            }
        }
    }

    /// At most every 20 s unless forced.
    func refresh(force: Bool = false) {
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < 20 { return }
        var base = PublicChatService.indexerBaseURL(forChannel: ChessBotCodec.channel)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty else { return }
        lastFetch = Date()
        task?.cancel()
        task = Task { [weak self] in
            var answered = false
            defer { if !Task.isCancelled { self?.serverUnreachable = !answered } }
            for period in ChessLeaderboardPeriod.allCases {
                guard var components = URLComponents(string: "\(base)/chess/bots/leaderboard") else { return }
                components.queryItems = [
                    URLQueryItem(name: "period", value: period.rawValue),
                    URLQueryItem(name: "limit", value: "100")
                ]
                guard let url = components.url else { return }
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let decoded = try? JSONDecoder().decode(Response.self, from: data),
                      decoded.period == period.rawValue else { continue }
                guard !Task.isCancelled, let self else { return }
                answered = true
                var levels: [Int: Board] = [:]
                for bot in decoded.bots {
                    levels[bot.level] = Board(
                        games: bot.games,
                        rows: bot.players.map { ChessBotBoardRow(address: $0.address, moves: $0.moves, at: $0.at) }
                    )
                }
                self.boards[period] = levels
                ChessTournamentService.shared.resolveNames(for: Set(levels.values.flatMap { $0.rows.map(\.address) }))
            }
        }
    }

    /// Fewest moves first, the earlier win on a tie.
    func rows(for bot: ChessBot, period: ChessLeaderboardPeriod) -> [ChessBotBoardRow] {
        var rows = boards[period]?[bot.level]?.rows ?? []
        let since = ChessTournamentEngine.periodSinceMs(period, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        if let address = WalletManager.shared.currentWallet?.publicAddress,
           let mine = ChessBotProgress.shared.bestWin(against: bot, since: since) {
            let own = ChessBotBoardRow(address: address, moves: mine.moves, at: mine.at)
            if let index = rows.firstIndex(where: { $0.address.lowercased() == address.lowercased() }) {
                if mine.moves < rows[index].moves { rows[index] = own }
            } else {
                rows.append(own)
            }
        }
        return rows.sorted { ($0.moves, $0.at, $0.address) < ($1.moves, $1.at, $1.address) }
    }

    /// Has anyone played this bot, as far as this phone can tell?
    func hasBeenPlayed(_ bot: ChessBot) -> Bool {
        let record = ChessBotProgress.shared.record(for: bot)
        if record.wins + record.losses + record.draws > 0 { return true }
        return (boards[.allTime]?[bot.level]?.games ?? 0) > 0
    }
}
