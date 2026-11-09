import Foundation
import Combine
import UIKit
import UserNotifications

/// KaChat 2.0 Public Chat feature: public, unencrypted, many-to-many channels.
/// Swift analog of the Android client's `PublicChatRepository` + `PublicChatScanningService`
/// combined - join/leave channels, send public chats, and scan new blocks for messages in
/// channels that are currently "wanted" (always-listen or actively viewed).
@MainActor
final class PublicChatService: ObservableObject {
    static let shared = PublicChatService()

    /// Hardcoded curated channels shown in a "Popular" section, matching Android. These two are
    /// AUTO-JOINED for every account (see `ensureFeaturedChannelsJoined`).
    /// nonisolated: read from PublicChatStore's background prune (retention rule) as well as
    /// main-actor UI - immutable Sendable value, safe from anywhere.
    nonisolated static let featuredChannels = ["kaspa", "kachat-bugs"]

    /// Curated per-language rooms, listed behind the collapsible "Other Languages" row under
    /// Popular. Indexer-tracked exactly like the featured rooms (30-day retention, indexer
    /// history, no retention gear, remote-push eligible) but deliberately NOT auto-joined: a
    /// store row is created on first open or bell tap. Auto-joining eleven more rooms would
    /// multiply push registrations, block-scan subscriptions and cellular cost for every user,
    /// including the vast majority who want none of them.
    /// Ordered alphabetically by display name, Latin scripts first (see `languageDisplayName`).
    nonisolated static let languageChannels = [
        "kaspa-indonesia",
        "kaspa-czech",
        "kaspa-german",
        "kaspa-espanol",
        "kaspa-francais",
        "kaspa-portugues",
        "kaspa-romania",
        "kaspa-slovak",
        "kaspa-russian",
        "kaspa-chinese",
        "kaspa-japanese",
        "kaspa-korean",
        "kaspa-hebrew",
    ]

    /// The rooms the app ships as defaults (Popular + the language rooms): always in the list,
    /// switched off rather than left, "Popular" in Room Info. Only auto-join and the pinned
    /// Popular list use `featuredChannels` alone.
    nonisolated static let curatedChannels = featuredChannels + languageChannels

    /// Whether the indexer keeps this room's history: the curated rooms, and any other room the
    /// indexer tracks - one the operator adds on the indexer (it then keeps 30 days of it) needs
    /// no app update. EVERYTHING that follows from "the indexer serves this room's history" keys
    /// off this - 30-day retention, remote-push registration, the cellular block-stream skip,
    /// the push-covered local-banner skip, the "even when the app is closed" wording. See
    /// `IndexerTrackedRooms` for how the app learns the extra rooms.
    nonisolated static func isIndexerTracked(_ channel: String) -> Bool {
        let name = PublicChatChannelName.normalize(channel)
        return curatedChannels.contains(name) || IndexerTrackedRooms.contains(name)
    }

    /// Every room `isIndexerTracked` says yes to, as far as this phone knows.
    nonisolated static var indexerTrackedChannels: Set<String> {
        Set(curatedChannels).union(IndexerTrackedRooms.all())
    }

    /// Rooms the app uses as machinery, never shown as chats: the chess arena
    /// (ONLINE_CHESS.md). Hidden from Public Chats, no unread, no banners.
    nonisolated static let serviceChannels: Set<String> = [ChessTournamentCodec.arenaChannel]

    @Published private(set) var channels: [PublicChatChannel] = []
    @Published private(set) var messagesByChannel: [String: [PublicChatMessage]] = [:]
    /// This wallet's public chat reactions, keyed by channel then by targetTxId - mirrors
    /// `GroupChatService.reactionsByGroupId`'s shape (and reuses `ReactionSnapshot`,
    /// see `PublicChatStore.fetchReactions`). Loaded per channel on open (`acquire`) and kept
    /// live afterward by `sendPublicChatReaction` / the incoming-reaction interception in
    /// `processPublicChatHits` and `fetchFromIndexerAndMerge`.
    @Published private(set) var reactionsByChannel: [String: [String: [ReactionSnapshot]]] = [:]
    /// The newest edit per message txId, per room - see `MessageEditCodec`.
    @Published private(set) var editsByChannel: [String: [String: MessageEditSnapshot]] = [:]
    /// The room message whose text the composer is editing (the user's own) - see `sendPublicChatEdit`.
    @Published var editingMessage: PublicChatMessage?
    @Published var lastSendError: KasiaError?
    @Published var replyingTo: PublicChatMessage?
    /// Rows of the service channels (the chess arena) this phone sent whose block time is still
    /// this phone's own clock: the chain's time has not reached us yet. The arena's reducer
    /// orders these by the moves around them, never by the local stamp (see
    /// `ChessTournamentService.reduce`).
    var locallyStampedTxIds: Set<String> { Set(localStampSentAt.keys) }
    /// The same rows, by when this phone started waiting for them (wall ms). Kept across
    /// launches, so a row the network dropped before a relaunch is still found out
    /// (`checkUnconfirmedServiceRows`); a relaunch restarts the wait, as the chain's answer may
    /// have come while the app was closed. Per account, like the store the rows live in: filled
    /// by `setCurrentWallet`.
    private var localStampSentAt: [String: Int64] = [:] {
        didSet { Self.saveLocalStamps(localStampSentAt, wallet: walletAddress) }
    }
    private var isCheckingLocalStamps = false
    /// Set when a public chat-room notification is tapped, so the chat list can navigate to that
    /// room - mirrors `ChatService.pendingChatNavigation`'s cold-start handling.
    @Published var pendingPublicChatNavigation: String?

    /// Shows a "Popular" tab of curated channels in the list screen. Default matches Android.
    private let store = PublicChatStore.shared

    /// Reference count of open channel screens ("live viewing"), keyed by normalized name.
    private var liveViewRefCounts: [String: Int] = [:]
    private var blockNotificationHandlerId: UUID?
    private var isScanningActive = false
    /// pendingId of public chats with an auto-retry already scheduled - prevents scheduling a
    /// duplicate retry if `sendPublicChatInternal` fails again before the first retry fires.
    private var scheduledSendRetries: Set<String> = []

