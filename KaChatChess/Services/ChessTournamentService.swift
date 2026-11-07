import Foundation
import Combine
import UIKit

/// Chess tournaments (ONLINE_CHESS.md): the `#chess-arena` room read through
/// `PublicChatService`, reduced by `ChessTournamentEngine` into the bracket every phone agrees
/// on, and the actions a player can take - each one a public chat transaction.
@MainActor
final class ChessTournamentService: ObservableObject {
    static let shared = ChessTournamentService()

    @Published private(set) var tournaments: [String: ChessTournament] = [:]
    /// All time (since `ChessTournamentEngine.leaderboardFreshFromMs`) and this UTC month: the
    /// indexer's boards (all history) merged with what this phone has read (the newest rows).
    @Published private(set) var leaderboard: [ChessLeaderboardRow] = []
    @Published private(set) var monthlyLeaderboard: [ChessLeaderboardRow] = []
    func board(for period: ChessLeaderboardPeriod) -> [ChessLeaderboardRow] {
        period == .month ? monthlyLeaderboard : leaderboard
    }
    /// Chain time as this phone estimates it: wall clock, for running clocks between blocks.
    @Published private(set) var now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    @Published var lastError: String?
    /// Moves sent and not yet seen back from the chain, so the board shows them at once and
    /// the player cannot double-send.
    @Published private(set) var pendingMoveGames: Set<String> = []

    private var cancellables = Set<AnyCancellable>()
    private var clockTask: Task<Void, Never>?
    /// While this player is waiting in a room or playing, the arena is pulled from the indexer
    /// every two seconds on top of the room's 8 s poll and the block scan - the other side's
    /// join or move should be on this phone in a couple of seconds, not ten.
    private var fastPollTask: Task<Void, Never>?
    private static let fastPollIntervalNanos: UInt64 = 2 * 1_000_000_000
    private var refCount = 0
    private var arenaJoined = false
    /// When a claim was last posted for a game (wall ms). One is enough when it takes; one the
    /// chain voided (a last-second move landed first, a clock ahead of the chain) or that failed
    /// to send is posted again after `claimRetryMs`, while the game is still undecided on chain.
    private var claimedGames: [String: Int64] = [:]
    private static let claimRetryMs: Int64 = 30_000
    /// The app claims by itself only for a flag this recent: an old game both players walked
    /// away from is not paid for on every launch. The board's Claim button covers the rest.
    private static let autoClaimWindowMs: Int64 = 30 * 60_000
    /// When each pending move was sent (wall ms): one the reducer still has not applied after
    /// `pendingMoveTimeoutMs` stops showing as sending. (One the network dropped is applied from
    /// its local row until `dropUnconfirmedRowsIfDue` takes it out.)
    private var pendingMoveSentAt: [String: Int64] = [:]
    private static let pendingMoveTimeoutMs: Int64 = 25_000
    /// Games whose claim is being sent right now: the board's Claim win does nothing while one is.
    @Published private(set) var claimsInFlight: Set<String> = []
    /// Taps on Claim win closer together than this are one claim.
    private static let claimTapGapMs: Int64 = 5_000
    /// An own arena transaction the chain has not shown this long after it was sent is looked up,
    /// and dropped when the network has never seen it (`PublicChatService.checkUnconfirmedServiceRows`).
    /// Blocks come ten a second and the indexer is polled every 2-8 s, so a transaction that
    /// landed is normally back in well under 10 s; 60 s also covers a slow indexer or an
    /// orphan waiting on its parent, and still leaves most of a five-minute clock to play the
    /// move again. One the network cannot be asked about is given up after five minutes.
    private static let unconfirmedRowMs: Int64 = 60_000
    private static let unconfirmedGiveUpMs: Int64 = 5 * 60_000
    /// The account the per-account state below belongs to.
    private var stateAddress: String?
    /// One replay at a time: asks that come in while one runs are served by a single replay
    /// after it (`reduceArena`).
    private var reduceTask: Task<Void, Never>?
    private var requestedReduce = 0
    private var appliedReduce = 0

