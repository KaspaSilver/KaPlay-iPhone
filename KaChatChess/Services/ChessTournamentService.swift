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
    /// The automatic claims of one flag. A claim that keeps not taking is going against a board
    /// that's wrong, so each retry first pages the arena again, and after a few the app stops
    /// paying for them: the board's Claim win is still there.
    private struct AutoClaim {
        let flagAt: Int64
        var tries = 0
        var repaged = false
    }
    private var autoClaims: [String: AutoClaim] = [:]
    private static let maxAutoClaims = 4
    /// One of this player's games has a later move than the board reached: at most this often
    /// the arena is paged back to the game's start.
    private static let gapRepageGapMs: Int64 = 30_000
    private var lastGapRepageAt: Int64 = 0
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
    /// True while the chess server (the arena's indexer) isn't answering: what's on screen is
    /// what this phone has, plus what the block stream brings.
    @Published private(set) var arenaServerDown = false
    /// While the indexer is down, when each of this player's games last had all its players read
    /// from the REST API (wall ms).
    private var chainReadAt: [String: Int64] = [:]
    private var nextChainRead: Int64 = 0
    private static let chainReadIntervalMs: Int64 = 10_000
    /// The REST API shows a move a few seconds after it lands: a read this long past the flag
    /// has seen any move made before it.
    private static let chainFlagMarginMs: Int64 = 5_000
    private static let roomsUnconfirmedMessage = "The chess server is unreachable, so open rooms can't be confirmed. Try again when it's back."
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
        // Its current value too: this service can start after the indexer went down.
        PublicChatService.shared.$arenaIndexerDown
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] down in
                guard let self else { return }
                let wasDown = self.arenaServerDown
                self.arenaServerDown = down
                if wasDown, !down { self.refreshIndexerLeaderboards(force: true) }
            }
            .store(in: &cancellables)
    }

    private func accountChanged(to address: String?) {
        guard address != stateAddress else { return }
        stateAddress = address
        queuedPublicRoomId = nil
        pendingMoveGames = []
        pendingMoveSentAt = [:]
        claimedGames = [:]
        autoClaims = [:]
        autoRejoinsLeft = 0
        chainReadAt = [:]
        nextChainRead = 0
        lastGapRepageAt = 0
        lastError = nil
    }

    var myAddress: String? { WalletManager.shared.currentWallet?.publicAddress }

    // MARK: - Watching the arena

    /// A chess screen came on: keep the arena scanned and polled while any is up.
    func acquire() {
        refCount += 1
        guard refCount == 1 else { return }
        let publicChat = PublicChatService.shared
        publicChat.resyncArenaIndexerIfUnset()
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
                    || PublicChatService.shared.arenaIndexerDown
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
                PublicChatService.shared.resyncArenaIndexerIfUnset()
                // With the indexer down the room's own poll checks when it's back; this phone's
                // games are read by their players' addresses.
                if PublicChatService.shared.arenaIndexerDown {
                    await self.readMyGamesFromChainIfDue()
                    continue
                }
                // Only while it matters: a seat held, a game on, or a flag waiting to be
                // claimed. Idle in the lobby, the room's own poll is plenty.
                guard self.isBusyOnline else { continue }
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

    /// The indexer is down: this player's live games, and the ones just flagged, from the two
    /// players' addresses. It fills in what the block stream missed (a reconnect, the app in the
    /// background) and is what lets a timeout claim go out (`flagIsConfirmed`), which rests on
    /// the opponent's address alone: their moves are what could be missing.
    private func readMyGamesFromChainIfDue() async {
        guard let me = myAddress, now >= nextChainRead else { return }
        nextChainRead = now + Self.chainReadIntervalMs
        for tournament in tournaments.values where tournament.status == .live {
            for game in tournament.games.values {
                guard let mine = game.color(of: me), let flagAt = game.flagAt,
                      now - flagAt < Self.autoClaimWindowMs else { continue }
                let askedAt = Int64(Date().timeIntervalSince1970 * 1000)
                let answered = await PublicChatService.shared.readArenaFromChain(
                    tournamentId: tournament.id, players: [game.address(of: mine.opposite)], since: game.startedAt
                )
                _ = await PublicChatService.shared.readArenaFromChain(
                    tournamentId: tournament.id, players: [me], since: game.startedAt
                )
                if answered { chainReadAt["\(tournament.id)|\(game.id)"] = askedAt }
            }
        }
    }

    /// Whether the chain has been read since this flag: the moves on this phone can be behind
    /// (just relaunched, or the indexer down), and a clock judged from those says nothing.
    private func flagIsConfirmed(in tournament: ChessTournament, game: ChessTournamentGame, flagAt: Int64) -> Bool {
        guard !PublicChatService.indexerBaseURL(forChannel: ChessTournamentCodec.arenaChannel).isEmpty else { return true }
        if PublicChatService.shared.arenaIndexerAnsweredAt >= flagAt + 1_500 { return true }
        return (chainReadAt["\(tournament.id)|\(game.id)"] ?? 0) >= flagAt + Self.chainFlagMarginMs
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
            let me = myAddress
            let wallNow = Int64(Date().timeIntervalSince1970 * 1000)
            let result = await Task.detached(priority: .userInitiated) { () -> (tournaments: [String: ChessTournament], gapSince: Int64?) in
                let events: [ChessArenaEvent] = rows.compactMap { row in
                    guard row.deliveryStatus == .sent, !row.id.hasPrefix("pending_"),
                          let message = ChessTournamentCodec.decode(row.content) else { return nil }
                    return ChessArenaEvent(txId: row.id, sender: row.senderAddress, blockTime: row.blockTime, message: message)
                }
                let tournaments = ChessTournamentEngine.reduce(ChessTournamentService.orderingLocalStamps(events, localStamps: localStamps))
                let gapSince = me.flatMap { ChessTournamentService.earliestGap(events, in: tournaments, me: $0, now: wallNow) }
                return (tournaments, gapSince)
            }.value
            appliedReduce = target
            apply(result.tournaments)
            if let since = result.gapSince, wallNow - lastGapRepageAt >= Self.gapRepageGapMs {
                lastGapRepageAt = wallNow
                PublicChatService.shared.repageArena(since: since)
            }
        }
        reduceTask = nil
    }

    /// A game of `me`'s still undecided has a move from one of its players beyond the next ply:
    /// a row before it is missing on this phone. Returns the earliest such game's start.
    nonisolated private static func earliestGap(_ events: [ChessArenaEvent], in tournaments: [String: ChessTournament], me: String, now: Int64) -> Int64? {
        var since: Int64?
        for event in events where event.message.a == "move" {
            guard let gameId = event.message.g, let ply = event.message.n,
                  let game = tournaments[event.message.t]?.games[gameId],
                  game.color(of: me) != nil, game.color(of: event.sender) != nil,
                  ply > game.moves.count + 1, !game.isDecided(at: now) else { continue }
            since = min(since ?? game.startedAt, game.startedAt)
        }
        return since
    }

    private func apply(_ reduced: [String: ChessTournament]) {
        tournaments = reduced
        recomputeLocalBoards()
        resolveNames(for: Set(reduced.values.flatMap(\.players)))
        // Asked to join a public room that filled first: queue into the next one. Bounded per
        // tap (`autoRejoinsLeft`), so a join can never turn into spending nobody asked for.
        if let queued = queuedPublicRoomId, let me = myAddress, let room = reduced[queued],
           room.isFull, !room.players.contains(me) {
            queuedPublicRoomId = nil
            if autoRejoinsLeft > 0 {
                autoRejoinsLeft -= 1
                let wasDuel = ChessTournamentCodec.duelNumber(of: queued) != nil
                Task { await self.joinPublicRoom(duel: wasDuel, automaticAfter: queued) }
            } else {
                lastError = Self.roomFilledMessage
            }
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
        ChessTournamentCodec.publicId(currentRoomNumber(numberOf: ChessTournamentCodec.publicNumber(of:), idOf: ChessTournamentCodec.publicId))
    }
    var currentPublicRoom: ChessTournament? { tournaments[currentPublicRoomId] }

    /// The public 1v1 room taking players right now.
    var currentDuelRoomId: String {
        ChessTournamentCodec.duelId(currentRoomNumber(numberOf: ChessTournamentCodec.duelNumber(of:), idOf: ChessTournamentCodec.duelId))
    }
    var currentDuelRoom: ChessTournament? { tournaments[currentDuelRoomId] }

    /// The room to queue into: the lowest-numbered public room of that kind still waiting for
    /// players; when none is, one past the highest room this phone knows. Every phone with the
    /// same recent history lands on the same number - and it does not need the history back to
    /// room 1 (see the engine's join rule).
    ///
    /// Anyone can post a join naming any room, so this is the choice of a room to pick, never
    /// the reducer's view of what rooms exist: only a room's canonical id counts (`duel-01` is
    /// not room 1), nothing past `maxRoomNumber`, and of the runs of numbers near each other only
    /// the longest (the real queue), so a stray `duel-900000` can't move it.
    private func currentRoomNumber(numberOf: (String) -> Int?, idOf: (Int) -> String) -> Int {
        var rooms: [(number: Int, isOpen: Bool)] = []
        for room in tournaments.values {
            guard let number = numberOf(room.id), number <= Self.maxRoomNumber, idOf(number) == room.id else { continue }
            rooms.append((number, room.status == .open && !room.isFull))
        }
        rooms.sort { $0.number < $1.number }
        var best: ArraySlice<(number: Int, isOpen: Bool)> = []
        var start = 0
        for index in rooms.indices where index + 1 == rooms.count || rooms[index + 1].number - rooms[index].number > Self.maxRoomGap {
            let run = rooms[start...index]
            if run.count > best.count { best = run }
            start = index + 1
        }
        return best.first(where: { $0.isOpen })?.number ?? ((best.last?.number ?? 0) + 1)
    }

    private static let maxRoomNumber = 1_000_000_000
    private static let maxRoomGap = 1_000

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
            .filter { !$0.isPublic && $0.isDuel && ($0.status == .open || $0.isInPlay(at: now) || hasUnclaimedWin($0)) && $0.players.contains(me) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Private tournaments this player is in, still open or in play.
    var myPrivateTournaments: [ChessTournament] {
        guard let me = myAddress else { return [] }
        return tournaments.values
            .filter { !$0.isPublic && !$0.isDuel && ($0.status == .open || $0.isInPlay(at: now) || hasUnclaimedWin($0)) && $0.players.contains(me) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// A game here this player has won on the clock, with no claim on chain. Finished lists
    /// public games only, so this keeps a private one reachable, for its Claim win.
    func hasUnclaimedWin(_ tournament: ChessTournament) -> Bool {
        guard let me = myAddress, tournament.status == .live else { return false }
        return tournament.games.values.contains { !$0.isOver && $0.decidedWinner(at: now) == me }
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

    private var boardsGeneration = 0

    /// Off the main thread, like the replay it follows; the newest ask is the one that lands.
    private func recomputeLocalBoards() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        boardsMonthStart = ChessTournamentEngine.utcMonthStartMs(nowMs)
        boardsGeneration += 1
        let generation = boardsGeneration
        let all = Array(tournaments.values)
        Task { [weak self] in
            let boards = await Task.detached(priority: .userInitiated) { () -> [ChessLeaderboardPeriod: [ChessLeaderboardRow]] in
                var boards: [ChessLeaderboardPeriod: [ChessLeaderboardRow]] = [:]
                for period in ChessLeaderboardPeriod.allCases {
                    boards[period] = ChessTournamentEngine.leaderboard(
                        from: all, since: ChessTournamentEngine.periodSinceMs(period, nowMs: nowMs))
                }
                return boards
            }.value
            guard let self, self.boardsGeneration == generation else { return }
            self.localBoards = boards
            self.publishBoards()
        }
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
                if $0.lastPlayedAt != $1.lastPlayedAt { return $0.lastPlayedAt > $1.lastPlayedAt }
                return $0.address < $1.address
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
    /// `automaticAfter`: this is the app moving on from a room that filled first, not a tap.
    private func joinPublicRoom(duel: Bool, automaticAfter filledRoom: String? = nil) async {
        guard let me = myAddress else { return }
        guard historyReady else { lastError = "Still loading the rooms - try again in a moment."; return }
        if filledRoom == nil { autoRejoinsLeft = Self.maxAutoRejoins }
        // The freshest shared view first: whatever the indexer holds this second is what every
        // other phone is choosing from. Only then pick the room. The subscription delivers the
        // merge on the next run-loop turn, so reduce the rows here and now instead of reading
        // a room number off the old state.
        // Without that view the room number and its seats are only what this phone last saw:
        // nothing is sent. (No indexer configured at all: the block stream is all there is.)
        guard await arenaViewIsConfirmed() else {
            lastError = Self.roomsUnconfirmedMessage
            return
        }
        await reduceArena()
        // The account may have changed while the rooms loaded.
        guard myAddress == me else { return }
        let id = duel ? currentDuelRoomId : currentPublicRoomId
        // Never a join the reducer would ignore: it can't take a seat, and it costs a fee.
        guard id != filledRoom, tournaments[id].map({ $0.status == .open }) ?? true else {
            lastError = Self.roomFilledMessage
            return
        }
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
    /// How many more rooms the app may try by itself before the player taps Join again.
    private var autoRejoinsLeft = 0
    private static let maxAutoRejoins = 2
    private static let roomFilledMessage = "That room filled first. Tap Join to try the next one."

    /// Whether the rooms on this phone are the indexer's as of just now, with any history still
    /// owed paged in. One failed request isn't an outage: it's tried again, and an answer from
    /// the last few seconds stands.
    private func arenaViewIsConfirmed() async -> Bool {
        let chat = PublicChatService.shared
        let channel = ChessTournamentCodec.arenaChannel
        guard !PublicChatService.indexerBaseURL(forChannel: channel).isEmpty else { return true }
        var confirmed = await chat.refreshFromIndexerNow(channel: channel)
        if !confirmed, !chat.arenaIndexerDown {
            try? await Task.sleep(nanoseconds: 800_000_000)
            confirmed = await chat.refreshFromIndexerNow(channel: channel)
        }
        let wallNow = Int64(Date().timeIntervalSince1970 * 1000)
        guard confirmed || wallNow - chat.arenaIndexerAnsweredAt < Self.recentAnswerMs else { return false }
        // Past one poll interval: paging is done by the room's 8 s poll.
        let deadline = Date().addingTimeInterval(12)
        while !chat.arenaBackfillDone, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return chat.arenaBackfillDone
    }
    private static let recentAnswerMs: Int64 = 15_000

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
            lastError = arenaServerDown
                ? "The chess server is unreachable, so that code can't be looked up. Try again when it's back."
                : "No open tournament with that code. Codes are eight characters; the tournament must exist and still have seats."
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
        if tournament.isPublic, arenaServerDown {
            lastError = Self.roomsUnconfirmedMessage
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
                // Not off a board that may be behind the chain.
                guard flagIsConfirmed(in: tournament, game: game, flagAt: flagAt) else { continue }
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
        if arenaServerDown, !flagIsConfirmed(in: tournament, game: game, flagAt: game.flagAt ?? now) {
            lastError = "The chess server is unreachable and the network hasn't confirmed this yet. Try again in a moment."
            return
        }
        postClaim(tournament, game: game, force: true)
    }

    private func postClaim(_ tournament: ChessTournament, game: ChessTournamentGame, force: Bool = false) {
        let key = "\(tournament.id)|\(game.id)"
        guard !claimsInFlight.contains(key) else { return }
        if !force {
            if let at = claimedGames[key], now - at < Self.claimRetryMs { return }
            let flagAt = game.flagAt ?? 0
            var record = autoClaims[key].flatMap { $0.flagAt == flagAt ? $0 : nil } ?? AutoClaim(flagAt: flagAt)
            guard record.tries < Self.maxAutoClaims else { return }
            // A claim that didn't take: read the arena again before paying for another. The
            // next tick waits on `flagIsConfirmed` until that's done.
            if record.tries > 0, !record.repaged {
                record.repaged = true
                autoClaims[key] = record
                PublicChatService.shared.repageArena(since: game.startedAt)
                return
            }
            record.tries += 1
            record.repaged = false
            autoClaims[key] = record
        }
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