    /// Fast pre-filter for the public chat payload prefix, applied to the still-hex-encoded
    /// `Protowire_RpcTransaction.payload` before paying the cost of hex-decoding it - avoids
    /// decoding every transaction in every new block just to reject non-public chat ones.
    private nonisolated static func hexOf(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }
    private nonisolated static let bcastPrefixHex: String = hexOf("kchat:1:bcast:")        // write + read
    private nonisolated static let legacyBcastPrefixHex: String = hexOf("ciph_msg:1:bcast:") // read-only

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // On expensive (cellular/metered) paths, indexer-covered rooms stop block-streaming
        // (see scanWantedChannels) - re-evaluate whenever the path flips either way.
        NetworkEpochMonitor.shared.expensivePathPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateScanningStateIfNeeded()
            }
            .store(in: &cancellables)
        // The closed-room sweep runs only while the app is on screen (see sweepClosedRooms).
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.startForegroundSweep()
                self?.refreshIndexerTrackedRooms()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.stopForegroundSweep() }
            .store(in: &cancellables)
        // A room the indexer turned out to track (or stopped tracking): its push registration,
        // cellular scanning and wording follow at once.
        NotificationCenter.default.publisher(for: IndexerTrackedRooms.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                self.updateScanningStateIfNeeded()
            }
            .store(in: &cancellables)
        // Before stamps were kept per account.
        UserDefaults.standard.removeObject(forKey: Self.localStampsKey)
    }

    /// True while the chess arena's indexer has stopped answering. The arena then lives on the
    /// block stream, with the REST API filling in the player's own games
    /// (`ChessTournamentService.readMyGamesFromChainIfDue`).
    @Published private(set) var arenaIndexerDown = false
    /// When the newest indexer answer for the arena was asked for (wall ms): rows up to then are
    /// in the store, so it only counts once any paging-in that was due has finished. A timeout
    /// claim waits for one newer than the flag.
    private(set) var arenaIndexerAnsweredAt: Int64 = 0

    private func noteArenaAnswered(channel: String, askedAt: Int64) {
        guard channel == ChessTournamentCodec.arenaChannel, deepBackfilledChannels.contains(channel) else { return }
        arenaIndexerAnsweredAt = max(arenaIndexerAnsweredAt, askedAt)
    }

    /// The arena's history is paged in, as far as this session owes it.
    var arenaBackfillDone: Bool { deepBackfilledChannels.contains(ChessTournamentCodec.arenaChannel) }

    /// The latest word on the arena's indexer, after every read: state, not transitions, so a
    /// missed or reordered change can't leave it stuck either way.
    func arenaHealthObserved(down: Bool) {
        guard down != arenaIndexerDown else { return }
        AppLog.log("[PublicChat] Arena indexer %@", down ? "isn't answering: reading from the block stream and the Kaspa REST API" : "is answering again")
        arenaIndexerAvailabilityChanged(down: down)
        NotificationCenter.default.post(name: .indexerAvailabilityChanged, object: nil, userInfo: ["down": down])
    }

    /// The indexer's address was cleared while it was down: nothing would ever report it back.
    func resyncArenaIndexerIfUnset() {
        guard arenaIndexerDown, Self.indexerBaseURL(forChannel: ChessTournamentCodec.arenaChannel).isEmpty else { return }
        Task { await PublicChatIndexerClient.arenaHealth.reset() }
        arenaHealthObserved(down: false)
    }

    /// Pages the arena back to `since` on the next poll: one of this player's games shows a
    /// move missing, or a claim didn't take. Until that's done no answer counts as fresh.
    func repageArena(since: Int64) {
        requestRepage(channel: ChessTournamentCodec.arenaChannel, since: since - Self.repageMarginMs)
    }

    /// Whether the REST API shows this transaction accepted (a bot stamp).
    func isTransactionAccepted(txId: String) async -> Bool {
        if case .accepted = await Self.lookUpTransaction(txId: txId) { return true }
        return false
    }

    private static func skipsIndexer(_ channel: String) async -> Bool {
        guard channel == ChessTournamentCodec.arenaChannel else { return false }
        return await PublicChatIndexerClient.arenaHealth.shouldSkipIndexer()
    }

    /// Down: on cellular the block stream comes back on (`scanWantedChannels`). Back: the arena is
    /// paged in again, since the steady poll's newest rows can't reach back over an outage, and
    /// the indexer's block times replace what the stream gave meanwhile.
    private func arenaIndexerAvailabilityChanged(down: Bool) {
        arenaIndexerDown = down
        if !down {
            deepBackfilledChannels.remove(ChessTournamentCodec.arenaChannel)
            deepBackfillResume[ChessTournamentCodec.arenaChannel] = nil
            backfillFloor[ChessTournamentCodec.arenaChannel] = nil
            arenaIndexerAnsweredAt = 0
        }
        updateScanningStateIfNeeded()
    }

    /// When the app-wide indexer was last asked which rooms it tracks.
    private var trackedRoomsCheckedAt: (base: String, at: Date)?

    /// Asks the app-wide public chat indexer which rooms it tracks (`/broadcast-channels`), at
    /// most once an hour per indexer - on app open and wallet switch. An indexer without the
    /// endpoint answers nothing and the set keeps what it learned from served rows.
    func refreshIndexerTrackedRooms() {
        let base = AppSettings.load().publicChatIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        if let last = trackedRoomsCheckedAt, last.base == base, Date().timeIntervalSince(last.at) < 3600 { return }
        trackedRoomsCheckedAt = (base, Date())
        Task {
            guard let channels = await PublicChatIndexerClient.fetchTrackedChannels(baseURL: base) else { return }
            IndexerTrackedRooms.setReported(channels)
        }
    }

    // MARK: - Wallet lifecycle

    /// Switch to a different wallet's public chat store. Call alongside
    /// `MessageStore.shared.setCurrentWallet` at every wallet-lifecycle transition.
    func setCurrentWallet(_ walletAddress: String?) {
        let normalized = walletAddress?.lowercased()
        let sameWallet = normalized == self.walletAddress
        // A room can already be on screen when the wallet lands: a cold launch from a room's
        // notification routes into it during loadWallet's awaits, before this ran. That room is
        // THIS wallet's and stays open, so its viewing state survives; only a real switch to
        // another wallet (whose screens are being torn down) resets it. Wiping it mid-view made
        // release() skip its mark-read (no refcount), and loadReadState() below replaced the
        // mark-read from acquire (which couldn't persist - the per-wallet key was still nil) -
        // so a room read straight from its notification stayed "unread", and the badge came
        // back on the next open.
        let tearingDownOtherWallet = self.walletAddress != nil && !sameWallet
        self.walletAddress = normalized
        if !sameWallet {
            messagesByChannel = [:]
            reactionsByChannel = [:]
            sweptChannels = []
            // Each wallet has its own store: what one applied says nothing about the other's.
            appliedIndexerRows = [:]
            // What was fetched and backfilled was the other wallet's store: this one's rooms
            // start from nothing.
            deepBackfilledChannels = []
            deepBackfillResume = [:]
            indexerFetchedChannels = []
            arenaIndexerAnsweredAt = 0
            indexerCoveredUntil = [:]
            backfillFloor = [:]
            localStampSentAt = normalized.map { Self.loadLocalStamps(wallet: $0) } ?? [:]
            localStampNextCheck = [:]
            droppedServiceRows = []
        }
        if tearingDownOtherWallet { liveViewRefCounts = [:] }
        loadReadState()
        // The store opens off the main thread now; the rooms are read once it says so.
        let targetWallet = normalized
        store.setCurrentWallet(walletAddress) { [weak self] in
            guard let self else { return }
            // The store calls back on the main thread (CoreDataStoreLoader); this is the
            // service's own actor, so no hop is needed.
            MainActor.assumeIsolated {
                guard self.walletAddress == targetWallet else { return }
                self.refreshChannels()
                // Rooms that were open before the wallet landed: their acquire read an empty
                // store and its mark-read was lost to loadReadState() - reload and mark read
                // now (persisted under the real key this time).
                for channel in self.liveViewRefCounts.keys {
                    self.loadMessages(for: channel)
                    self.markChannelRead(channel)
                }
                self.updateScanningStateIfNeeded()
                if UIApplication.shared.applicationState == .active { self.startForegroundSweep() }
                self.refreshIndexerTrackedRooms()
            }
        }
    }

    // MARK: - Foreground sweep of closed rooms

    /// The loop behind `sweepClosedRooms`, alive while the app is active.
    private var foregroundSweepTask: Task<Void, Never>?
    /// Rooms the sweep has asked about at least once this session: only rows found AFTER that
    /// first pass are news worth a banner - the first pass is history catching up.
    private var sweptChannels: Set<String> = []
    private static let foregroundSweepIntervalNanos: UInt64 = 20 * 1_000_000_000
    /// Rows older than this are not bannered even when new to the store - they are backlog,
    /// not a message that just arrived.
    private static let sweepBannerWindowMs: Int64 = 3 * 60 * 1000

    /// While the app is on screen, a room the user is NOT looking at used to be refreshed only
    /// by the live block scan - which misses blocks whenever the stream reconnects, and is off
    /// altogether for indexed rooms on cellular (`scanWantedChannels`) where the remote push
    /// that covers them is dropped in the foreground. So a message in #kaspa showed up only
    /// once the room was opened. This is the fix, the same shape as 1:1 chat's foreground
    /// contact sweep: every 20 s, each joined room with its bell on that is not open asks the
    /// indexer for its newest rows (one small request per room, sequential). The open room
    /// keeps its own 8 s poll; the block scan stays as the fast path.
    func startForegroundSweep() {
        guard foregroundSweepTask == nil else { return }
        foregroundSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if UIApplication.shared.applicationState == .active {
                    await self.sweepClosedRooms()
                }
                try? await Task.sleep(nanoseconds: Self.foregroundSweepIntervalNanos)
            }
        }
    }

    func stopForegroundSweep() {
        foregroundSweepTask?.cancel()
        foregroundSweepTask = nil
    }

    private func sweepClosedRooms() async {
        let targets = channels.filter {
            $0.notifyEnabled && !isViewing(channel: $0.channelName)
                && !Self.serviceChannels.contains($0.channelName)
                && !Self.indexerBaseURL(forChannel: $0.channelName).isEmpty
        }
        for channel in targets {
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
            await fetchNewestAndMerge(channel: channel.channelName)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// One small newest-page fetch for a closed room, merged like any other indexer page;
    /// rows that are new to the store and recent get the same in-app banner the scan gives.
    /// Asks the indexer for a room's newest rows right now and merges them - what the chess
    /// arena does just before a player picks a room, so the choice is made on the freshest
    /// shared view rather than whatever this phone happened to hold. Returns false when there
    /// is no indexer for the room or the request failed.
    @discardableResult
    func refreshFromIndexerNow(channel rawChannel: String) async -> Bool {
        let channel = PublicChatChannelName.normalize(rawChannel)
        guard !Self.indexerBaseURL(forChannel: channel).isEmpty else { return false }
        return await fetchNewestAndMerge(channel: channel)
    }

    @discardableResult
    private func fetchNewestAndMerge(channel: String) async -> Bool {
        let base = Self.indexerBaseURL(forChannel: channel)
        guard !base.isEmpty else { return false }
        if await Self.skipsIndexer(channel) { return false }
        let askedAt = Int64(Date().timeIntervalSince1970 * 1000)
        repageIfPollingLapsed(channel: channel, now: askedAt)
        do {
            let page = try await PublicChatIndexerClient.fetchHistoryPage(baseURL: base, channel: channel, limit: 40)
            defer { noteArenaAnswered(channel: channel, askedAt: askedAt) }
            // Guarded: inserting an element that is already there still publishes, which
            // re-rendered an open room on every sweep for nothing.
            if !indexerFetchedChannels.contains(channel) { indexerFetchedChannels.insert(channel) }
            let hidden = store.hiddenSenderAddresses(forChannel: channel)
            var editsChanged = false
            for row in page.messages where !hidden.contains(row.senderAddress) {
                guard let edit = MessageEditCodec.parse(row.content) else { continue }
                if applyIncomingEdit(edit, channel: channel, senderAddress: row.senderAddress, editTxId: row.txId, blockTime: row.blockTime) {
                    editsChanged = true
                }
            }
            if editsChanged { loadEdits(for: channel) }
            let rows = page.messages
                .filter { !hidden.contains($0.senderAddress) && MessageReactionCodec.parse($0.content) == nil && MessageEditCodec.parse($0.content) == nil }
                .map { (id: $0.txId, channel: channel, senderAddress: $0.senderAddress, content: $0.content, blockTime: $0.blockTime) }
            let known = await store.messageIds(forChannel: channel)
            let fresh = rows.filter { !known.contains($0.id) }
            let firstPass = !sweptChannels.contains(channel)
            sweptChannels.insert(channel)
            var changed = false
            if Self.serviceChannels.contains(channel) {
                // Our own arena rows take the chain's block time - see processPublicChatHits.
                for row in rows {
                    confirmLocalStamp(row.id)
                    if store.updateBlockTime(id: row.id, blockTime: row.blockTime) { changed = true }
                }
            }
            // Awaited, not a deferred reload: the arena picks a room right after this returns
            // (`ChessTournamentService.joinPublicRoom`) and must read the rows just merged.
            guard !fresh.isEmpty else {
                if changed { await reloadMessagesNow(for: channel) }
                return true
            }
            let inserted = await store.insertMessages(fresh)
            guard !inserted.isEmpty else {
                if changed { await reloadMessagesNow(for: channel) }
                return true
            }
            await store.pruneExpiredMessages()
            await reloadMessagesNow(for: channel)
            guard !firstPass else { return true }
            let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Self.sweepBannerWindowMs
            for row in fresh where row.blockTime > cutoff {
                notifyIfEnabled(channel: channel, senderAddress: row.senderAddress, content: row.content, txId: row.id)
            }
            return true
        } catch {
            // Best-effort; the next sweep tries again.
            AppLog.log("%@", "[PublicChat] Sweep fetch failed for #\(channel): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Read state (the Public Chats list's unread counts)

    private var walletAddress: String?
    /// Per room, the block time (ms) up to which the reader has seen it. Per wallet.
    @Published private(set) var lastReadByChannel: [String: Int64] = [:]
    /// Rooms marked unread by hand, which show a badge even with nothing new in them.
    @Published private(set) var manuallyUnreadChannels: Set<String> = []

    /// Default (curated) rooms switched off in Public Chats settings: gone from the list, never
    /// notifying, not counted. Per wallet.
    @Published private(set) var hiddenCuratedChannels: Set<String> = []
    private var hiddenCuratedKey: String? { walletAddress.map { "kachat_broadcast_hidden_curated_\($0)" } }

    /// The rooms the Public Chats list shows, in its order: the two Popular rooms on top, then
    /// every other joined room by latest activity. Service rooms and default rooms switched off
    /// in settings are left out. Shared by the list and by its Select All.
    var listedChannels: [PublicChatChannel] {
        let featured = Self.featuredChannels.compactMap { name in
            channels.first { $0.channelName == name }
        }
        .filter { isCuratedChannelShown($0.channelName) }
        func lastActivity(_ channel: PublicChatChannel) -> Int64 {
            messages(forChannel: channel.channelName).last?.blockTime
                ?? Int64((channel.joinedAt ?? .distantPast).timeIntervalSince1970 * 1000)
        }
        let others = channels
            .filter { !Self.featuredChannels.contains($0.channelName) }
            .filter { !Self.serviceChannels.contains($0.channelName) }
            // A default room switched off in Public Chats settings stays out of the list.
            .filter { isCuratedChannelShown($0.channelName) }
            .sorted { lastActivity($0) > lastActivity($1) }
        return featured + others
    }

    func isCuratedChannelShown(_ name: String) -> Bool {
        !hiddenCuratedChannels.contains(PublicChatChannelName.normalize(name))
    }

    private var lastReadKey: String? { walletAddress.map { "kachat_broadcast_last_read_\($0)" } }
    private var manualUnreadKey: String? { walletAddress.map { "kachat_broadcast_manual_unread_\($0)" } }

    private func loadReadState() {
        let defaults = UserDefaults.standard
        if let key = lastReadKey, let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) {
            lastReadByChannel = decoded
        } else {
            lastReadByChannel = [:]
        }
        manuallyUnreadChannels = Set(manualUnreadKey.flatMap { defaults.stringArray(forKey: $0) } ?? [])
        hiddenCuratedChannels = Set(hiddenCuratedKey.flatMap { defaults.stringArray(forKey: $0) } ?? [])
    }

    private func persistReadState() {
        let defaults = UserDefaults.standard
        if let key = lastReadKey, let data = try? JSONEncoder().encode(lastReadByChannel) {
            defaults.set(data, forKey: key)
        }
        if let key = manualUnreadKey {
            defaults.set(Array(manuallyUnreadChannels), forKey: key)
        }
    }

    /// Messages from other people newer than the read marker. A room seen for the first time
    /// counts from now, not from the start of its history.
    func unreadCount(forChannel name: String) -> Int {
        let channel = PublicChatChannelName.normalize(name)
        guard !isViewing(channel: channel), !hiddenCuratedChannels.contains(channel) else { return 0 }
        let manual = manuallyUnreadChannels.contains(channel) ? 1 : 0
        guard let marker = lastReadByChannel[channel] else { return manual }
        let mine = WalletManager.shared.currentWallet?.publicAddress
        let count = (messagesByChannel[channel] ?? []).reduce(0) { total, message in
            message.blockTime > marker && message.senderAddress != mine ? total + 1 : total
        }
        return max(count, manual)
    }

    var totalUnreadCount: Int {
        channels.filter { !Self.serviceChannels.contains($0.channelName) }
            .reduce(0) { $0 + unreadCount(forChannel: $1.channelName) }
    }

    func markChannelRead(_ name: String) {
        let channel = PublicChatChannelName.normalize(name)
        let newest = messagesByChannel[channel]?.last?.blockTime ?? 0
        lastReadByChannel[channel] = max(newest, Int64(Date().timeIntervalSince1970 * 1000))
        manuallyUnreadChannels.remove(channel)
        persistReadState()
    }

    /// #kaspa and #kachat-bugs notify by default. Applied once per wallet, so a bell the user
    /// later switches off stays off.
    // Rooms join with notifications OFF and stay off until the user turns a bell on - the
    // curated rooms included. (They used to be switched on once per wallet here.)

    // MARK: - Channel membership

    func refreshChannels() {
        channels = store.joinedChannels()
    }

    var featuredChannelsNotJoined: [String] {
        let joined = Set(channels.map { $0.channelName })
        return Self.featuredChannels.filter { !joined.contains($0) }
    }

    @discardableResult
    func joinChannel(_ rawName: String) -> Bool {
        guard store.joinChannel(rawName) else { return false }
        refreshChannels()
        return true
    }

    func leaveChannel(_ name: String) {
        // Curated rooms (Popular and the language rooms alike) can't be left - both are
        // permanent fixtures of the list screen, so no UI offers it; guard against stray paths.
        guard !Self.curatedChannels.contains(PublicChatChannelName.normalize(name)) else { return }
        let normalized = PublicChatChannelName.normalize(name)
        store.leaveChannel(normalized)
        messagesByChannel.removeValue(forKey: normalized)
        reactionsByChannel.removeValue(forKey: normalized)
        liveViewRefCounts.removeValue(forKey: normalized)
        refreshChannels()
        updateScanningStateIfNeeded()
    }

    func setNotifyEnabled(_ enabled: Bool, forChannel name: String) {
        // Indexed channels' bells also gate remote push - sync the registration so the push
        // service starts/stops sending for this channel.
        if Self.isIndexerTracked(name) {
        }
        store.setNotifyEnabled(enabled, forChannel: name)
        refreshChannels()
        updateScanningStateIfNeeded()
    }

    // MARK: - Hidden senders

    func hideSender(_ address: String, inChannel channel: String) {
        store.hideSender(address, inChannel: channel)
        syncHiddenSendersToPushIfNeeded(channel: channel)
        for channel in messagesByChannel.keys {
            loadMessages(for: channel)
        }
    }

    func unhideSender(_ address: String, inChannel channel: String) {
        store.unhideSender(address, inChannel: channel)
        syncHiddenSendersToPushIfNeeded(channel: channel)
        for channel in messagesByChannel.keys {
            loadMessages(for: channel)
        }
    }

    func hiddenSenderAddresses(forChannel channel: String) -> Set<String> {
        store.hiddenSenderAddresses(forChannel: channel)
    }

    // MARK: - Per-room indexer

    /// Channel -> indexer base URL, for rooms the user pointed somewhere other than the app's
    /// configured public chat indexer.
    ///
    /// A public chat is on-chain, so any indexer that watches the same network serves the same
    /// room - which means a room can be read through whichever one you trust or host, without
    /// changing the app-wide setting that every OTHER room uses. Empty here means "use the
    /// app-wide one", which is what the curated Popular rooms do (KaChat's own indexer).
    // nonisolated: `indexerBaseURL(forChannel:)` is nonisolated so callers off the main actor
    // can resolve a room's indexer, and a main-actor-isolated constant is not reachable from it.
    // Per network: a room pointed at a mainnet indexer must not keep reading it on testnet.
    // Mainnet keeps the original key.
    private nonisolated static var indexerOverridesKey: String {
        AppSettings.load().networkType == .mainnet
            ? "kachat_broadcast_indexer_overrides"
            : "kachat_broadcast_indexer_overrides.testnet"
    }

    private var indexerOverrides: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.indexerOverridesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.indexerOverridesKey) }
    }

    /// The indexer this room reads from: its own override, or the app-wide public chat indexer.
    nonisolated static func indexerBaseURL(forChannel channel: String) -> String {
        let overrides = UserDefaults.standard.dictionary(forKey: indexerOverridesKey) as? [String: String] ?? [:]
        let own = overrides[PublicChatChannelName.normalize(channel)]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let own, !own.isEmpty { return own }
        return AppSettings.load().publicChatIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hiddenSendersByChannel() -> (global: Set<String>, perChannel: [String: Set<String>]) {
        store.hiddenSendersByChannel()
    }

    /// Hides in the indexed channels also gate server-side push - re-sync the registration so
    /// the push service stops (or resumes) sending for that sender.
    private func syncHiddenSendersToPushIfNeeded(channel: String) {
        guard Self.isIndexerTracked(channel) else { return }
    }

    // MARK: - Live viewing (reference counted)

    /// Call when a public chat channel screen appears; pairs with `release`.
    func acquire(_ name: String) {
        let normalized = PublicChatChannelName.normalize(name)
        ChatService.clearDeliveredNotifications(threadIdentifier: "broadcast:\(normalized)")
        liveViewRefCounts[normalized, default: 0] += 1
        Task { await store.pruneExpiredMessages() }
        loadMessages(for: normalized)
        markChannelRead(normalized)
        loadReactions(for: normalized)
        loadEdits(for: normalized)
        updateScanningStateIfNeeded()
        startIndexerPollingIfConfigured(channel: normalized)
    }

    /// Per-channel indexer poll loops, running while that channel's screen is open.
    private var indexerPollTasks: [String: Task<Void, Never>] = [:]
    /// Channels whose FULL indexer history (up to the 30-day window) was already paged in this
    /// session — the deep backfill runs once per room per launch; the 8s poll then only needs
    /// the newest page to stay fresh.
    private var deepBackfilledChannels: Set<String> = []
    /// Channels the indexer has answered at least once this session - the chess arena waits
    /// for this before letting a player pick a room (`ChessTournamentService.historyReady`).
    @Published private(set) var indexerFetchedChannels: Set<String> = []

    /// Indexer rows already applied this session, per channel: reaction and edit txids that
    /// landed, and "txid@blockTime" for service-room block-time fixes. The steady-state poll
    /// re-serves the newest 30 rows every 8s, and each of those used to cost a synchronous
    /// Core Data fetch on the main actor again - reapplying is idempotent, so it only ever cost
    /// time. Not persisted: a fresh launch re-checks once, which is the safe direction.
    private var appliedIndexerRows: [String: Set<String>] = [:]
    private static let appliedIndexerRowsCap = 4_000

    private func wasApplied(_ key: String, channel: String) -> Bool {
        appliedIndexerRows[channel]?.contains(key) == true
    }

    private func markApplied(_ key: String, channel: String) {
        var set = appliedIndexerRows[channel] ?? []
        // Bounded by forgetting everything at the cap; the cost is one re-check per row.
        if set.count >= Self.appliedIndexerRowsCap { set.removeAll(keepingCapacity: true) }
        set.insert(key)
        appliedIndexerRows[channel] = set
    }
    /// Where an interrupted deep backfill picks up: the `before` cursor of the next page to
    /// ask for, and how many pages of the safety valve are left. Session-only, like the
    /// completed set above. Without this a single thrown page - one timeout on page 30 of a
    /// busy room - restarted the whole pager from page 1 on the next 8s tick, and kept doing
    /// so until every page happened to succeed in one go.
    private var deepBackfillResume: [String: (before: Int64, pagesLeft: Int)] = [:]
    private static let indexerPollIntervalNanos: UInt64 = 8 * 1_000_000_000
    /// When the newest answered poll of a room was asked for (wall ms). Anything older than this
    /// that a newest-rows poll can't reach (app in the background, room closed, polls failing)
    /// is paged in again (`repageIfPollingLapsed`).
    private var indexerCoveredUntil: [String: Int64] = [:]
    /// How far back a repeat of the backfill goes; none means the whole 30-day window.
    private var backfillFloor: [String: Int64] = [:]
    private static let pollLapseMs: Int64 = 20_000
    private static let repageMarginMs: Int64 = 60_000

    /// The polls stopped for a while: the rows since then may be past what the newest page holds.
    private func repageIfPollingLapsed(channel: String, now: Int64) {
        guard deepBackfilledChannels.contains(channel), let covered = indexerCoveredUntil[channel],
              now - covered > Self.pollLapseMs else { return }
        requestRepage(channel: channel, since: covered - Self.repageMarginMs)
    }

    /// The next poll pages the room back to `since`. A backfill already running to an older
    /// point, or the whole window, is left to go there.
    private func requestRepage(channel: String, since: Int64) {
        if deepBackfilledChannels.remove(channel) != nil {
            backfillFloor[channel] = since
            deepBackfillResume[channel] = nil
        } else if let floor = backfillFloor[channel] {
            backfillFloor[channel] = min(floor, since)
        }
        if channel == ChessTournamentCodec.arenaChannel { arenaIndexerAnsweredAt = 0 }
    }

    /// While a room is open, the KaChat public chat indexer is polled every few seconds and new
    /// rows merge into the local store (txid-deduped) - live block scanning alone proved
    /// unreliable for freshness (the indexer had messages the app never showed). First fetch
    /// fires immediately on open, so history backfill is included. No-op when the URL is unset;
    /// hidden senders and retention pruning apply exactly like scanned rows.
    private func startIndexerPollingIfConfigured(channel: String) {
        guard indexerPollTasks[channel] == nil else { return }
        let base = Self.indexerBaseURL(forChannel: channel)
        guard !base.isEmpty else { return }
        indexerPollTasks[channel] = Task { [weak self] in
            // Opening a chess screen asks at once whether the arena's indexer is back.
            if channel == ChessTournamentCodec.arenaChannel {
                await PublicChatIndexerClient.arenaHealth.allowProbeNow()
            }
            while !Task.isCancelled {
                // The room view stays mounted (and this loop alive) while the app is in the
                // background, but there is nobody to show a fresh row to - skip the network
                // work until the app is active again, the same gate the open-chat poll uses.
                if UIApplication.shared.applicationState == .active {
                    await self?.fetchFromIndexerAndMerge(baseURL: base, channel: channel)
                }
                try? await Task.sleep(nanoseconds: Self.indexerPollIntervalNanos)
            }
        }
    }

    private func stopIndexerPolling(channel: String) {
        indexerPollTasks[channel]?.cancel()
        indexerPollTasks[channel] = nil
    }

    private func fetchFromIndexerAndMerge(baseURL: String, channel: String) async {
        if await Self.skipsIndexer(channel) { return }
        let askedAt = Int64(Date().timeIntervalSince1970 * 1000)
        repageIfPollingLapsed(channel: channel, now: askedAt)
        do {
            // Steady-state polls only need the newest few rows (everything older is already in
            // the store, txid-deduped); re-fetching 200 rows every 8s was pure re-download. The
            // deep backfill below keeps the full 200-row pages. The indexer's `before`
            // parameter pages OLDER history, so it cannot act as a newest-side floor - the
            // small limit is the mechanism. Rows the newest page can't reach after a gap in the
            // polling are paged in again (`repageIfPollingLapsed`).
            let steadyStateLimit = deepBackfilledChannels.contains(channel) ? 30 : 200
            let messages = try await PublicChatIndexerClient.fetchHistoryPage(
                baseURL: baseURL, channel: channel, limit: steadyStateLimit
            )
            // Guarded: a no-op insert still publishes, re-rendering the open room every poll.
            if !indexerFetchedChannels.contains(channel) { indexerFetchedChannels.insert(channel) }
            // The newest page goes in FIRST, before any history is paged. It used to wait for
            // the whole 30-day backfill below - up to 50 sequential requests on a busy room - so
            // the message a notification had just announced showed up seconds after the room
            // opened, not with it.
            await mergeIndexerRows(messages.messages, channel: channel, prune: true)
            indexerCoveredUntil[channel] = askedAt
            // Deep backfill: page older history with `before` until the indexer runs out or we
            // reach its 30-day window, or the floor of a repeat after a gap. Without this, rooms
            // only ever showed the newest single page (200 rows) — busy rooms like
            // #kachat-bugs never loaded anywhere near the 30 days the indexer holds.
            if !deepBackfilledChannels.contains(channel) {
                let cutoff = max(
                    Int64(Date().timeIntervalSince1970 * 1000) - PublicChatStore.indexerRetentionMillis,
                    backfillFloor[channel] ?? 0
                )
                var hasMore: Bool
                var oldest: Int64?
                var pagesLeft: Int
                if let resume = deepBackfillResume[channel] {
                    // Picking up an interrupted pager: everything newer than this cursor is
                    // already in the store from the attempt that recorded it.
                    hasMore = true
                    oldest = resume.before
                    pagesLeft = resume.pagesLeft
                } else {
                    hasMore = messages.hasMore
                    oldest = messages.messages.map(\.blockTime).min()
                    pagesLeft = 50 // safety valve: 50 × 200 = 10k rows, far beyond any real room
                }
                var interrupted = false
                while hasMore, let before = oldest, before > cutoff, pagesLeft > 0 {
                    pagesLeft -= 1
                    let page: (messages: [PublicChatIndexerClient.IndexedPublicChat], hasMore: Bool)
                    do {
                        page = try await PublicChatIndexerClient.fetchHistoryPage(
                            baseURL: baseURL, channel: channel, before: before
                        )
                    } catch {
                        // Keep what this attempt did get: the pages already merged stay, and
                        // the cursor recorded after each of them is where the next 8s tick
                        // resumes - not page 1.
                        AppLog.log("%@", "[PublicChat] Deep backfill for #\(channel) paused at before=\(before): \(error.localizedDescription)")
                        interrupted = true
                        break
                    }
                    guard !page.messages.isEmpty else { break }
                    // Each page merged as it arrives, oldest last.
                    await mergeIndexerRows(page.messages, channel: channel, prune: false)
                    hasMore = page.hasMore
                    oldest = page.messages.map(\.blockTime).min()
                    if hasMore, let next = oldest {
                        deepBackfillResume[channel] = (before: next, pagesLeft: pagesLeft)
                    }
                }
                // Marked done only once the pager actually finishes; a paused one keeps its
                // resume cursor and the next poll continues from there.
                if !interrupted {
                    deepBackfilledChannels.insert(channel)
                    deepBackfillResume[channel] = nil
                    backfillFloor[channel] = nil
                }
            }
            noteArenaAnswered(channel: channel, askedAt: askedAt)
        } catch {
            // Best-effort on top of live scanning - the loop just tries again next tick.
            AppLog.log("%@", "[PublicChat] Indexer fetch failed for #\(channel): \(error.localizedDescription)")
        }
    }

    /// One page of indexer rows into the room: edits and reactions to their indexes, the
    /// rest into the store, the room reloaded when anything was new.
    private func mergeIndexerRows(_ page: [PublicChatIndexerClient.IndexedPublicChat], channel: String, prune: Bool) async {
        let hidden = store.hiddenSenderAddresses(forChannel: channel)
        let visible = page.filter { !hidden.contains($0.senderAddress) }

        // Reactions never become visible message rows - route them to the per-channel
        // reactions index instead (newest-blockTime-wins per (target, reactor), so
        // re-serving the same history every poll is idempotent - see
        // `PublicChatStore.applyIncomingReaction`).
        // Collected here, applied in one background pass with one save (see
        // `PublicChatStore.applyIncoming`) - this was a main-thread fetch and save per row.
        var incomingReactions: [PublicChatStore.IncomingReaction] = []
        var incomingEdits: [PublicChatStore.IncomingEdit] = []
        for row in visible {
            if let edit = MessageEditCodec.parse(row.content) {
                guard !wasApplied(row.txId, channel: channel) else { continue }
                incomingEdits.append(.init(
                    targetTxId: edit.targetTxId, senderAddress: row.senderAddress,
                    text: edit.text, editTxId: row.txId, blockTime: row.blockTime
                ))
                continue
            }
            guard let reaction = MessageReactionCodec.parse(row.content) else { continue }
            guard !wasApplied(row.txId, channel: channel) else { continue }
            incomingReactions.append(.init(
                targetTxId: reaction.targetTxId, reactorAddress: row.senderAddress,
                emoji: reaction.action == "remove" ? nil : reaction.emoji,
                reactionTxId: row.txId, blockTime: row.blockTime
            ))
        }
        if !incomingReactions.isEmpty || !incomingEdits.isEmpty {
            let storeReady = store.isReady
            let result = await store.applyIncoming(reactions: incomingReactions, edits: incomingEdits, channel: channel)
            // A reaction row is keyed by target and reactor, not by the target's presence, so
            // once the store has seen its tx (applied, or superseded) it never needs it again.
            if storeReady {
                for reaction in incomingReactions { markApplied(reaction.reactionTxId, channel: channel) }
            }
            // Edits only once they land: one met before its target message (history pages come
            // newest first) has to be tried again when the target arrives.
            for editTxId in result.appliedEditTxIds { markApplied(editTxId, channel: channel) }
            if result.reactionsChanged { loadReactions(for: channel) }
            if !result.appliedEditTxIds.isEmpty { loadEdits(for: channel) }
        }

        let rows = visible
            .filter { MessageReactionCodec.parse($0.content) == nil && MessageEditCodec.parse($0.content) == nil }
            .map { (id: $0.txId, channel: channel, senderAddress: $0.senderAddress, content: $0.content, blockTime: $0.blockTime) }
        var insertedCount = await store.insertMessages(rows).count
        if Self.serviceChannels.contains(channel) {
            // Rows this phone sent carry its own clock until the chain's time reaches us -
            // see processPublicChatHits.
            for row in rows {
                // Our own row can have taken this phone's clock again after the indexer's time
                // was applied (the send resolving late): that one is never "already applied".
                let onOwnClock = localStampSentAt[row.id] != nil || droppedServiceRows.remove(row.id) != nil
                confirmLocalStamp(row.id)
                let key = "\(row.id)@\(row.blockTime)"
                guard onOwnClock || !wasApplied(key, channel: channel) else { continue }
                if store.updateBlockTime(id: row.id, blockTime: row.blockTime) {
                    insertedCount += 1
                }
                if store.isReady { markApplied(key, channel: channel) }
            }
        }
        if insertedCount > 0 {
            if prune { await store.pruneExpiredMessages() }
            loadMessages(for: channel)
        }
    }


    /// True while this channel's room screen is open (the acquire/release refcount) - the
    /// notification policy's "currently open conversation": banners for a room the user is
    /// looking at are suppressed (here for scan-driven local banners, and in
    /// `AppDelegate.willPresent` for remote pushes), everything else fires even in-app.
    func isViewing(channel: String) -> Bool {
        liveViewRefCounts[PublicChatChannelName.normalize(channel)] != nil
    }

    /// Call when a public chat channel screen disappears; pairs with `acquire`.
    func release(_ name: String) {
        let normalized = PublicChatChannelName.normalize(name)
        guard let count = liveViewRefCounts[normalized] else { return }
        if count <= 1 {
            // Everything that arrived while the room was open has been seen.
            markChannelRead(normalized)
            liveViewRefCounts.removeValue(forKey: normalized)
            stopIndexerPolling(channel: normalized)
        } else {
            liveViewRefCounts[normalized] = count - 1
        }
        updateScanningStateIfNeeded()
    }

    private var wantedChannels: Set<String> {
        var wanted = Set(liveViewRefCounts.keys)
        // The bell is the one control: a room with notifications on is listened to while the app
        // is open (that is what lets it notify, and count unread), any room. The separate
        // "listen" switch is gone; a value stored by an older build is no longer read.
        for channel in channels where channel.notifyEnabled {
            wanted.insert(channel.channelName)
        }
        return wanted
    }

    // MARK: - Messages

    func messages(forChannel name: String) -> [PublicChatMessage] {
        messagesByChannel[PublicChatChannelName.normalize(name)] ?? []
    }

    /// Aggregated reactions for a channel, keyed by the reacted-to message's txId.
    func reactions(forChannel name: String) -> [String: [ReactionSnapshot]] {
        reactionsByChannel[PublicChatChannelName.normalize(name)] ?? [:]
    }

    func edits(forChannel name: String) -> [String: MessageEditSnapshot] {
        editsByChannel[PublicChatChannelName.normalize(name)] ?? [:]
    }

    /// Read on a background context. Opening a room called this and `loadReactions`
    /// synchronously on the main thread, whole channel each, while the room was sliding in.
    /// A generation per channel keeps an older read that finishes late from overwriting a newer
    /// one (a local edit reloads straight after its write).
    private func loadEdits(for channel: String) {
        editLoadGeneration[channel, default: 0] &+= 1
        let generation = editLoadGeneration[channel]
        Task { @MainActor [weak self] in
            guard let self else { return }
            let fresh = await self.store.fetchEditsAsync(forChannel: channel)
            guard self.editLoadGeneration[channel] == generation,
                  self.editsByChannel[channel] != fresh else { return }
            self.editsByChannel[channel] = fresh
        }
    }
    private var editLoadGeneration: [String: Int] = [:]
    private var reactionLoadGeneration: [String: Int] = [:]

    /// An edit envelope seen in a room (scan, indexer page or sweep): applied if its sender
    /// sent the message it names and that message is text. Returns whether anything changed.
    private func applyIncomingEdit(_ edit: MessageEditContent, channel: String, senderAddress: String, editTxId: String, blockTime: Int64) -> Bool {
        guard let target = store.sender(ofMessage: edit.targetTxId),
              target.senderAddress == senderAddress,
              MessageEditCodec.isEditable(target.content) else { return false }
        return store.upsertEdit(targetTxId: edit.targetTxId, channel: channel, text: edit.text, editTxId: editTxId, blockTime: blockTime, deliveryStatus: nil)
    }

    // MARK: - Edit

    func startEditing(_ message: PublicChatMessage) {
        replyingTo = nil
        editingMessage = message
    }

    func cancelEditing() {
        editingMessage = nil
    }

    /// Background read with a per-channel generation - see `loadEdits`.
    private func loadReactions(for channel: String) {
        reactionLoadGeneration[channel, default: 0] &+= 1
        let generation = reactionLoadGeneration[channel]
        Task { @MainActor [weak self] in
            guard let self else { return }
            let fresh = await self.store.fetchReactionsAsync(forChannel: channel)
            guard self.reactionLoadGeneration[channel] == generation,
                  self.reactionsByChannel[channel] != fresh else { return }
            self.reactionsByChannel[channel] = fresh
        }
    }

    /// How many of a room's newest messages are in memory. Enough to scroll through a busy
    /// day; "Load earlier messages" at the top of the room widens it. The chess arena has no
    /// window: its reducer replays the whole room.
    static let roomWindowSize = 400
    private var windowSizeByChannel: [String: Int] = [:]
    /// Rooms whose last read came back shorter than the window: nothing older to load.
    private var windowExhausted: Set<String> = []
    /// A read that finishes after a newer one began is dropped, not published.
    private var messageLoadGeneration: [String: Int] = [:]

    private func windowSize(for channel: String) -> Int? {
        Self.serviceChannels.contains(channel) ? nil : (windowSizeByChannel[channel] ?? Self.roomWindowSize)
    }

    /// Reads the room's window on a background context and publishes it if it changed. Not
    /// synchronous any more: the read used to be a main-thread `performAndWait` over the whole
    /// room, on every merge, prune and open.
    private func loadMessages(for channel: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reloadMessages(for: channel)
        }
    }

    /// Reloads until the reload that publishes is one started here: a newer reload already
    /// in flight would otherwise win and publish later, after the caller has read the rows.
    private func reloadMessagesNow(for channel: String) async {
        for _ in 0..<3 {
            if await reloadMessages(for: channel) { return }
        }
    }

    /// False when a newer reload of the channel took over before this one published.
    @discardableResult
    private func reloadMessages(for channel: String) async -> Bool {
        let generation = (messageLoadGeneration[channel] ?? 0) + 1
        messageLoadGeneration[channel] = generation
        let limit = windowSize(for: channel)
        let rows = await store.messages(forChannel: channel, newestLimit: limit)
        guard messageLoadGeneration[channel] == generation else { return false }
        if let limit {
            if rows.count < limit { windowExhausted.insert(channel) } else { windowExhausted.remove(channel) }
        }
        // Reaction envelopes are never rendered as message rows - drop any that made it into
        // the message table (rows scanned by an app version that predates reactions).
        // Off the main actor: up to 400 rows, each a codec sniff, on every reload - and a
        // room's first backfill reloads once per history page.
        let fresh = await Task.detached(priority: .userInitiated) {
            // and never two rows with one id: the room's list is keyed by it, and a duplicate
            // left a blank gap in it (the store also deletes duplicates on read)
            var seen = Set<String>()
            return rows.filter {
                seen.insert($0.id).inserted
                    && MessageReactionCodec.parse($0.content) == nil && MessageEditCodec.parse($0.content) == nil
            }
        }.value
        guard messageLoadGeneration[channel] == generation else { return false }
        // Only actually publish when the content changed: `@Published` fires on every
        // assignment regardless of equality, and an unconditional assignment re-rendered the
        // whole message list - including an open avatar menu - even when nothing had changed.
        guard messagesByChannel[channel] != fresh else { return true }
        messagesByChannel[channel] = fresh
        return true
    }

    // MARK: - Reply

    func startReplyTo(_ message: PublicChatMessage) {
        replyingTo = message
    }

    func cancelReply() {
        replyingTo = nil
    }

    // MARK: - Retry

    // MARK: - Reactions

    // MARK: - Fee estimation

    /// Estimate the on-chain fee for sending `content` as a public chat right now, matching how
    /// 1:1 chat shows a live "fee: N sompi" preview while typing (`ChatService.estimateMessageFee`).
    /// Accounts for an active reply, since replies wrap the content in a larger envelope.
    func estimatePublicChatFee(channel rawChannel: String, content: String, feeOverride: UInt64? = nil) async throws -> UInt64 {
        if let feeOverride { return feeOverride }
        let channel = PublicChatChannelName.normalize(rawChannel)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KasiaError.networkError("Message is empty")
        }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }

        let payloadText: String
        if let reply = replyingTo {
            let preview = MessageReplyCodec.previewText(for: reply.content)
            payloadText = MessageReplyCodec.encode(
                replyToId: reply.id,
                replyToSender: reply.senderAddress,
                replyToPreview: preview,
                text: trimmed
            )
        } else {
            payloadText = trimmed
        }

        let payload = KasiaTransactionBuilder.buildPublicChatPayload(channel: channel, content: payloadText)
        let utxos = try await ChatService.shared.fetchUtxosWithFallback(for: wallet.publicAddress)
        guard !utxos.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        return KasiaTransactionBuilder.estimatePublicChatFee(
            payload: payload,
            inputCount: 1,
            senderScriptPubKey: senderScriptPubKey
        )
    }

    /// Same estimate, but for a payload of a known byte size rather than real text - used for a
    /// live preview while a voice message is still being recorded (its final size isn't known
    /// yet), matching Android's `VoiceMessage.estimatedWirePayloadSize` heuristic.
    func estimatePublicChatFee(channel rawChannel: String, payloadByteCount: Int) -> UInt64? {
        guard let wallet = WalletManager.shared.currentWallet,
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            return nil
        }
        let dummyPayload = Data(count: max(0, payloadByteCount))
        return KasiaTransactionBuilder.estimatePublicChatFee(
            payload: dummyPayload,
            inputCount: 1,
            senderScriptPubKey: senderScriptPubKey
        )
    }

    // MARK: - Sending

    /// `deferNoInputRetry` false (the chess sends): a send whose coins are not spendable yet
    /// throws instead of being retried later in the background, so the caller - which retries a
    /// few times itself and then shows the error - never reports a move as sent that is not.
    /// Returns the transaction id; nil only when the send was deferred.
    @discardableResult
    func sendPublicChat(channel rawChannel: String, content: String, feeOverride: UInt64? = nil, deferNoInputRetry: Bool = true) async throws -> String? {
        let channel = PublicChatChannelName.normalize(rawChannel)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PublicChatChannelName.isValid(channel) else {
            throw KasiaError.networkError("Invalid channel name")
        }
        guard !trimmed.isEmpty else { return nil }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        // If replying, wrap the content in the shared reply envelope (matches Android's
        // PublicChatViewModel.sendPublicChat) so the quote survives even if the original message is
        // later pruned or its sender hidden.
        let payload: String
        if let reply = replyingTo {
            let preview = MessageReplyCodec.previewText(for: reply.content)
            payload = MessageReplyCodec.encode(
                replyToId: reply.id,
                replyToSender: reply.senderAddress,
                replyToPreview: preview,
                text: trimmed
            )
        } else {
            payload = trimmed
        }

        let pendingId = "pending_\(UUID().uuidString)"
        let pendingBlockTime = Int64(Date().timeIntervalSince1970 * 1000)
        store.insertMessage(
            id: pendingId,
            channel: channel,
            senderAddress: wallet.publicAddress,
            content: payload,
            blockTime: pendingBlockTime,
            deliveryStatus: .pending
        )
        loadMessages(for: channel)

        do {
            let txId = try await ChatService.shared.enqueueOutgoingTxOperation {
                try await self.sendPublicChatInternal(
                    channel: channel,
                    content: payload,
                    walletAddress: wallet.publicAddress,
                    privateKey: privateKey,
                    pendingId: pendingId,
                    feeOverride: feeOverride
                )
            }
            replyingTo = nil
            return txId
        } catch {
            try await handleSendFailure(
                error,
                channel: channel,
                content: payload,
                walletAddress: wallet.publicAddress,
                privateKey: privateKey,
                pendingId: pendingId,
                deferRetry: deferNoInputRetry
            )
            return nil
        }
    }

    // MARK: - Own arena rows the chain has not shown yet

    /// When a due row may next be looked up (wall ms): one still in a mempool, or one the REST
    /// API could not answer for, is asked about again later, not on every tick.
    private var localStampNextCheck: [String: Int64] = [:]
    /// Own rows marked failed this session: if the chain shows one after all, it counts again.
    private var droppedServiceRows: Set<String> = []
    private nonisolated static let localStampsKey = "publicChatLocalStampSentAt"
    /// A row a node says it doesn't hold still waits this long from sending, for a REST API
    /// running behind. Short of the give-up: a move really lost must leave clock to replay it.
    private static let restLagGraceMs: Int64 = 120_000

    private func trackLocalStamp(_ txId: String) {
        localStampSentAt[txId] = Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// The chain (a scanned block or the indexer) showed the row: it carries the chain's time now.
    private func confirmLocalStamp(_ txId: String) {
        guard localStampSentAt[txId] != nil else { return }
        localStampSentAt[txId] = nil
        localStampNextCheck[txId] = nil
    }

    private nonisolated static func localStampsWalletKey(_ wallet: String) -> String { "\(localStampsKey).\(wallet)" }

    private nonisolated static func loadLocalStamps(wallet: String) -> [String: Int64] {
        guard let data = UserDefaults.standard.data(forKey: localStampsWalletKey(wallet)),
              let saved = try? JSONDecoder().decode([String: Int64].self, from: data) else { return [:] }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return saved.mapValues { _ in now }
    }

    private nonisolated static func saveLocalStamps(_ stamps: [String: Int64], wallet: String?) {
        guard let wallet, let data = try? JSONEncoder().encode(stamps) else { return }
        UserDefaults.standard.set(data, forKey: localStampsWalletKey(wallet))
    }

    /// Own arena rows the chain has not shown `bound` ms after they were sent. Each is looked up:
    /// accepted (REST API), it takes the block's time there; in a mempool or spent to a coin the
    /// address holds, it waits or counts as landed; found nowhere by a node that answered, once
    /// the REST API has had `restLagGraceMs` to catch up, it is marked failed, so the arena's
    /// reducer stops applying it and the board is the chain's again (a move is the player's to
    /// play again). A row the network cannot be asked about is given up after `giveUp` ms. A
    /// failed row the chain shows later takes its block time and counts again
    /// (`PublicChatStore.updateBlockTime`). Returns the ids marked failed.
    func checkUnconfirmedServiceRows(olderThan bound: Int64, giveUpAfter giveUp: Int64) async -> Set<String> {
        guard !isCheckingLocalStamps else { return [] }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let due = localStampSentAt.filter { now - $0.value > bound && (localStampNextCheck[$0.key] ?? 0) <= now }
        guard !due.isEmpty else { return [] }
        isCheckingLocalStamps = true
        defer { isCheckingLocalStamps = false }
        var failed: Set<String> = []
        var changed = false
        for (txId, sentAt) in due {
            let lookup = await Self.lookUpTransaction(txId: txId)
            // The chain showed it while the lookup ran.
            guard localStampSentAt[txId] != nil else { continue }
            let later = Int64(Date().timeIntervalSince1970 * 1000) + 15_000
            switch lookup {
            case .accepted(let blockTime):
                confirmLocalStamp(txId)
                if let blockTime, store.updateBlockTime(id: txId, blockTime: blockTime) { changed = true }
                continue
            case .unanswered where now - sentAt <= giveUp:
                localStampNextCheck[txId] = later
                continue
            case .notAccepted:
                if await NodePoolService.shared.getMempoolEntry(txId: txId) != nil {
                    localStampNextCheck[txId] = later
                    continue
                }
                // No mempool entry also comes back when no node could be asked, and a 404 from a
                // REST API running behind: neither says the transaction is gone.
                let address = WalletManager.shared.currentWallet?.publicAddress
                if let address, let utxos = try? await NodePoolService.shared.getUtxosByAddresses([address], allowRestFallback: false) {
                    if utxos.contains(where: { $0.outpoint.transactionId == txId }) {
                        confirmLocalStamp(txId)
                        continue
                    }
                    if now - sentAt <= Self.restLagGraceMs {
                        localStampNextCheck[txId] = later
                        continue
                    }
                } else if now - sentAt <= giveUp {
                    localStampNextCheck[txId] = later
                    continue
                }
            case .unanswered:
                break
            }
            // The chain showed it, or the account changed, while the lookups ran.
            guard localStampSentAt[txId] != nil else { continue }
            AppLog.log("[PublicChatService] Own arena tx %@ never reached the chain: dropped", String(txId.prefix(12)))
            localStampSentAt[txId] = nil
            localStampNextCheck[txId] = nil
            store.updateMessageStatus(id: txId, status: .failed)
            droppedServiceRows.insert(txId)
            failed.insert(txId)
            changed = true
        }
        if changed {
            for channel in Self.serviceChannels { loadMessages(for: channel) }
        }
        return failed
    }

    private enum TransactionLookup {
        case accepted(blockTime: Int64?)
        case notAccepted
        case unanswered
    }

    /// The REST API's view of a transaction: accepted (with its block's time), unknown or not
    /// accepted, or no answer.
    private static func lookUpTransaction(txId: String) async -> TransactionLookup {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/transactions/\(txId)?inputs=false&outputs=false&resolve_previous_outpoints=no") else { return .unanswered }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unanswered }
        if status == 404 { return .notAccepted }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unanswered }
        guard (json["is_accepted"] as? Bool) == true else { return .notAccepted }
        return .accepted(blockTime: (json["block_time"] as? NSNumber)?.int64Value)
    }

    /// What a chess send should say when the chatting address has no coins at all - not the
    /// "wait for confirmations" of a change output still being mined, which retries.
    static var notEnoughKasMessage: String {
        AppLocalization.string("Not enough KAS on your Chatting Address. Add some and try again.")
    }

    /// Worth trying again in a moment: the coins are there but not spendable yet (the change of
    /// the last send), or the node rejected the transaction as an orphan / already spent - none
    /// of which reached the chain. Anything else (no funds, a timeout whose outcome is unknown)
    /// is not retried blindly.
    static func isRetryableSendError(_ error: Error) -> Bool {
        let chatService = ChatService.shared
        if chatService.isNoConfirmedInputsError(error) || chatService.shouldRetrySendError(error) { return true }
        let confirming = AppLocalization.string("The network is still confirming your previous send. Please try again in a few seconds.").lowercased()
        return error.localizedDescription.lowercased().contains(confirming)
    }

    /// If sending too quickly back-to-back races the previous public chat's not-yet-confirmed
    /// UTXOs, `sendPublicChatInternal` surfaces that as a "no confirmed inputs" error - automatic-
    /// ally retry those with backoff (matches 1:1 chat's `scheduleOutgoingRetry`) instead of
    /// leaving the user to notice and manually tap retry. Any other error still fails immediately.
    private func handleSendFailure(
        _ error: Error,
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String,
        deferRetry: Bool = true
    ) async throws {
        if deferRetry, ChatService.shared.isNoConfirmedInputsError(error) {
            let delay = ChatService.shared.nextNoInputRetryDelay(for: pendingId)
            AppLog.log("[PublicChatService] Deferred retry (no confirmed inputs) for %@ in %.0fs",
                  String(pendingId.prefix(12)), delay)
            schedulePublicChatRetry(
                channel: channel,
                content: content,
                walletAddress: walletAddress,
                privateKey: privateKey,
                pendingId: pendingId,
                delaySeconds: delay
            )
            return
        }
        ChatService.shared.clearNoInputRetryState(for: pendingId)
        store.markMessageFailed(pendingId: pendingId)
        loadMessages(for: channel)
        // Surface a humanized message (never kaspad's raw "orphan is disallowed" text) - this is
        // what the composer's "Failed to send" toast renders, possibly while the user is already
        // typing their next message.
        let surfaced = KasiaError.networkError(Self.friendlySendErrorMessage(for: error))
        lastSendError = surfaced
        // Kept as itself: a caller must be able to tell "may have gone through" from a failure
        // (a bot stamp offers no Retry for it - a second stamp of the same game).
        if error is SendOutcomeUnknownError { throw error }
        throw surfaced
    }

    private func schedulePublicChatRetry(
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String,
        delaySeconds: TimeInterval
    ) {
        guard !scheduledSendRetries.contains(pendingId) else { return }
        scheduledSendRetries.insert(pendingId)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let self else { return }
            self.scheduledSendRetries.remove(pendingId)
            let currentStatus = self.store.deliveryStatus(ofMessage: pendingId)
            guard currentStatus == .pending else {
                ChatService.shared.clearNoInputRetryState(for: pendingId)
                return
            }
            do {
                _ = try await ChatService.shared.enqueueOutgoingTxOperation {
                    try await self.sendPublicChatInternal(
                        channel: channel,
                        content: content,
                        walletAddress: walletAddress,
                        privateKey: privateKey,
                        pendingId: pendingId
                    )
                }
            } catch {
                try? await self.handleSendFailure(
                    error,
                    channel: channel,
                    content: content,
                    walletAddress: walletAddress,
                    privateKey: privateKey,
                    pendingId: pendingId
                )
            }
        }
    }

    /// Returns the submitted transaction's id. For a normal message send the pending row is
    /// resolved to it in-store; reaction sends (which have no message row - their `pendingId` is
    /// synthetic) use the returned id to stamp the reaction's `reactionTxId`.
    @discardableResult
    private func sendPublicChatInternal(
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String,
        feeOverride: UInt64? = nil
    ) async throws -> String {
        let chatService = ChatService.shared

        // Fetch UTXOs fresh (not the 20s-stale `fetchCachedUtxos`) and merge in any pending
        // change output from a just-submitted public chat, excluding whatever it just spent - the
        // same in-flight UTXO chaining 1:1 messages use, so sending several public chats back-to-
        // back doesn't try to double-spend the same not-yet-confirmed UTXO.
        let freshUtxos = try await NodePoolService.shared.getUtxosByAddresses([walletAddress])
        let candidateUtxos = chatService.prepareMessageUtxos(confirmed: freshUtxos)
        guard !candidateUtxos.isEmpty else {
            // No coin at all on the address (and none in flight): waiting will not help, so say
            // so instead of "wait for confirmations" - which retried in the background forever.
            if freshUtxos.isEmpty { throw KasiaError.networkError(Self.notEnoughKasMessage) }
            throw KasiaError.networkError(chatService.noSpendableFundsYetMessage())
        }

        do {
            return try await buildSignSubmitPublicChat(
                channel: channel,
                content: content,
                walletAddress: walletAddress,
                privateKey: privateKey,
                pendingId: pendingId,
                utxos: candidateUtxos,
                feeOverride: feeOverride
            )
        } catch {
            // The node pool hedges submits across nodes, so the node this landed on can be a few
            // seconds behind the node that served the UTXO snapshot (or behind a just-accepted
            // public chat whose change we chained). It then rejects with kaspad's raw
            // "... is an orphan, where orphan is disallowed" / "already spent" text. That's a
            // transient state mismatch, not a user error - retry ONCE with a freshly fetched,
            // confirmed-only input set (mirrors the 1:1 path's confirmed-only fallback) before
            // giving up, instead of surfacing raw node text (see friendlySendErrorMessage).
            guard chatService.shouldRetrySendError(error) else { throw error }
            let refetched = try await NodePoolService.shared.getUtxosByAddresses([walletAddress])
            let confirmedOnly = chatService.prepareMessageUtxos(confirmed: refetched)
                .filter { $0.blockDaaScore > 0 }
            guard !confirmedOnly.isEmpty else { throw error }
            AppLog.log("[PublicChatService] Submit rejected (%@) for %@ - retrying with confirmed-only inputs",
                       error.localizedDescription, String(pendingId.prefix(12)))
            return try await buildSignSubmitPublicChat(
                channel: channel,
                content: content,
                walletAddress: walletAddress,
                privateKey: privateKey,
                pendingId: pendingId,
                utxos: confirmedOnly,
                feeOverride: feeOverride
            )
        }
    }

    /// One build -> sign -> submit -> bookkeeping attempt against a fixed candidate UTXO set.
    /// Split out of `sendPublicChatInternal` so the orphan/already-spent fallback there can rerun
    /// the whole attempt against a refreshed input set.
    private func buildSignSubmitPublicChat(
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String,
        utxos candidateUtxos: [UTXO],
        feeOverride: UInt64?
    ) async throws -> String {
        let chatService = ChatService.shared

        let tx = try KasiaTransactionBuilder.buildPublicChatTx(
            from: walletAddress,
            channel: channel,
            content: content,
            senderPrivateKey: privateKey,
            utxos: candidateUtxos,
            feeOverride: feeOverride
        )
        let spentUtxos = chatService.spentMessageUtxos(from: tx, candidates: candidateUtxos)
        let usesUnconfirmedInputs = spentUtxos.contains { $0.blockDaaScore == 0 }

        do {
            let (txId, _) = try await NodePoolService.shared.submitTransaction(tx, allowOrphan: usesUnconfirmedInputs)
            chatService.reserveMessageOutpoints(spentUtxos)
            chatService.consumePendingUtxos(spentUtxos)
            if let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: walletAddress) {
                chatService.addPendingOutputs(from: tx, txId: txId, senderScriptPubKey: senderScriptPubKey)
            }
            chatService.clearNoInputRetryState(for: pendingId)
            let blockTime = Int64(Date().timeIntervalSince1970 * 1000)
            if Self.serviceChannels.contains(channel) { trackLocalStamp(txId) }
            store.resolvePendingMessage(pendingId: pendingId, realId: txId, blockTime: blockTime)
            loadMessages(for: channel)
            return txId
        } catch let unknown as SendOutcomeUnknownError {
            // A node may hold it: its coins stay reserved (the reservation runs out by itself if
            // it never lands), or the next send would spend them again. An arena row is kept as
            // sent - a move's ply stays taken - and the unconfirmed-row check below settles it
            // (`checkUnconfirmedServiceRows`): the chain shows it, or it is dropped. Elsewhere the
            // send fails with "may have gone through", never offering a blind resend.
            chatService.reserveMessageOutpoints(spentUtxos)
            chatService.consumePendingUtxos(spentUtxos)
            if let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: walletAddress) {
                chatService.addPendingOutputs(from: tx, txId: unknown.txId, senderScriptPubKey: senderScriptPubKey)
            }
            guard Self.serviceChannels.contains(channel) else { throw unknown }
            chatService.clearNoInputRetryState(for: pendingId)
            trackLocalStamp(unknown.txId)
            store.resolvePendingMessage(pendingId: pendingId, realId: unknown.txId, blockTime: Int64(Date().timeIntervalSince1970 * 1000))
            loadMessages(for: channel)
            return unknown.txId
        } catch {
            chatService.releaseMessageOutpoints()
            throw error
        }
    }

    /// Node-level rejection text ("transaction ... is an orphan, where orphan is disallowed",
    /// "already spent", ...) means "the network hasn't caught up with your previous send yet" -
    /// meaningless and alarming to a user mid-typing. Map it (after retries are exhausted) to a
    /// plain-language message; anything unrecognized passes through unchanged.
    static func friendlySendErrorMessage(for error: Error) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("orphan") || lower.contains("already spent") || lower.contains("double spend") {
            return AppLocalization.string("The network is still confirming your previous send. Please try again in a few seconds.")
        }
        if lower.contains("insufficient funds") { return notEnoughKasMessage }
        return raw
    }

    // MARK: - Block scanning lifecycle

    /// The channels that justify the block stream on the CURRENT network path. On WiFi this is
    /// every wanted channel. On an expensive (cellular/metered) path, featured rooms are
    /// dropped when the KaChat public chat indexer is configured: an OPEN featured room is kept
    /// fresh by the existing 8s indexer poll (`startIndexerPollingIfConfigured`), and a closed
    /// one is covered by remote push - so streaming every block for them is pure duplicate
    /// cost. Non-indexed rooms (user-added channels with alwaysListen, or open non-featured
    /// rooms) have NO other delivery path, so they keep the stream even on cellular.
    private var scanWantedChannels: Set<String> {
        var wanted = wantedChannels
        // With the indexer down the stream is the only live route, cellular or not: it's how a
        // game in progress keeps getting the other player's moves.
        guard NetworkEpochMonitor.shared.isExpensivePath, !arenaIndexerDown else { return wanted }
        // Per room, since each can point at its own indexer now: a curated room whose override
        // is blank still counts as indexed via the app-wide setting.
        wanted.subtract(Self.indexerTrackedChannels.filter { !Self.indexerBaseURL(forChannel: $0).isEmpty })
        return wanted
    }

    private func updateScanningStateIfNeeded() {
        let shouldScan = !scanWantedChannels.isEmpty
        guard shouldScan != isScanningActive else { return }
        isScanningActive = shouldScan
        if shouldScan {
            startScanning()
        } else {
            stopScanning()
        }
    }

    private nonisolated static let blockScanQueue = DispatchQueue(label: "com.kachat.broadcastBlockScan", qos: .utility)

    /// One fully-parsed public chat candidate from a scanned block. `senderAddress` is what
    /// output 0 claims until `verifiedAuthors` has checked input 0 spends from it (XP-012).
    struct BlockScanHit {
        let channel: String
        let txId: String
        let senderAddress: String
        let content: String
        let blockTime: Int64
        var inputTxId: String = ""
        var inputIndex: UInt32 = 0
    }

    /// OFF-MAIN block scan over the stream's once-parsed `ScannedBlock` (the old path decoded
    /// the whole protobuf block again here, and again in GroupChatService). Pure extraction,
    /// no state: wanted/hidden filtering happens on the main hop, which only fires for actual
    /// hits (almost every block has zero).
    private nonisolated static func extractPublicChatHits(_ block: ScannedBlock, hrp: String) -> [BlockScanHit] {
        var hits: [BlockScanHit] = []
        for tx in block.transactions {
            guard tx.payloadHex.hasPrefix(bcastPrefixHex) || tx.payloadHex.hasPrefix(legacyBcastPrefixHex) else { continue }
            guard let payloadData = CryptoUtils.hexToData(tx.payloadHex),
                  let payloadString = String(data: payloadData, encoding: .utf8),
                  let parsed = KasiaTransactionBuilder.parsePublicChatPayload(payloadString) else { continue }
            guard let scriptData = CryptoUtils.hexToData(tx.firstOutputScriptHex),
                  let senderAddress = KaspaAddress.address(fromScriptPublicKey: scriptData, hrp: hrp) else { continue }
            hits.append(BlockScanHit(
                channel: PublicChatChannelName.normalize(parsed.channel),
                txId: tx.txId,
                senderAddress: senderAddress,
                content: parsed.content,
                blockTime: tx.blockTime,
                inputTxId: tx.firstInputTxId,
                inputIndex: tx.firstInputIndex
            ))
        }
        return hits
    }

    /// XP-012: a public chat payload carries no signature, so its author is whoever signed the
    /// transaction. A post is kept only when the address its input 0 spends from is the address
    /// output 0 pays (the rule Desktop uses); otherwise anyone could post, edit messages and play
    /// chess as any address by paying them output 0. Input 0's address comes from a recent payload
    /// transaction's outputs (a poster's previous post) or else the REST API; a post whose input
    /// can't be resolved is dropped.
    private nonisolated static func verifiedAuthors(_ hits: [BlockScanHit], hrp: String) async -> [BlockScanHit] {
        await withTaskGroup(of: BlockScanHit?.self) { group in
            for hit in hits {
                group.addTask {
                    guard !hit.inputTxId.isEmpty,
                          let spentFrom = await inputAddress(txId: hit.inputTxId, index: hit.inputIndex, hrp: hrp),
                          spentFrom.lowercased() == hit.senderAddress.lowercased() else {
                        AppLog.log("[PublicChat] dropped %@: input 0 is not the posting address", hit.txId)
                        return nil
                    }
                    return hit
                }
            }
            var kept: [BlockScanHit] = []
            for await hit in group { if let hit { kept.append(hit) } }
            return kept
        }
    }

    /// The address an outpoint pays: from the recent-output cache, else the REST API (the
    /// previous transaction is older than the post, so it is indexed; retried briefly).
    private nonisolated static func inputAddress(txId: String, index: UInt32, hrp: String) async -> String? {
        if let script = RecentOutputScripts.shared.script(txId: txId, index: index),
           let data = CryptoUtils.hexToData(script) {
            return KaspaAddress.address(fromScriptPublicKey: data, hrp: hrp)
        }
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/transactions/\(txId)?inputs=false&outputs=true&resolve_previous_outpoints=no") else { return nil }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let outputs = j["outputs"] as? [[String: Any]] else { continue }
            let output = outputs.first { ($0["index"] as? NSNumber)?.uint32Value == index } ?? (Int(index) < outputs.count ? outputs[Int(index)] : nil)
            if let address = output?["script_public_key_address"] as? String { return address }
            if let script = output?["script_public_key"] as? String, let data = CryptoUtils.hexToData(script) {
                return KaspaAddress.address(fromScriptPublicKey: data, hrp: hrp)
            }
        }
        return nil
    }

    private func startScanning() {
        if blockNotificationHandlerId == nil {
            blockNotificationHandlerId = NodePoolService.shared.addBlockHandler { [weak self] block in
                Self.blockScanQueue.async {
                    let hrp = AppSettings.load().networkType == .mainnet ? "kaspa" : "kaspatest"
                    let hits = Self.extractPublicChatHits(block, hrp: hrp)
                    guard !hits.isEmpty else { return }
                    Task { @MainActor in
                        // only posts whose input 0 spends from the posting address (XP-012);
                        // verifiedAuthors is nonisolated, so the lookups run off the main actor
                        let verified = await Self.verifiedAuthors(hits, hrp: hrp)
                        guard !verified.isEmpty else { return }
                        await self?.processPublicChatHits(verified)
                    }
                }
            }
        }
        Task { await NodePoolService.shared.subscribeBlockAdded(client: "broadcast-scan") }
    }

    private func stopScanning() {
        Task { await NodePoolService.shared.unsubscribeBlockAdded(client: "broadcast-scan") }
        // The notification handler stays registered - see NodePoolService.unsubscribeBlockAdded
        // for why there's no protocol-level way to actually stop the node from pushing them.
        // handleBlockAddedData() bails out immediately when wantedChannels is empty, so this
        // is a cheap no-op rather than wasted scanning work.
    }

    // MARK: - Block scanning

    /// Main-actor tail of the block scan: runs ONLY when a block actually contained public chat
    /// payloads (rare). State filtering + store insert + UI refresh. The message rows go in as
    /// one background batch: a reconnect burst used to do one synchronous main-thread save per
    /// row.
    private func processPublicChatHits(_ hits: [BlockScanHit]) async {
        let wanted = wantedChannels
        guard !wanted.isEmpty else { return }
        let hidden = store.hiddenSendersByChannel()
        var touchedChannels = Set<String>()
        var reactionChannels = Set<String>()
        var editChannels = Set<String>()
        var messageHits: [BlockScanHit] = []

        for hit in hits {
            guard wanted.contains(hit.channel) else { continue }
            guard !hidden.global.contains(hit.senderAddress),
                  hidden.perChannel[hit.channel]?.contains(hit.senderAddress) != true else { continue }
            // Reactions are never shown as their own bubble (or notified) - just attached to the
            // message they target - so intercept and route to the reactions index before this
            // ever becomes a message row. Our own outgoing reactions already applied their local
            // update at send time (sendPublicChatReaction); newest-blockTime-wins dedupes the echo.
            if let edit = MessageEditCodec.parse(hit.content) {
                if applyIncomingEdit(edit, channel: hit.channel, senderAddress: hit.senderAddress, editTxId: hit.txId, blockTime: hit.blockTime) {
                    editChannels.insert(hit.channel)
                }
                continue
            }
            if let reaction = MessageReactionCodec.parse(hit.content) {
                let changed = store.applyIncomingReaction(
                    targetTxId: reaction.targetTxId,
                    channel: hit.channel,
                    reactorAddress: hit.senderAddress,
                    emoji: reaction.action == "remove" ? nil : reaction.emoji,
                    reactionTxId: hit.txId,
                    blockTime: hit.blockTime
                )
                if changed { reactionChannels.insert(hit.channel) }
                continue
            }
            messageHits.append(hit)
        }

        if !messageHits.isEmpty {
            let inserted = await store.insertMessages(messageHits.map {
                (id: $0.txId, channel: $0.channel, senderAddress: $0.senderAddress, content: $0.content, blockTime: $0.blockTime)
            })
            for hit in messageHits {
                // Only a row still on this phone's clock, or given up on. Any other row already
                // has a chain time: a transaction can sit in several parallel blocks with
                // different times, and the indexer's is the one every phone ends up with.
                let takesStreamTime = Self.serviceChannels.contains(hit.channel)
                    && !inserted.contains(hit.txId)
                    && (localStampSentAt[hit.txId] != nil || store.deliveryStatus(ofMessage: hit.txId) == .failed)
                if Self.serviceChannels.contains(hit.channel) { confirmLocalStamp(hit.txId) }
                if inserted.contains(hit.txId) {
                    touchedChannels.insert(hit.channel)
                    notifyIfEnabled(channel: hit.channel, senderAddress: hit.senderAddress, content: hit.content, txId: hit.txId)
                } else if takesStreamTime, store.updateBlockTime(id: hit.txId, blockTime: hit.blockTime) {
                    // Our own arena row, stamped with this phone's clock when it was submitted:
                    // the block's time is what every other phone sees, so take it (the reducer
                    // orders joins and runs the clocks by it).
                    droppedServiceRows.remove(hit.txId)
                    touchedChannels.insert(hit.channel)
                }
            }
        }

        for channel in reactionChannels {
            loadReactions(for: channel)
        }
        for channel in editChannels {
            loadEdits(for: channel)
        }

        guard !touchedChannels.isEmpty else { return }
        for channel in touchedChannels {
            loadMessages(for: channel)
        }
        await store.pruneExpiredMessages()
    }

    // MARK: - The arena from the REST API

    private struct ChainArenaRow {
        let txId: String
        let sender: String
        let content: String
        let blockTime: Int64
    }

    private nonisolated static let chainPageSize = 100
    private nonisolated static let chainMaxPages = 20

    /// One room's messages from its known players, read by address from the Kaspa REST API, for
    /// while the indexer is down. A channel has no address of its own, so this can only fill in a
    /// room whose players this phone already knows; it can't find new rooms or new joiners, and
    /// the arena's history can't be rebuilt this way. Only rows the store doesn't hold go in, so
    /// a time the indexer gave is left alone. True when every player's address answered.
    func readArenaFromChain(tournamentId: String, players: [String], since: Int64) async -> Bool {
        var found: [ChainArenaRow] = []
        var complete = true
        for address in players {
            guard let rows = await Self.chainArenaRows(address: address, tournamentId: tournamentId, since: since) else {
                complete = false
                continue
            }
            found.append(contentsOf: rows)
        }
        await mergeChainArenaRows(found)
        return complete
    }

    private func mergeChainArenaRows(_ found: [ChainArenaRow]) async {
        guard !found.isEmpty else { return }
        let arena = ChessTournamentCodec.arenaChannel
        let hidden = store.hiddenSenderAddresses(forChannel: arena)
        let rows = found
            .filter { !hidden.contains($0.sender) }
            .map { (id: $0.txId, channel: arena, senderAddress: $0.sender, content: $0.content, blockTime: $0.blockTime) }
        var changed = !(await store.insertMessages(rows)).isEmpty
        // Our own rows still on this phone's clock, or given up on, take the chain's time.
        for row in rows where localStampSentAt[row.id] != nil || droppedServiceRows.contains(row.id) {
            confirmLocalStamp(row.id)
            droppedServiceRows.remove(row.id)
            if store.updateBlockTime(id: row.id, blockTime: row.blockTime) { changed = true }
        }
        if changed { await reloadMessagesNow(for: arena) }
    }

    /// `address`'s accepted posts to the room since `since`, newest pages first until they're
    /// older than that. The author rule is the block scan's (XP-012): input 0 spends from the
    /// address output 0 pays. Nil when the REST API didn't answer.
    private nonisolated static func chainArenaRows(address: String, tournamentId: String, since: Int64) async -> [ChainArenaRow]? {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        let me = address.lowercased()
        var found: [ChainArenaRow] = []
        for page in 0..<chainMaxPages {
            guard let url = URL(string: "\(root)/addresses/\(me)/full-transactions?limit=\(chainPageSize)&offset=\(page * chainPageSize)&resolve_previous_outpoints=light&fields=transaction_id,is_accepted,payload,inputs,outputs,block_time") else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
            var reachedSince = false
            for row in rows {
                guard let blockTime = chainNumber(row["block_time"]) else { continue }
                if blockTime < since { reachedSince = true; continue }
                if let parsed = chainArenaRow(row, address: address, me: me, blockTime: blockTime),
                   ChessTournamentCodec.decode(parsed.content)?.t == tournamentId {
                    found.append(parsed)
                }
            }
            if rows.count < chainPageSize || reachedSince { break }
        }
        return found
    }

    private nonisolated static func chainNumber(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    private nonisolated static func chainArenaRow(_ row: [String: Any], address: String, me: String, blockTime: Int64) -> ChainArenaRow? {
        func first(_ key: String) -> [String: Any]? {
            ((row[key] as? [[String: Any]]) ?? []).min { (chainNumber($0["index"]) ?? 0) < (chainNumber($1["index"]) ?? 0) }
        }
        guard (row["is_accepted"] as? Bool) == true, let txId = row["transaction_id"] as? String,
              (first("inputs")?["previous_outpoint_address"] as? String)?.lowercased() == me,
              (first("outputs")?["script_public_key_address"] as? String)?.lowercased() == me,
              let payloadHex = row["payload"] as? String,
              let payload = CryptoUtils.hexToData(payloadHex),
              let text = String(data: payload, encoding: .utf8),
              let parsed = KasiaTransactionBuilder.parsePublicChatPayload(text),
              PublicChatChannelName.normalize(parsed.channel) == ChessTournamentCodec.arenaChannel else { return nil }
        return ChainArenaRow(txId: txId, sender: address, content: parsed.content, blockTime: blockTime)
    }

    // MARK: - Local notifications

    /// Fires a local notification for a newly-scanned message, matching Android's per-channel
    /// "Enable Notifications" toggle - like block scanning itself, this only ever fires while the
    /// app is alive (foreground or briefly backgrounded), never for a fully closed/terminated app.
    private func notifyIfEnabled(channel: String, senderAddress: String, content: String, txId: String) {
        guard !Self.serviceChannels.contains(channel) else { return }
        guard senderAddress != WalletManager.shared.currentWallet?.publicAddress else { return }
        guard channels.first(where: { $0.channelName == channel })?.notifyEnabled == true else { return }
        guard !store.hiddenSenderAddresses(forChannel: channel).contains(senderAddress) else { return }
        let settings = AppSettings.load()
        guard settings.notificationsEnabled else { return }
        // Simple Mode removes Public Chats entirely - no local banners for them either.
        // The remote push is the only banner source - see `ChatService.localBannersEnabled`.
        guard ChatService.localBannersEnabled else { return }
        guard !settings.childModeEnabled else { return }
        // Indexed channels are covered by remote push (registered via
        // watched_publicChat_channels) while the app is backgrounded or closed - skip the
        // scan-driven local banner there so one message can't notify twice. While the app is
        // ACTIVE the scan is the notification source whatever the mode
        // (AppDelegate.willPresent drops public chat pushes in foreground), so the banner fires.
        if Self.isIndexerTracked(channel), settings.notificationMode == .remotePush,
           UIApplication.shared.applicationState != .active {
            return
        }
        // Foreground policy: in-app banners fire everywhere (chat list, other chats) EXCEPT the
        // room currently on screen - same rule as 1:1's active conversation and groups'
        // activeGroupId. The refcount alone isn't enough: the screen stays "open" while the app
        // is backgrounded, and then the banner SHOULD fire.
        if isViewing(channel: channel), UIApplication.shared.applicationState == .active {
            return
        }

        let notificationBody = MessageReplyCodec.previewText(for: content)

        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = "#\(channel)"
        notificationContent.body = notificationBody
        notificationContent.sound = .default
        notificationContent.threadIdentifier = "broadcast:\(channel)"

        // Keyed by txId: matches the push spec's apns-collapse-id (= message txid), so in the
        // rare cross-state race (local banner posted while active, push displayed after the
        // app backgrounds) the second one replaces the first in Notification Center instead
        // of stacking. Also self-dedupes a re-scanned message.
        let request = UNNotificationRequest(
            identifier: txId,
            content: notificationContent,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLog.log("[PublicChatService] Failed to send local notification: %@", error.localizedDescription)
            }
        }
    }
}