    private init() {
        PublicChatService.shared.$messagesByChannel
            .map { $0[ChessTournamentCodec.arenaChannel] ?? [] }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.reduceArena() }
            }
            .store(in: &cancellables)
        // A queued join, a pending move or a claim belongs to the account that made it: after a
        // log out or a switch they must never be sent from the next one.
        WalletManager.shared.$currentWallet
            .map { $0?.publicAddress }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] address in self?.accountChanged(to: address) }
            .store(in: &cancellables)
    }

    private func accountChanged(to address: String?) {
        guard address != stateAddress else { return }
        stateAddress = address
        queuedPublicRoomId = nil
        pendingMoveGames = []
        pendingMoveSentAt = [:]
        claimedGames = [:]
        lastError = nil
    }

    var myAddress: String? { WalletManager.shared.currentWallet?.publicAddress }

    // MARK: - Watching the arena

    /// A chess screen came on: keep the arena scanned and polled while any is up.
    func acquire() {
        refCount += 1
        guard refCount == 1 else { return }
        let publicChat = PublicChatService.shared
        if !arenaJoined, !publicChat.channels.contains(where: { $0.channelName == ChessTournamentCodec.arenaChannel }) {
            publicChat.joinChannel(ChessTournamentCodec.arenaChannel)
        }
        arenaJoined = true
        publicChat.acquire(ChessTournamentCodec.arenaChannel)
        if let me = myAddress { resolveNames(for: [me]) }
        refreshIndexerLeaderboards()
        // The clock stood still while no chess screen was up: the first checks on this screen
        // must not read a time minutes old.
        now = Int64(Date().timeIntervalSince1970 * 1000)
        historyReady = false
        Task { [weak self] in
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if PublicChatService.shared.indexerFetchedChannels.contains(ChessTournamentCodec.arenaChannel)
                    || PublicChatService.indexerBaseURL(forChannel: ChessTournamentCodec.arenaChannel).isEmpty { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self?.historyReady = true
        }
        clockTask?.cancel()
        // Once a second: every chess screen re-renders on this. The board's clock chip draws
        // its own tenths in the last ten seconds from a local timeline (see `clockChip`).
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.now = Int64(Date().timeIntervalSince1970 * 1000)
                self.expirePendingMoves()
                self.dropUnconfirmedRowsIfDue()
                self.claimTimeoutsIfDue()
                // The 1st of the month (UTC) came while a chess screen was up: a new month board.
                if self.boardsMonthStart != 0, ChessTournamentEngine.utcMonthStartMs(self.now) != self.boardsMonthStart {
                    self.recomputeLocalBoards()
                    self.refreshIndexerLeaderboards(force: true)
                }
            }
        }
        fastPollTask?.cancel()
        fastPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.fastPollIntervalNanos)
                guard let self, !Task.isCancelled else { return }
                // Only while it matters: a seat held or a game on. Idle in the lobby, the
                // room's own poll is plenty.
                guard self.myActiveTournament != nil else { continue }
                await PublicChatService.shared.refreshFromIndexerNow(channel: ChessTournamentCodec.arenaChannel)
            }
        }
    }

    func release() {
        refCount = max(0, refCount - 1)
        guard refCount == 0 else { return }
        PublicChatService.shared.release(ChessTournamentCodec.arenaChannel)
        clockTask?.cancel()
        clockTask = nil
        fastPollTask?.cancel()
        fastPollTask = nil
    }

    /// Asks for a replay of the arena and returns once one that started after the ask has
    /// landed. Every change, not only a change in row COUNT: our own sends replace a pending
    /// row in place when the transaction lands, so the count stays the same - and a count guard
    /// here left a player's own leave (and moves) unapplied until the next unrelated row or a
    /// relaunch. The publisher already drops identical arrays.
    private func reduceArena() async {
        requestedReduce += 1
        let wanted = requestedReduce
        if reduceTask == nil {
            reduceTask = Task { [weak self] in await self?.runReduces() }
        }
        while appliedReduce < wanted, let task = reduceTask { await task.value }
    }

    /// The replay of the whole 30-day arena runs off the main thread: it is pure (value types
    /// and static rules), and on the main thread it froze the clocks and the board for as long
    /// as it took on every move. Never two at once: rows that change while one runs get one
    /// more replay after it, of the rows as they stand then.
    private func runReduces() async {
        while appliedReduce < requestedReduce {
            let target = requestedReduce
            let rows = PublicChatService.shared.messages(forChannel: ChessTournamentCodec.arenaChannel)
            let localStamps = PublicChatService.shared.locallyStampedTxIds
            let reduced = await Task.detached(priority: .userInitiated) { () -> [String: ChessTournament] in
                let events: [ChessArenaEvent] = rows.compactMap { row in
                    guard row.deliveryStatus == .sent, !row.id.hasPrefix("pending_"),
                          let message = ChessTournamentCodec.decode(row.content) else { return nil }
                    return ChessArenaEvent(txId: row.id, sender: row.senderAddress, blockTime: row.blockTime, message: message)
                }
                return ChessTournamentEngine.reduce(ChessTournamentService.orderingLocalStamps(events, localStamps: localStamps))
            }.value
            appliedReduce = target
            apply(reduced)
        }
        reduceTask = nil
    }

    private func apply(_ reduced: [String: ChessTournament]) {
        tournaments = reduced
        recomputeLocalBoards()
        resolveNames(for: Set(reduced.values.flatMap(\.players)))
        // Asked to join a public room that filled first: queue into the next one, once.
        if let queued = queuedPublicRoomId, let me = myAddress, let room = reduced[queued],
           room.isFull, !room.players.contains(me) {
            queuedPublicRoomId = nil
            let wasDuel = ChessTournamentCodec.duelNumber(of: queued) != nil
            Task { if wasDuel { await self.joinPublicDuelQueue() } else { await self.joinPublicQueue() } }
        } else if let queued = queuedPublicRoomId, let me = myAddress, reduced[queued]?.players.contains(me) == true {
            queuedPublicRoomId = nil
        }
        // A move of ours that the chain now shows is no longer pending.
        let mine = myAddress
        pendingMoveGames = pendingMoveGames.filter { key in
            guard let (tid, gid) = Self.split(key), let game = reduced[tid]?.games[gid] else { return true }
            return game.playerToMove == mine && !game.isOver
        }
        pendingMoveSentAt = pendingMoveSentAt.filter { pendingMoveGames.contains($0.key) }
    }

    /// Our own rows carry this phone's clock until the chain's block time reaches us
    /// (`PublicChatService.locallyStampedTxIds`). A clock ahead of the chain put our move after
    /// the reply to it, a clock behind before the move it answers - either way a move out of
    /// turn, ignored, and a board stuck until the chain's time came. Until then such a move sits
    /// between the moves of its game around it by ply, whatever the local stamp says. This
    /// phone's view only: every phone still reduces the chain's times once they are known.
    nonisolated private static func orderingLocalStamps(_ events: [ChessArenaEvent], localStamps: Set<String>) -> [ChessArenaEvent] {
        guard !localStamps.isEmpty else { return events }
        return events.map { event in
            let message = event.message
            guard localStamps.contains(event.txId), message.a == "move",
                  let gameId = message.g, let ply = message.n else { return event }
            var lower: Int64?
            var upper: Int64?
            for other in events where other.txId != event.txId && other.message.t == message.t
                && other.message.g == gameId && other.message.a == "move" {
                guard let otherPly = other.message.n else { continue }
                if otherPly < ply { lower = max(lower ?? other.blockTime, other.blockTime) }
                if otherPly > ply { upper = min(upper ?? other.blockTime, other.blockTime) }
            }
            var time = event.blockTime
            if let upper { time = min(time, upper - 1) }
            if let lower { time = max(time, lower + 1) }
            guard time != event.blockTime else { return event }
            return ChessArenaEvent(txId: event.txId, sender: event.sender, blockTime: time, message: message)
        }
    }

    /// Own arena transactions the network never took (`unconfirmedRowMs`) stop counting on this
    /// phone: the reducer drops them and the board is the chain's again - a dropped move is the
    /// player's to play again, and a timeout claim the board was waiting on goes out after all.
    /// Only once the arena's history is in, so a row the chain showed while the app was closed
    /// is found there first.
    private func dropUnconfirmedRowsIfDue() {
        guard historyReady else { return }
        Task {
            let dropped = await PublicChatService.shared.checkUnconfirmedServiceRows(
                olderThan: Self.unconfirmedRowMs, giveUpAfter: Self.unconfirmedGiveUpMs
            )
            guard !dropped.isEmpty else { return }
            let wasMove = tournaments.values.contains { tournament in
                tournament.games.values.contains { game in game.moves.contains { dropped.contains($0.txId) } }
            }
            lastError = wasMove
                ? "Your move didn't reach the network. Play it again."
                : "That didn't reach the network. Try again."
        }
    }

    /// A move the reducer never applied (it came too late for the clock, say): the board stops
    /// saying "Sending your move…".
    private func expirePendingMoves() {
        for (key, sentAt) in pendingMoveSentAt where now - sentAt > Self.pendingMoveTimeoutMs {
            pendingMoveSentAt[key] = nil
            pendingMoveGames.remove(key)
            lastError = "Your move didn't count. Check the board."
        }
    }

    private static func split(_ key: String) -> (String, String)? {
        guard let range = key.range(of: "|") else { return nil }
        return (String(key[..<range.lowerBound]), String(key[range.upperBound...]))
    }

    // MARK: - Lists

    /// The public room taking players right now: the first numbered room that is not full.
    /// Its id exists before anyone has joined it (the first join creates it), so the lobby can
    /// always show "Public tournament #N" with its seats.
    var currentPublicRoomId: String {
        ChessTournamentCodec.publicId(currentRoomNumber(numberOf: ChessTournamentCodec.publicNumber(of:)))
    }
    var currentPublicRoom: ChessTournament? { tournaments[currentPublicRoomId] }

    /// The public 1v1 room taking players right now.
    var currentDuelRoomId: String {
        ChessTournamentCodec.duelId(currentRoomNumber(numberOf: ChessTournamentCodec.duelNumber(of:)))
    }
    var currentDuelRoom: ChessTournament? { tournaments[currentDuelRoomId] }

    /// The room to queue into: the lowest-numbered public room of that kind still waiting for
    /// players; when none is, one past the highest room this phone knows. Every phone with the
    /// same recent history lands on the same number - and it does not need the history back to
    /// room 1 (see the engine's join rule).
    private func currentRoomNumber(numberOf: (String) -> Int?) -> Int {
        var open: Int?
        var highest = 0
        for room in tournaments.values {
            guard let number = numberOf(room.id) else { continue }
            highest = max(highest, number)
            if room.status == .open, !room.isFull { open = min(open ?? number, number) }
        }
        return open ?? highest + 1
    }

    /// True once the arena's history has come back from the indexer (or, without one, once the
    /// first rows arrived / a few seconds passed). A join before that would pick a room from an
    /// empty view - room 1 - which everyone else finished long ago.
    @Published private(set) var historyReady = false

    /// Bumped when a screen deep in the flow (the result screen's Done) wants the whole
    /// stack popped to the 1v1 / Tournaments screen; that screen watches it and clears its
    /// navigation state.
    @Published private(set) var popToLobbyRequest = 0
    func requestPopToLobby() { popToLobbyRequest += 1 }

    /// A player who advanced (or is watching while waiting) wants the bracket screen of this
    /// tournament: the kind's screen pops to itself and pushes the bracket, which opens the
    /// player's next game the moment it exists.
    struct BracketRequest: Equatable { let id: String; let serial: Int }
    @Published private(set) var openBracketRequest: BracketRequest?
    func requestOpenBracket(_ id: String) {
        openBracketRequest = BracketRequest(id: id, serial: (openBracketRequest?.serial ?? 0) + 1)
    }

    /// Private 1v1s this player is in, still open or in play.
    var myPrivateDuels: [ChessTournament] {
        guard let me = myAddress else { return [] }
        return tournaments.values
            .filter { !$0.isPublic && $0.isDuel && ($0.status == .open || $0.isInPlay(at: now)) && $0.players.contains(me) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Private tournaments this player is in, still open or in play.
    var myPrivateTournaments: [ChessTournament] {
        guard let me = myAddress else { return [] }
        return tournaments.values
            .filter { !$0.isPublic && !$0.isDuel && ($0.status == .open || $0.isInPlay(at: now)) && $0.players.contains(me) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var openTournaments: [ChessTournament] {
        tournaments.values.filter { $0.status == .open }.sorted { $0.createdAt > $1.createdAt }
    }
    /// Rooms with a game still being played. A live room whose clocks have all run out with
    /// no claim posted is not one of them (see `ChessTournamentGame.flaggedSide`).
    var liveTournaments: [ChessTournament] {
        tournaments.values.filter { $0.isInPlay(at: now) }.sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
    }
    /// Finished on the chain, or finished on the clock with the claim still to come.
    var finishedTournaments: [ChessTournament] {
        tournaments.values
            .filter { $0.status == .finished || ($0.status == .live && !$0.isInPlay(at: now)) }
            .sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
    }

    /// The tournament this player is in that is not over, if any. A waiting seat that has
    /// expired does not count: the player is free to join elsewhere.
    var myActiveTournament: ChessTournament? {
        guard let me = myAddress else { return nil }
        return tournaments.values
            .filter { $0.isStillPlaying(me, at: now) || ($0.status == .open && $0.isSeated(me, at: now)) }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    /// Too busy online for a challenge link to open a bot screen: the rooms are still loading
    /// (a game in play may not be known yet), the player is seated or playing, or a game of
    /// theirs was decided on the clock lately with the claim not on chain yet - its winner is
    /// still on the board to claim it.
    var isBusyOnline: Bool {
        guard historyReady else { return true }
        if myActiveTournament != nil { return true }
        guard let me = myAddress else { return false }
        return tournaments.values.contains { tournament in
            tournament.status == .live && tournament.games.values.contains { game in
                guard game.color(of: me) != nil, let flagAt = game.flagAt else { return false }
                return now - flagAt < Self.autoClaimWindowMs
            }
        }
    }

    // MARK: - Leaderboards

    private var localBoards: [ChessLeaderboardPeriod: [ChessLeaderboardRow]] = [:]
    private var indexerBoards: [ChessLeaderboardPeriod: (since: Int64, rows: [ChessLeaderboardRow])] = [:]
    private var boardsMonthStart: Int64 = 0
    private var lastIndexerLeaderboardFetch: Date?
    private var indexerLeaderboardTask: Task<Void, Never>?

    private func recomputeLocalBoards() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        boardsMonthStart = ChessTournamentEngine.utcMonthStartMs(nowMs)
        let all = Array(tournaments.values)
        for period in ChessLeaderboardPeriod.allCases {
            localBoards[period] = ChessTournamentEngine.leaderboard(
                from: all, since: ChessTournamentEngine.periodSinceMs(period, nowMs: nowMs))
        }
        publishBoards()
    }

    /// Per player, each figure is the larger of the two sources: both count the same window,
    /// the indexer has the older history and this phone the newest blocks, so neither can be
    /// above the true count. An indexer board for another window (an old indexer without
    /// `period`, or a month that has since rolled over) is not used.
    private func publishBoards() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        func merged(_ period: ChessLeaderboardPeriod) -> [ChessLeaderboardRow] {
            let local = localBoards[period] ?? []
            guard let remote = indexerBoards[period],
                  remote.since == ChessTournamentEngine.periodSinceMs(period, nowMs: nowMs) else { return local }
            var rows = Dictionary(remote.rows.map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
            for r in local {
                guard var m = rows[r.address] else { rows[r.address] = r; continue }
                m.wins = max(m.wins, r.wins)
                m.losses = max(m.losses, r.losses)
                m.duelWins = max(m.duelWins, r.duelWins)
                m.duelLosses = max(m.duelLosses, r.duelLosses)
                m.tournamentGameWins = max(m.tournamentGameWins, r.tournamentGameWins)
                m.tournamentGameLosses = max(m.tournamentGameLosses, r.tournamentGameLosses)
                m.tournamentsPlayed = max(m.tournamentsPlayed, r.tournamentsPlayed)
                m.tournamentsWon = max(m.tournamentsWon, r.tournamentsWon)
                m.tournamentsLost = max(m.tournamentsLost, r.tournamentsLost)
                m.lastPlayedAt = max(m.lastPlayedAt, r.lastPlayedAt)
                rows[r.address] = m
            }
            return rows.values.sorted {
                if $0.wins != $1.wins { return $0.wins > $1.wins }
                if $0.losses != $1.losses { return $0.losses < $1.losses }
                return $0.lastPlayedAt > $1.lastPlayedAt
            }
        }
        let all = merged(.allTime)
        let month = merged(.month)
        if all != leaderboard { leaderboard = all }
        if month != monthlyLeaderboard { monthlyLeaderboard = month }
    }

    private struct IndexerLeaderboardResponse: Decodable {
        struct Player: Decodable {
            let address: String
            let wins, losses, duelWins, duelLosses: Int
            let tournamentGameWins, tournamentGameLosses: Int
            let tournamentsPlayed, tournamentsWon, tournamentsLost: Int
            let lastPlayedAt: Int64
        }
        let players: [Player]
        let period: String?
        let since: Int64?
    }

    /// GET /chess/leaderboard?period=month|all on the arena's indexer (ONLINE_CHESS.md §6).
    /// At most every 20 s unless forced; any failure leaves the phone's own boards in place.
    func refreshIndexerLeaderboards(force: Bool = false) {
        if !force, let last = lastIndexerLeaderboardFetch, Date().timeIntervalSince(last) < 20 { return }
        var base = PublicChatService.indexerBaseURL(forChannel: ChessTournamentCodec.arenaChannel)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty else { return }
        lastIndexerLeaderboardFetch = Date()
        indexerLeaderboardTask?.cancel()
        indexerLeaderboardTask = Task { [weak self] in
            for period in ChessLeaderboardPeriod.allCases {
                guard var components = URLComponents(string: "\(base)/chess/leaderboard") else { return }
                components.queryItems = [
                    URLQueryItem(name: "period", value: period.rawValue),
                    URLQueryItem(name: "limit", value: "1000")
                ]
                guard let url = components.url else { return }
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let decoded = try? JSONDecoder().decode(IndexerLeaderboardResponse.self, from: data),
                      decoded.period == period.rawValue, let since = decoded.since else { continue }
                let rows = decoded.players.map {
                    ChessLeaderboardRow(
                        address: $0.address, wins: $0.wins, losses: $0.losses,
                        duelWins: $0.duelWins, duelLosses: $0.duelLosses,
                        tournamentGameWins: $0.tournamentGameWins, tournamentGameLosses: $0.tournamentGameLosses,
                        tournamentsPlayed: $0.tournamentsPlayed, tournamentsWon: $0.tournamentsWon,
                        tournamentsLost: $0.tournamentsLost, lastPlayedAt: $0.lastPlayedAt)
                }
                guard !Task.isCancelled, let self else { return }
                self.indexerBoards[period] = (since, rows)
                self.publishBoards()
                self.resolveNames(for: Set(rows.prefix(100).map(\.address)))
            }
        }
    }

    // MARK: - Names

    /// Addresses whose KNS profile was asked for this session.
    private var resolvedNames: Set<String> = []

    /// Names in the arena follow the app's rule - contact name, then KNS domain, then the
    /// shortened address (`ContactsManager.displayName`) - and the domain part needs the
    /// profile in `KNSService.profileCache`. Fetched once per address per session; the cache
    /// answers after that, and `KNSService` publishes so rows re-render when it lands.
    func resolveNames(for addresses: Set<String>) {
        let fresh = addresses.subtracting(resolvedNames)
        guard !fresh.isEmpty else { return }
        resolvedNames.formUnion(fresh)
        let network = AppSettings.load().networkType
        for address in fresh {
            Task { _ = await KNSService.shared.fetchProfile(for: address, network: network) }
        }
    }

    // MARK: - Fees

    /// What sending `message` costs right now, as "0.0017 KAS", for a button label. An arena
    /// message is a fixed-size payload, so this is the same estimate the composer shows while
    /// typing, without a network round trip (one input, like every arena send).
    func feeText(for message: ChessTournamentMessage) -> String? {
        guard let wallet = WalletManager.shared.currentWallet,
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else { return nil }
        let payload = KasiaTransactionBuilder.buildPublicChatPayload(
            channel: ChessTournamentCodec.arenaChannel,
            content: ChessTournamentCodec.encode(message)
        )
        let sompi = KasiaTransactionBuilder.estimatePublicChatFee(payload: payload, inputCount: 1, senderScriptPubKey: senderScriptPubKey)
        // Four decimals: "0.0017 KAS" reads at a glance; the exact sompi is in the transaction.
        return String(format: "%.4f %@", Double(sompi) / 100_000_000, KaspaUnit.symbol)
    }

    /// The join button's label: "Join (Fee: 0.0017 KAS)".
    func joinLabel(roomId: String) -> String {
        guard let fee = feeText(for: ChessTournamentCodec.join(id: roomId)) else { return "Join" }
        return "Join (Fee: \(fee))"
    }

    // MARK: - Actions (each one a public chat transaction)

    /// Joins the public room taking players now. If that room fills before this join lands
    /// (someone else got the last seat), `reduce` notices and joins the next room.
    func joinPublicQueue() async {
        await joinPublicRoom(duel: false)
    }

    /// The seat that ran out is still in `players` until the next join drops it (the engine
    /// judges that at the join's block time) - so "already in" means seated NOW, never the
    /// stale list, or a returning player's tap would do nothing at all.
    private func joinPublicRoom(duel: Bool) async {
        guard let me = myAddress else { return }
        guard historyReady else { lastError = "Still loading the rooms - try again in a moment."; return }
        // The freshest shared view first: whatever the indexer holds this second is what every
        // other phone is choosing from. Only then pick the room. The subscription delivers the
        // merge on the next run-loop turn, so reduce the rows here and now instead of reading
        // a room number off the old state.
        await PublicChatService.shared.refreshFromIndexerNow(channel: ChessTournamentCodec.arenaChannel)
        await reduceArena()
        // The account may have changed while the rooms loaded.
        guard myAddress == me else { return }
        let id = duel ? currentDuelRoomId : currentPublicRoomId
        if let busy = myActiveTournament {
            lastError = busy.status == .open ? "You're already waiting in \(busy.name)." : "You're still playing in \(busy.name)."
            return
        }
        if let room = tournaments[id], room.isSeated(me, at: now) {
            lastError = "You're already in this room."
            return
        }
        queuedPublicRoomId = id
        // A join that did not go out queues nothing: the next room must not be joined for it -
        // unless the queue has already moved on to another room while it was being sent.
        if !(await send(ChessTournamentCodec.join(id: id))), queuedPublicRoomId == id { queuedPublicRoomId = nil }
    }

    /// The room this player asked to join and is waiting to appear in.
    private var queuedPublicRoomId: String?

    /// Joins the public 1v1 room taking players now; same race handling as the tournaments.
    func joinPublicDuelQueue() async {
        await joinPublicRoom(duel: true)
    }

    /// A private 1v1 for a friend: no creator code, an eight-character code to share.
    func createPrivateDuel() async -> String? {
        let id = ChessTournamentCodec.newPrivateId()
        guard await send(ChessTournamentCodec.createDuel(id: id, name: ChessTournamentCodec.privateDuelName)) else { return nil }
        return id
    }

    /// A private tournament for friends. Needs the creator code; returns nil (with a message)
    /// when it is wrong, without sending anything.
    func createPrivateTournament(code: String) async -> String? {
        guard ChessTournamentCodec.isValidCreateKey(ChessTournamentCodec.createKey(code: code, id: "check"), id: "check") else {
            lastError = "That creator code is not right."
            return nil
        }
        let id = ChessTournamentCodec.newPrivateId()
        guard await send(ChessTournamentCodec.create(id: id, name: ChessTournamentCodec.privateTournamentName, code: code)) else { return nil }
        return id
    }

    /// Joins a friend's private tournament by its code (the tournament id).
    func joinPrivate(code raw: String) async -> Bool {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let tournament = tournaments[id], !tournament.isPublic else {
            lastError = "No open tournament with that code. Codes are eight characters; the tournament must exist and still have seats."
            return false
        }
        guard tournament.status == .open else { lastError = "That tournament has already started."; return false }
        return await join(tournament)
    }

    /// True when the player is seated or the join went out; false (with `lastError`) when
    /// nothing was sent.
    @discardableResult
    func join(_ tournament: ChessTournament) async -> Bool {
        guard let me = myAddress, tournament.status == .open else { return false }
        if tournament.isSeated(me, at: now) { return true }
        if let busy = myActiveTournament, busy.id != tournament.id {
            lastError = busy.status == .open ? "You're already waiting in \(busy.name)." : "You're still playing in \(busy.name)."
            return false
        }
        return await send(ChessTournamentCodec.join(id: tournament.id))
    }

    /// Gives the seat back while the room is still waiting (one transaction). True when the
    /// leave went out (or there was no seat to give back).
    @discardableResult
    func leave(_ tournament: ChessTournament) async -> Bool {
        guard let me = myAddress, tournament.status == .open, tournament.isSeated(me, at: now) else { return true }
        queuedPublicRoomId = nil
        return await send(ChessTournamentCodec.leave(id: tournament.id))
    }

    func cancel(_ tournament: ChessTournament) async {
        guard tournament.creator == myAddress, tournament.status == .open else { return }
        _ = await send(ChessTournamentCodec.cancel(id: tournament.id))
    }

    /// Plays a move if it is ours to make and legal; the board shows it as pending until the
    /// chain returns it.
    func play(_ move: ChessMove, in tournament: ChessTournament, game: ChessTournamentGame) async {
        // Not once the clock has decided it: a move after the flag is void on chain.
        guard let me = myAddress, game.playerToMove == me, !game.isDecided(at: now),
              !pendingMoveGames.contains("\(tournament.id)|\(game.id)"),
              ChessEngine.isLegal(move, in: game.board) else { return }
        let normalized = ChessEngine.normalizingPromotion(move, in: game.board)
        let key = "\(tournament.id)|\(game.id)"
        pendingMoveGames.insert(key)
        let sent = await send(ChessTournamentCodec.move(
            id: tournament.id, game: game.id, ply: game.moves.count + 1,
            from: normalized.from.algebraic, to: normalized.to.algebraic,
            promotion: normalized.promotion?.promotionLetter
        ))
        guard myAddress == me else { return }
        if sent {
            // Timed from the moment it went out, if the chain has not shown it already.
            if pendingMoveGames.contains(key) { pendingMoveSentAt[key] = Int64(Date().timeIntervalSince1970 * 1000) }
        } else {
            pendingMoveGames.remove(key)
            pendingMoveSentAt[key] = nil
        }
    }

    /// True when the resignation went out; false (with `lastError`) when it did not, and the
    /// game goes on - the board must keep the player.
    @discardableResult
    func resign(_ tournament: ChessTournament, game: ChessTournamentGame) async -> Bool {
        guard let me = myAddress, game.color(of: me) != nil, !game.isOver else { return false }
        return await send(ChessTournamentCodec.resign(id: tournament.id, game: game.id))
    }

    /// The opponent flagged in one of our games, lately: post the claim. Runs on every tick;
    /// a claim that has not taken after `claimRetryMs` (voided, or not sent) goes again.
    private func claimTimeoutsIfDue() {
        guard let me = myAddress else { return }
        let localStamps = PublicChatService.shared.locallyStampedTxIds
        for tournament in tournaments.values where tournament.status == .live {
            for game in tournament.games.values where !game.isOver {
                guard let mine = game.color(of: me), game.sideToMove != mine, let flagAt = game.flagAt else { continue }
                // A second's margin past zero, so the claim's block time is safely after; and
                // only a recent flag - an old abandoned game is left to the board's Claim.
                guard now - 1_500 >= flagAt, now - flagAt < Self.autoClaimWindowMs else { continue }
                // Our own last move still carries this phone's clock: the opponent's clock
                // started at an instant the chain has not confirmed yet - wait for it.
                if let last = game.moves.last, localStamps.contains(last.txId) { continue }
                postClaim(tournament, game: game)
            }
        }
    }

    /// The board's Claim, for a game the opponent has lost on time with no claim on chain yet -
    /// the way off the board for its winner that is not Resign.
    /// Repeated taps are one claim: nothing while one is being sent or within a few seconds of
    /// the last.
    func claimWin(_ tournament: ChessTournament, game: ChessTournamentGame) {
        guard let me = myAddress, game.decidedWinner(at: now) == me, !game.isOver else { return }
        let key = "\(tournament.id)|\(game.id)"
        if let at = claimedGames[key], now - at < Self.claimTapGapMs { return }
        postClaim(tournament, game: game, force: true)
    }

    private func postClaim(_ tournament: ChessTournament, game: ChessTournamentGame, force: Bool = false) {
        let key = "\(tournament.id)|\(game.id)"
        guard !claimsInFlight.contains(key) else { return }
        if !force, let at = claimedGames[key], now - at < Self.claimRetryMs { return }
        claimedGames[key] = now
        claimsInFlight.insert(key)
        Task {
            _ = await self.send(ChessTournamentCodec.claim(id: tournament.id, game: game.id))
            self.claimsInFlight.remove(key)
        }
    }

    func isClaiming(_ tournament: ChessTournament, game: ChessTournamentGame) -> Bool {
        claimsInFlight.contains("\(tournament.id)|\(game.id)")
    }

    /// One public chat transaction, with the retries a fast sequence of sends needs: the change
    /// of the previous transaction is not spendable until it is mined, so a move sent within a
    /// second of the last one can hit "no spendable UTXO" - the same retry KaPosts threads use.
    /// Only that kind of error is retried (`PublicChatService.isRetryableSendError`): no KAS on
    /// the chatting address, or a send whose outcome is unknown, fails at once with its message.
    /// Never deferred to a background retry: true means the transaction went out.
    private func send(_ message: ChessTournamentMessage) async -> Bool {
        let content = ChessTournamentCodec.encode(message)
        let sender = myAddress
        var attempt = 0
        while true {
            do {
                try await PublicChatService.shared.sendPublicChat(
                    channel: ChessTournamentCodec.arenaChannel, content: content, deferNoInputRetry: false
                )
                lastError = nil
                return true
            } catch {
                attempt += 1
                // A switched account: nothing more goes out for the old one.
                guard myAddress == sender else { return false }
                if attempt > 5 || !PublicChatService.isRetryableSendError(error) {
                    lastError = PublicChatService.friendlySendErrorMessage(for: error)
                    AppLog.log("[Chess] Send failed: %@", error.localizedDescription)
                    return false
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}