// MARK: - Public Chat indexer client

/// Minimal read client for the KaChat-owned public chat indexer (see PUBLIC_CHATS_INDEXER.md - the
/// server tracks #kaspa and #kachat-bugs history so clients aren't limited to what they catch
/// live). The API contract this client expects is the source of truth for the server build.
enum PublicChatIndexerClient {
    struct IndexedPublicChat: Decodable {
        let txId: String
        let channel: String?
        let senderAddress: String
        let content: String
        let blockTime: Int64
    }

    private struct HistoryResponse: Decodable {
        let messages: [IndexedPublicChat]
        let hasMore: Bool?
    }

    enum ClientError: LocalizedError {
        case badURL
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid public chats indexer URL"
            case .badResponse(let code): return "Public chats indexer returned HTTP \(code)"
            }
        }
    }

    /// Same fetch, but keeps the server's `hasMore` so callers can page older history with
    /// `before` — the plain fetchHistory silently discarded it, which is why rooms only ever
    /// showed the newest single page.
    static func fetchHistoryPage(
        baseURL: String,
        channel: String,
        limit: Int = 200,
        before: Int64? = nil
    ) async throws -> (messages: [IndexedPublicChat], hasMore: Bool) {
        guard PublicChatChannelName.normalize(channel) == ChessTournamentCodec.arenaChannel else {
            return try await requestHistoryPage(baseURL: baseURL, channel: channel, limit: limit, before: before)
        }
        do {
            let page = try await requestHistoryPage(baseURL: baseURL, channel: channel, limit: limit, before: before)
            await noteArenaResult(error: nil)
            return page
        } catch {
            await noteArenaResult(error: error)
            throw error
        }
    }

    /// Whether the chess arena's indexer is answering. Every arena read reports here.
    static let arenaHealth = IndexerHealth()

    private enum Outcome { case answered, down, inconclusive }

    private static func outcome(of error: Error) -> Outcome {
        if error is CancellationError { return .inconclusive }
        if let urlError = error as? URLError {
            switch urlError.code {
            // the phone has no connection: that says nothing about the indexer
            case .cancelled, .notConnectedToInternet, .dataNotAllowed: return .inconclusive
            default: return .down
            }
        }
        // Any status that isn't a success, or a body that doesn't decode, gave no rows: to the
        // arena that's the same as no answer, and the REST API must take over.
        if error is ClientError || error is DecodingError { return .down }
        return .inconclusive
    }

    private static func noteArenaResult(error: Error?) async {
        switch error.map(outcome(of:)) ?? .answered {
        case .answered: _ = await arenaHealth.recordAnswer()
        case .down: _ = await arenaHealth.recordFailure()
        case .inconclusive: break
        }
        let down = await arenaHealth.isDown
        await MainActor.run { PublicChatService.shared.arenaHealthObserved(down: down) }
    }

    private static func requestHistoryPage(
        baseURL: String,
        channel: String,
        limit: Int,
        before: Int64?
    ) async throws -> (messages: [IndexedPublicChat], hasMore: Bool) {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        var components = URLComponents(string: "\(trimmed)/get-broadcasts")
        var query = [
            URLQueryItem(name: "channel", value: channel),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let before {
            query.append(URLQueryItem(name: "before", value: String(before)))
        }
        components?.queryItems = query
        guard let url = components?.url else { throw ClientError.badURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.badResponse(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(HistoryResponse.self, from: data)
        // An indexer only stores the rooms it tracks: rows back mean it keeps this room's history.
        if !decoded.messages.isEmpty {
            IndexerTrackedRooms.markServed(channel)
        }
        return (decoded.messages, decoded.hasMore ?? false)
    }

    private struct TrackedChannelsResponse: Decodable {
        let channels: [String]
    }

    /// GET /broadcast-channels -> {"channels": [...]}: the rooms this indexer tracks now (set on
    /// the indexer's dashboard). nil when the indexer predates the endpoint (404) or can't be reached.
    static func fetchTrackedChannels(baseURL: String) async -> [String]? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        guard !trimmed.isEmpty, let url = URL(string: "\(trimmed)/broadcast-channels") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TrackedChannelsResponse.self, from: data) else { return nil }
        return decoded.channels
    }
}

extension Notification.Name {
    /// The chess arena's indexer stopped answering or came back; `userInfo["down"]` says which.
    static let indexerAvailabilityChanged = Notification.Name("indexerAvailabilityChanged")
}

/// Whether an indexer is answering (the same as KaChat's). It only counts as down after several
/// failures in a row, so one timeout never moves the arena off it. While it's down, one request a
/// minute is let through to find out when it's back; any answer brings it back at once.
actor IndexerHealth {
    private var downSince: Date?
    private var failuresInARow = 0
    private var lastFailureAt = Date.distantPast
    private var retryAt = Date.distantPast
    private static let failuresToGoDown = 3
    /// Failures further apart than this aren't a run.
    private static let failureWindow: TimeInterval = 120
    private static let retryInterval: TimeInterval = 60

    var isDown: Bool { downSince != nil }

    /// The next read goes through, down or not (a chess screen just opened).
    func allowProbeNow() { retryAt = .distantPast }

    func reset() {
        downSince = nil
        failuresInARow = 0
        retryAt = .distantPast
    }

    func shouldSkipIndexer() -> Bool {
        guard downSince != nil else { return false }
        let now = Date()
        // moved here rather than a "probing" flag, which could stick if the caller never asks
        guard now >= retryAt else { return true }
        retryAt = now.addingTimeInterval(Self.retryInterval)
        return false
    }

    /// True when this is the moment it went down.
    func recordFailure() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastFailureAt) > Self.failureWindow { failuresInARow = 0 }
        lastFailureAt = now
        failuresInARow += 1
        guard downSince == nil, failuresInARow >= Self.failuresToGoDown else { return false }
        downSince = now
        retryAt = now.addingTimeInterval(Self.retryInterval)
        return true
    }

    /// True when this is the moment it came back.
    func recordAnswer() -> Bool {
        failuresInARow = 0
        defer { downSince = nil }
        return downSince != nil
    }
}

/// The rooms an indexer tracks beyond the curated ones, so a room the operator adds on the
/// indexer gets everything a default room gets - its 30 days of history kept on the phone,
/// remote push, the cellular savings - with no app update. Learned two ways:
/// - **Reported**: the app-wide indexer's `GET /broadcast-channels` (replaced on every answer).
/// - **Served**: a room whose `/get-broadcasts` returned rows - an indexer stores only rooms it
///   tracks. Counts for 30 days after the last rows came back (the indexer's own window), so
///   this also works with an indexer that predates the endpoint, and with a room's own indexer.
/// Per network, persisted. Thread-safe: the store's background prune reads it.
enum IndexerTrackedRooms {
    /// Posted (main queue) when the set changes, so push registration and scanning follow.
    static let didChange = Notification.Name("IndexerTrackedRoomsDidChange")
    private static let servedWindow: TimeInterval = 30 * 24 * 3600

    private static let lock = NSLock()
    private static var loadedSuffix: String?
    private static var reported: Set<String> = []
    private static var served: [String: TimeInterval] = [:]

    private static var suffix: String {
        AppSettings.load().networkType == .mainnet ? "" : ".testnet"
    }
    private static func reportedKey(_ suffix: String) -> String { "kachat_indexer_tracked_rooms.reported" + suffix }
    private static func servedKey(_ suffix: String) -> String { "kachat_indexer_tracked_rooms.served" + suffix }

    /// Call with `lock` held: loads this network's sets once (again after a network switch).
    private static func loadIfNeeded() {
        let current = suffix
        guard loadedSuffix != current else { return }
        loadedSuffix = current
        reported = Set(UserDefaults.standard.stringArray(forKey: reportedKey(current)) ?? [])
        served = (UserDefaults.standard.dictionary(forKey: servedKey(current)) as? [String: TimeInterval]) ?? [:]
    }

    static func contains(_ normalized: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        if reported.contains(normalized) { return true }
        guard let at = served[normalized] else { return false }
        return Date().timeIntervalSince1970 - at < servedWindow
    }

    static func all() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        let now = Date().timeIntervalSince1970
        return reported.union(served.filter { now - $0.value < servedWindow }.keys)
    }

    /// The app-wide indexer's list, as `/broadcast-channels` answered.
    static func setReported(_ channels: [String]) {
        let names = Set(channels.map(PublicChatChannelName.normalize).filter { !$0.isEmpty })
        lock.lock()
        loadIfNeeded()
        let changed = names != reported
        if changed {
            reported = names
            UserDefaults.standard.set(Array(names).sorted(), forKey: reportedKey(loadedSuffix ?? ""))
        }
        lock.unlock()
        if changed { postChange() }
    }

    /// `channel`'s indexer just returned rows for it.
    static func markServed(_ channel: String) {
        let name = PublicChatChannelName.normalize(channel)
        guard !name.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        lock.lock()
        loadIfNeeded()
        let previous = served[name]
        let wasTracked = reported.contains(name) || previous.map { now - $0 < servedWindow } ?? false
        // written at most once an hour per room: every 8 s poll lands here
        let stale = previous.map { now - $0 > 3600 } ?? true
        if stale {
            served[name] = now
            UserDefaults.standard.set(served, forKey: servedKey(loadedSuffix ?? ""))
        }
        lock.unlock()
        if !wasTracked { postChange() }
    }

    private static func postChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }
}
