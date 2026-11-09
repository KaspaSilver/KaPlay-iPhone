import Foundation
import SwiftUI
import Combine
import UIKit
import UserNotifications
import CryptoKit
import Intents

// MARK: - Conversation state, message sending, handshake sending, fee estimation

extension ChatService {

    /// Async/background fetch variant that keeps Core Data page
    /// reads and decrypt work off the main actor. The final in-memory merge still happens on
    /// the main actor for published state consistency.
    /// Pulls the whole stored history of the open chat into memory in the background. The list
    /// then only ever grows its rendered window over messages already in memory - scrolling up
    /// never waits on a store read, and the top of the chat is there the moment the reader
    /// reaches it. The open conversation is exempt from the memory trim (see
    /// `trimMessagesForMemory`'s callers); `leaveConversation` trims it back once the chat is left.
    ///
    /// Gentle on purpose. It waits out the push animation, then reads pages off the main actor
    /// and merges them in batches of `fullHistoryMergeBatch` messages. It used to merge and
    /// publish `conversations` after every 500-message page, starting while the chat was still
    /// sliding in; each publish re-rendered the chat list underneath, every row in it and the
    /// open thread, and re-ran the thread's snapshot rebuild over the whole history - dozens of
    /// times over for a long chat, which is the lag right after opening one.
    private static let fullHistoryPageSize = 500
    private static let fullHistoryMergeBatch = 3_000

    // MARK: - Foreground contact sweep (defense-in-depth for live 1:1 delivery)

    /// Start the global foreground indexer sweep if it isn't already running. Mirrors desktop's
    /// 5s / Android's 2s foreground polls: while the app is active, walk the most recently active
    /// contacts one at a time calling `fetchContextualMessagesFromContact` (the same per-contact
    /// fetch the utxosChanged push and the open-chat poll use), ~5s between full sweeps.
    ///
    /// This is a backstop for any silent failure of the utxosChanged subscription, not the primary
    /// delivery path - so it is deliberately gentle: serial fetches with a short gap (never N
    /// concurrent requests), the next sweep starts only after the previous one finishes, the
    /// currently-open chat is skipped (`startActiveChatPoll` already covers it at 2s), nothing
    /// runs while a full sync is in flight or before the initial sync has completed, and a failed
    /// sweep doubles the interval (up to 60s) until a sweep succeeds again.
    ///
    /// Idempotent with every other fetch path: `fetchContextualMessagesFromContact` skips txIds
    /// already in the store and `addMessageToConversation` re-checks by txId at insert.
    func startForegroundContactSweep() {
        if let task = foregroundSweepTask, !task.isCancelled { return }
        guard WalletManager.shared.currentWallet != nil else { return }
        AppLog.log("[ChatService] Foreground contact sweep started (%.0fs, cap %d)",
                   currentForegroundSweepBaseInterval, foregroundSweepMaxContacts)
        foregroundSweepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Base interval resolves per iteration: 5s on WiFi, 15s on expensive
            // (cellular/metered) paths - the sweep is a backstop, not the primary path, so
            // cellular trades a little freshness for a third of the requests.
            var interval = self.currentForegroundSweepBaseInterval
            // Seed the group-catch-up clock: scenePhase .active just ran its own
            // GroupChatService.performCatchUpSync(), so the ride-along below should first
            // fire an interval from now, not duplicate that round trip immediately.
            self.lastForegroundGroupCatchUpAt = Date()
            while !Task.isCancelled {
                let swept = await self.runForegroundContactSweep()
                if Task.isCancelled { return }
                let base = self.currentForegroundSweepBaseInterval
                switch swept {
                case .failed:
                    let next = min(max(interval, base) * 2, self.foregroundSweepMaxInterval)
                    if next != interval {
                        AppLog.log("[ChatService] Foreground contact sweep backing off to %.0fs after indexer failure", next)
                    }
                    interval = next
                case .succeeded:
                    if interval != base {
                        AppLog.log("[ChatService] Foreground contact sweep recovered - back to %.0fs", base)
                    }
                    interval = base
                case .skipped:
                    break  // gated out (inactive / syncing / not ready) - keep the current interval
                }
                // Group-chat backstop (see `lastForegroundGroupCatchUpAt`): groups have no
                // per-contact sweep equivalent - their live path is the blockAdded block-scan,
                // and a block missed during a stream gap only got recovered on the next
                // app-foreground catch-up. Run the cursor-based group catch-up at most once a
                // minute while the app is active so an open app converges on missed group
                // messages without needing a background/foreground cycle.
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// The sweep's base interval for the current network path: `foregroundSweepBaseInterval`
    /// (5s) on WiFi, `foregroundSweepExpensiveInterval` (15s) on cellular/metered paths.
    private var currentForegroundSweepBaseInterval: TimeInterval {
        NetworkEpochMonitor.shared.isExpensivePath
            ? foregroundSweepExpensiveInterval
            : foregroundSweepBaseInterval
    }

    /// Cancel the foreground sweep (app backgrounded, wallet switch/teardown, logout).
    func stopForegroundContactSweep() {
        guard let task = foregroundSweepTask else { return }
        task.cancel()
        foregroundSweepTask = nil
        AppLog.log("[ChatService] Foreground contact sweep stopped")
    }

    enum ForegroundSweepOutcome {
        case succeeded
        case failed
        case skipped
    }

    /// One serial pass over the sweep targets. Returns `.failed` on the first indexer error (the
    /// rest of the pass is abandoned so an unreachable indexer costs one request per sweep, not
    /// one per contact), `.skipped` when gating kept it from doing any work.
    private func runForegroundContactSweep() async -> ForegroundSweepOutcome {
        guard UIApplication.shared.applicationState == .active,
              isConfigured,
              apiClient.hasIndexer,
              hasCompletedInitialSync,
              !isSyncInProgress,
              let wallet = WalletManager.shared.currentWallet,
              let privateKey = WalletManager.shared.getPrivateKey() else {
            return .skipped
        }
        // People writing to us for the first time, without a handshake (Message Requests). The
        // live subscription never sees these (the inbox tag is the indexer's), so this runs
        // whether or not it is healthy.
        await syncInbox()
        if Task.isCancelled { return .skipped }
        // The subscription delivers everything the rest of this sweep would find, within a second
        // or two, for as long as it is verified alive. The rest is for when it is not.
        guard !isUtxoSubscriptionHealthy else { return .skipped }
        let myAddress = wallet.publicAddress

        // Incoming handshakes first, and BEFORE the empty-targets guard below, because neither
        // the per-contact loop nor an empty target list can ever surface a first handshake:
        // `foregroundSweepTargets` only includes contacts that already have an incoming alias,
        // which is precisely what a first handshake creates, and a wallet with no contacts at all
        // would return early having polled nothing.
        if !(await sweepIncomingHandshakes(myAddress: myAddress, privateKey: privateKey)) {
            return .failed
        }
        if Task.isCancelled { return .skipped }

        let targets = nextForegroundSweepWindow(excluding: activeConversationAddress)
        guard !targets.isEmpty else { return .succeeded }

        for address in targets {
            if Task.isCancelled { return .skipped }
            // Re-check live conditions per contact: the app may have gone inactive or the user
            // may have opened this very chat mid-sweep (the open-chat poll owns it from then on).
            guard UIApplication.shared.applicationState == .active else { return .skipped }
            guard isActiveWallet(myAddress) else { return .skipped }
            if activeConversationAddress == address { continue }
            let result = await fetchContextualMessagesFromContact(
                contactAddress: address, myAddress: myAddress, privateKey: privateKey,
                reorgRewindMs: liveTailReorgBufferMs
            )
            if case .failure = result { return .failed }
            // Gentle pacing between contacts so a sweep is a trickle, not a burst.
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return .succeeded
    }

    /// One cursor-based incoming-handshake fetch per sweep pass (not per contact), so a
    /// handshake from someone who is not a contact yet appears while you sit on the chat list.
    ///
    /// Nothing periodic used to look for one. `fetchHandshakesOnly` runs once, as a startup
    /// bootstrap phase; the contact sweep is by definition blind to a first handshake; and the
    /// fallback poll only runs while the utxosChanged subscription is DOWN. So a stranger's
    /// handshake had exactly one live path - the utxosChanged notification's unknown-sender
    /// resolution - and every way that can come up empty (the payload not on the tx endpoint
    /// yet, the mempool entry already gone, the indexer a beat behind) left the handshake
    /// invisible until an app foreground cycle or a pull to refresh. Which is what it did.
    ///
    /// Android has always polled handshakes on every cycle of its own foreground loop
    /// (`ChatRepository.syncMessages` calls `syncHandshakes`); this is the iOS equivalent.
    ///
    /// Deliberately NOT `fetchHandshakesOnly`: that also fetches outgoing handshakes and runs the
    /// self-stash recovery scan from block time 0, which is a bootstrap's job, not a 5s poll's.
    /// Returns false on an indexer error so the sweep's own backoff applies.
    private func sweepIncomingHandshakes(myAddress: String, privateKey: Data?) async -> Bool {
        let key = handshakeSyncObjectKey(direction: "in", address: myAddress)
        let nowMs = currentTimeMs()
        let fallbackSince = lastPollTime > syncReorgBufferMs ? lastPollTime - syncReorgBufferMs : lastPollTime
        let since = syncStartBlockTime(for: key, fallbackBlockTime: fallbackSince, nowMs: nowMs)
        let incoming: [HandshakeResponse]
        do {
            incoming = try await fetchIncomingHandshakes(for: myAddress, blockTime: since)
        } catch {
            AppLog.log("[ChatService] Foreground handshake sweep failed: %@", error.localizedDescription)
            return false
        }
        // Advanced only on a successful fetch, so a failed pass re-asks the same window.
        advanceSyncCursor(for: key, maxBlockTime: incoming.compactMap { $0.blockTime }.max())
        guard !incoming.isEmpty else { return true }
        AppLog.log("[ChatService] Foreground sweep picked up %d incoming handshake(s)", incoming.count)
        // Idempotent: `processHandshakes` dedupes by txId, so re-serving the same handshake
        // across the cursor's reorg rewind costs nothing.
        await processHandshakes(incoming, isOutgoing: false, myAddress: myAddress, privateKey: privateKey)
        saveMessages()
        saveConversationAliases()
        return true
    }

    /// Whether the UTXO subscription is up and was verified alive recently enough to trust:
    /// subscribed on a primary whose last successful subscribe or keepalive ping is within
    /// `utxoSubscriptionFreshness`.
    var isUtxoSubscriptionHealthy: Bool {
        guard isUtxoSubscribed else { return false }
        let pool = NodePoolService.shared
        guard pool.subscriptionState == .subscribed, let healthyAt = pool.subscriptionLastHealthyAt else { return false }
        return Date().timeIntervalSince(healthyAt) < utxoSubscriptionFreshness
    }

    /// This pass's window: the `foregroundSweepPinnedContacts` most recently active contacts
    /// every time, then the next slice of everyone else, resuming where the last pass stopped.
    private func nextForegroundSweepWindow(excluding openAddress: String?) -> [String] {
        let ordered = foregroundSweepTargets(excluding: openAddress)
        guard ordered.count > foregroundSweepMaxContacts else {
            foregroundSweepRotationOffset = 0
            return ordered
        }
        let pinned = Array(ordered.prefix(foregroundSweepPinnedContacts))
        let rest = Array(ordered.dropFirst(foregroundSweepPinnedContacts))
        let sliceSize = foregroundSweepMaxContacts - pinned.count
        var slice: [String] = []
        var index = foregroundSweepRotationOffset % rest.count
        for _ in 0..<min(sliceSize, rest.count) {
            slice.append(rest[index])
            index = (index + 1) % rest.count
        }
        foregroundSweepRotationOffset = index
        return pinned + slice
    }

    /// Sweep target rule: active contacts that already have an incoming alias (no alias = no
    /// handshake yet = nothing to fetch, and `fetchContextualMessagesFromContact` would return
    /// early anyway), minus the currently-open chat, ordered by most recent activity
    /// (`Contact.lastMessageAt` desc, then newest-added first). `nextForegroundSweepWindow`
    /// cuts a pass's window out of this.
    private func foregroundSweepTargets(excluding openAddress: String?) -> [String] {
        let candidates = contactsManager.activeContacts.filter { contact in
            contact.address != openAddress && !incomingAliases(for: contact.address).isEmpty
        }
        let ordered = candidates.sorted { a, b in
            switch (a.lastMessageAt, b.lastMessageAt) {
            case let (la?, lb?) where la != lb: return la > lb
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.addedAt > b.addedAt
            }
        }
        return ordered.map { $0.address }
    }

    /// Fetch only handshakes (lightweight, needed to establish encryption keys)
    /// NOTE: Assumes configureAPIIfNeeded() was already called by startup flow
    func fetchHandshakesOnly() async {
        guard let wallet = WalletManager.shared.currentWallet else {
            AppLog.log("[ChatService] fetchHandshakesOnly: No wallet")
            return
        }

        guard isConfigured else {
            AppLog.log("[ChatService] fetchHandshakesOnly: API not configured")
            return
        }
        guard apiClient.hasIndexer else {
            AppLog.log("%@", "[ChatService] fetchHandshakesOnly: no indexer on this network, skipping")
            return
        }

        let nowMs = currentTimeMs()
        let fallbackSince = lastPollTime > syncReorgBufferMs ? lastPollTime - syncReorgBufferMs : lastPollTime
        let incomingHandshakeKey = handshakeSyncObjectKey(direction: "in", address: wallet.publicAddress)
        let outgoingHandshakeKey = handshakeSyncObjectKey(direction: "out", address: wallet.publicAddress)
        let incomingSince = syncStartBlockTime(
            for: incomingHandshakeKey,
            fallbackBlockTime: fallbackSince,
            nowMs: nowMs
        )
        let outgoingSince = syncStartBlockTime(
            for: outgoingHandshakeKey,
            fallbackBlockTime: fallbackSince,
            nowMs: nowMs
        )
        let privateKey = WalletManager.shared.getPrivateKey()

        AppLog.log("[ChatService] Fetching incoming handshakes (since=%llu)...", incomingSince)
        // Phase-isolated like fetchNewMessages: a failed bootstrap phase is logged and skipped,
        // the remaining phases still run, and Phase 4's full sync re-covers whatever was missed
        // (the failed phase's cursor never advanced).
        let incoming: [HandshakeResponse]
        if let fetched = await retryUntilSuccess(
            label: "fetch incoming handshakes (bootstrap)",
            operation: { [self] in try await fetchIncomingHandshakes(for: wallet.publicAddress, blockTime: incomingSince) }
        ) {
            incoming = fetched
            advanceSyncCursor(for: incomingHandshakeKey, maxBlockTime: fetched.compactMap { $0.blockTime }.max())
            AppLog.log("[ChatService] Fetched %d incoming handshakes", fetched.count)
        } else {
            incoming = []
            AppLog.log("[ChatService] Failed to fetch incoming handshakes - continuing bootstrap")
        }

        AppLog.log("[ChatService] Fetching outgoing handshakes...")

        let outgoing: [HandshakeResponse]
        if let fetched = await retryUntilSuccess(
            label: "fetch outgoing handshakes (bootstrap)",
            operation: { [self] in try await fetchOutgoingHandshakes(for: wallet.publicAddress, blockTime: outgoingSince) }
        ) {
            outgoing = fetched
            advanceSyncCursor(for: outgoingHandshakeKey, maxBlockTime: fetched.compactMap { $0.blockTime }.max())
            AppLog.log("[ChatService] Fetched %d outgoing handshakes", fetched.count)
        } else {
            outgoing = []
            AppLog.log("[ChatService] Failed to fetch outgoing handshakes - continuing bootstrap")
        }

        AppLog.log("[ChatService] Handshake bootstrap: %d incoming, %d outgoing", incoming.count, outgoing.count)

        // Process handshakes to extract aliases
        AppLog.log("[ChatService] Processing handshakes...")
        await processHandshakes(incoming, isOutgoing: false, myAddress: wallet.publicAddress, privateKey: privateKey)
        await processHandshakes(outgoing, isOutgoing: true, myAddress: wallet.publicAddress, privateKey: privateKey)
        AppLog.log("[ChatService] Handshakes processed")

        // Fetch saved handshakes from self-stash. Short retry budget: this recovery scan always
        // re-reads from block_time 0, so there is nothing to lose by giving up quickly, and the
        // ~60s default budget would delay Phase 2-4 (and thus the foreground sweep, gated on
        // hasCompletedInitialSync) by a minute while the endpoint is down.
        AppLog.log("[ChatService] Fetching saved handshakes from self-stash...")
        _ = await retryUntilSuccess(
            label: "fetch saved handshakes (bootstrap)",
            maxAttempts: Self.syncPhaseMaxRetryAttempts,
            operation: { [self] in try await fetchSavedHandshakes(myAddress: wallet.publicAddress, privateKey: privateKey) }
        )
        AppLog.log("[ChatService] Self-stash fetch complete")

        saveConversationAliases()
        saveOurAliases()
        saveConversationIds()
        saveRoutingStates()

        AppLog.log("[ChatService] Handshake bootstrap complete. Aliases: %d, Our aliases: %d, Routing: %d", conversationAliases.count, ourAliases.count, routingStates.count)
    }

    func fetchNewMessages(forActiveOnly activeAddress: String? = nil) async {
        guard let wallet = WalletManager.shared.currentWallet else {
            AppLog.log("%@", "[ChatService] Skipping fetch - no wallet")
            return
        }

        // Ensure API is configured
        await configureAPIIfNeeded()
        guard isConfigured else {
            AppLog.log("%@", "[ChatService] Skipping fetch - API not configured")
            return
        }
        guard apiClient.hasIndexer else {
            // Messages still arrive live over the node subscription; only the indexer catch-up
            // is skipped until this network gets an indexer address.
            AppLog.log("%@", "[ChatService] Skipping fetch - no indexer on this network")
            return
        }

        // Try to flush pending self-stash transactions if any
        await attemptPendingSelfStashSends()

        var activeFetchSucceeded = false
        if let active = activeAddress {
            setChatFetchState(.loading, for: active)
        } else if !isLoading {
            isLoading = true
        }
        beginSyncBlockTime()
        if !isSyncInProgress { isSyncInProgress = true }  // Enable batching for Core Data writes
        var syncSucceeded = false
        let shouldSuppressNotifications = activeAddress == nil && lastPollTime == 0
        let previousSuppress = suppressNotificationsUntilSynced
        if shouldSuppressNotifications {
            suppressNotificationsUntilSynced = true
        }
        defer {
            if shouldSuppressNotifications {
                suppressNotificationsUntilSynced = previousSuppress
            }
            if isSyncInProgress { isSyncInProgress = false }  // Disable batching before final save
            if let active = activeAddress {
                setChatFetchState(activeFetchSucceeded ? nil : .failed, for: active)
            }
            // Same-value writes still publish, re-rendering every observer.
            if isLoading { isLoading = false }
            // Check if resubscription was deferred during sync
            executeResubscriptionIfNeeded()
            endSyncBlockTime(success: syncSucceeded)  // This handles batched save
        }

        let isFullFetch = activeAddress == nil
        AppLog.log("%@", "[ChatService] Fetching messages for: \(wallet.publicAddress.suffix(10)), fullFetch=\(isFullFetch), lastPollTime=\(lastPollTime)")

        // Fetch handshakes first (they establish aliases) with per-object cursors.
        let nowMs = currentTimeMs()
        let fallbackSince = lastPollTime > syncReorgBufferMs ? lastPollTime - syncReorgBufferMs : lastPollTime
        let messageSince = applyMessageRetention(to: fallbackSince)
        let incomingHandshakeKey = handshakeSyncObjectKey(direction: "in", address: wallet.publicAddress)
        let outgoingHandshakeKey = handshakeSyncObjectKey(direction: "out", address: wallet.publicAddress)
        let incomingHandshakeSince = syncStartBlockTime(
            for: incomingHandshakeKey,
            fallbackBlockTime: fallbackSince,
            nowMs: nowMs
        )
        let outgoingHandshakeSince = syncStartBlockTime(
            for: outgoingHandshakeKey,
            fallbackBlockTime: fallbackSince,
            nowMs: nowMs
        )

        // PHASE ISOLATION: every fetch phase below is independent. A phase that exhausts its
        // (short) retry budget is logged and SKIPPED for this cycle only - its per-object cursor
        // simply doesn't advance, so the next cycle re-covers the missed window - and all the
        // phases behind it still run. One persistently failing endpoint (seen live: the indexer
        // 500ing /self-stash/by-owner mid-pagination) must never starve contextual message
        // delivery; the old guard-return coupling here is exactly why new messages only appeared
        // on pull-to-refresh while the saved-handshake fetch was failing. `allPhasesSucceeded`
        // stays false when any cursor-bearing phase failed, so endSyncBlockTime never advances
        // the global lastPollTime fallback cursor past an unfetched window.
        var allPhasesSucceeded = true

        let incoming: [HandshakeResponse]
        if let fetched = await retryUntilSuccess(
            label: "fetch incoming handshakes",
            maxAttempts: Self.syncPhaseMaxRetryAttempts,
            operation: { [self] in try await fetchIncomingHandshakes(for: wallet.publicAddress, blockTime: incomingHandshakeSince) }
        ) {
            incoming = fetched
            advanceSyncCursor(for: incomingHandshakeKey, maxBlockTime: fetched.compactMap { $0.blockTime }.max())
        } else {
            incoming = []
            allPhasesSucceeded = false
            AppLog.log("%@", "[ChatService] Incoming handshake phase skipped this cycle - continuing with remaining phases")
        }

        let outgoing: [HandshakeResponse]
        if let fetched = await retryUntilSuccess(
            label: "fetch outgoing handshakes",
            maxAttempts: Self.syncPhaseMaxRetryAttempts,
            operation: { [self] in try await fetchOutgoingHandshakes(for: wallet.publicAddress, blockTime: outgoingHandshakeSince) }
        ) {
            outgoing = fetched
            advanceSyncCursor(for: outgoingHandshakeKey, maxBlockTime: fetched.compactMap { $0.blockTime }.max())
        } else {
            outgoing = []
            allPhasesSucceeded = false
            AppLog.log("%@", "[ChatService] Outgoing handshake phase skipped this cycle - continuing with remaining phases")
        }

        // First contact without a handshake (Message Requests) - its own cursor, its own phase.
        if activeAddress == nil {
            await syncInbox()
        }

        var inPayments: [PaymentResponse] = []
        var outPayments: [PaymentResponse] = []
        // Fetch payments only on full fetch AND when not using UTXO subscription (or on initial
        // sync when lastPaymentFetchTime is 0, or when a payment may have been missed while the
        // subscription was paused, dead, or a live lookup gave up - `paymentCatchUpSince`)
        let catchUpSince = paymentCatchUpSince
        let shouldFetchPayments = activeAddress == nil && (!isUtxoSubscribed || lastPaymentFetchTime == 0 || catchUpSince != nil)
        let paymentSince = min(messageSince, catchUpSince ?? messageSince)
        var paymentsPhaseSucceeded = true
        if shouldFetchPayments {
            AppLog.log("[ChatService] === FETCHING PAYMENTS (full fetch, utxoSubscribed=%d) ===", isUtxoSubscribed ? 1 : 0)
            if let incomingPayments = await retryUntilSuccess(
                label: "fetch incoming payments",
                maxAttempts: Self.syncPhaseMaxRetryAttempts,
                operation: { [self] in try await fetchIncomingPayments(for: wallet.publicAddress, blockTime: paymentSince) }
            ) {
                inPayments = incomingPayments
            } else {
                paymentsPhaseSucceeded = false
                allPhasesSucceeded = false
                AppLog.log("%@", "[ChatService] Incoming payment phase skipped this cycle - continuing with remaining phases")
            }

            if let outgoingPayments = await retryUntilSuccess(
                label: "fetch outgoing payments",
                maxAttempts: Self.syncPhaseMaxRetryAttempts,
                operation: { [self] in try await fetchOutgoingPayments(for: wallet.publicAddress, blockTime: paymentSince) }
            ) {
                outPayments = outgoingPayments
            } else {
                paymentsPhaseSucceeded = false
                allPhasesSucceeded = false
                AppLog.log("%@", "[ChatService] Outgoing payment phase skipped this cycle - continuing with remaining phases")
            }
            AppLog.log("[ChatService] === PAYMENT FETCH COMPLETE: in=%d, out=%d ===", inPayments.count, outPayments.count)

            // Update last payment fetch time for UTXO subscription - only when BOTH payment
            // fetches actually succeeded. Advancing this cursor (or setting the initial-sync
            // baseline) off a failed fetch would permanently skip the unfetched window.
            if paymentsPhaseSucceeded {
                // caught up: a gap that opened during this fetch would have set a later one
                if paymentCatchUpSince == catchUpSince { paymentCatchUpSince = nil }
                if !inPayments.isEmpty || !outPayments.isEmpty {
                    let maxInTime = inPayments.compactMap { $0.blockTime }.max() ?? 0
                    let maxOutTime = outPayments.compactMap { $0.blockTime }.max() ?? 0
                    lastPaymentFetchTime = max(maxInTime, maxOutTime, lastPaymentFetchTime)
                } else if lastPaymentFetchTime == 0 {
                    // Set to current time if no payments found on initial sync
                    lastPaymentFetchTime = fallbackSince > 0 ? fallbackSince : UInt64(Date().timeIntervalSince1970 * 1000)
                }
            }
        } else if activeAddress != nil {
            AppLog.log("[ChatService] Skipping payment fetch - active conversation only")
        } else {
            AppLog.log("[ChatService] Skipping payment fetch - UTXO subscription active")
        }

        AppLog.log("[ChatService] Fetched: %d incoming handshakes, %d outgoing handshakes", incoming.count, outgoing.count)
        if shouldFetchPayments {
            AppLog.log("[ChatService] Fetched: %d incoming payments, %d outgoing payments", inPayments.count, outPayments.count)
        }

        // The fetches above cross many network `await`s. If the user switched/imported a different
        // wallet in that window, applying these results now would write the previous wallet's
        // messages into the new wallet's store. Bail out before touching any shared state.
        guard isActiveWallet(wallet.publicAddress) else {
            AppLog.log("%@", "[ChatService] Wallet changed mid-sync - discarding stale results for \(wallet.publicAddress.suffix(10))")
            return
        }

        // Get private key for decryption
        let privateKey = WalletManager.shared.getPrivateKey()

        // Process handshakes - this extracts aliases
        await processHandshakes(incoming, isOutgoing: false, myAddress: wallet.publicAddress, privateKey: privateKey)
        await processHandshakes(outgoing, isOutgoing: true, myAddress: wallet.publicAddress, privateKey: privateKey)
        if shouldFetchPayments {
            // Filter out handshake transactions from payment lists to prevent
            // handshakes being duplicated as payment messages (Bug 4: wallet re-import)
            let handshakeTxIds = Set(incoming.map { $0.txId } + outgoing.map { $0.txId })
            if !handshakeTxIds.isEmpty {
                let inBefore = inPayments.count
                let outBefore = outPayments.count
                inPayments = inPayments.filter { !handshakeTxIds.contains($0.txId) }
                outPayments = outPayments.filter { !handshakeTxIds.contains($0.txId) }
                let filtered = (inBefore - inPayments.count) + (outBefore - outPayments.count)
                if filtered > 0 {
                    AppLog.log("[ChatService] Filtered %d handshake txs from payment results", filtered)
                }
            }
            await processPayments(inPayments, isOutgoing: false, myAddress: wallet.publicAddress, privateKey: privateKey)
            await processPayments(outPayments, isOutgoing: true, myAddress: wallet.publicAddress, privateKey: privateKey)
        }

        // Fetch saved handshakes from self-stash to get our aliases for outgoing messages.
        // This is a self-healing RECOVERY scan, not a prerequisite for new-message delivery:
        // it always re-reads the self-stash from block_time 0 (no cursor to corrupt), so a
        // failed attempt loses nothing - the next cycle scans the exact same range. It must
        // never bail out of the sync: when the indexer persistently 5xxes this one endpoint,
        // the contextual-message phases below still have to run.
        if await retryUntilSuccess(
            label: "fetch saved handshakes",
            maxAttempts: Self.syncPhaseMaxRetryAttempts,
            operation: { [self] in try await fetchSavedHandshakes(myAddress: wallet.publicAddress, privateKey: privateKey) }
        ) == nil {
            AppLog.log("%@", "[ChatService] Saved-handshake phase skipped this cycle - continuing to contextual messages")
        }

        // Reclassify misidentified handshakes:
        // If self-stash confirms we have handshakes with a contact but conversation has
        // no handshake messages, the earliest payment is likely the handshake (Bug 4 fix)
        await reclassifyMisidentifiedHandshakes()
        purgeContractAddressPaymentChats()

        // Migrate legacy aliases to deterministic routing states (one-time)
        if let privKey = privateKey {
            migrateToDeterministicAliases(privateKey: privKey)
        }

        // Re-check ownership after the handshake/payment processing awaits, before the contextual
        // message fetch pulls and stores per-conversation history under this wallet.
        guard isActiveWallet(wallet.publicAddress) else {
            AppLog.log("%@", "[ChatService] Wallet changed mid-sync - skipping contextual fetch for \(wallet.publicAddress.suffix(10))")
            return
        }

        // Now fetch contextual messages for all known aliases
        // A summary, not the maps: the full dump wrote every contact's address into the device
        // log on every sync. It stays available behind Settings > Diagnostics > Verbose API Logging.
        func aliasSummary(_ map: [String: Set<String>]) -> String {
            let tags = map.values.reduce(0) { $0 + $1.count }
            let withExtras = map.values.filter { $0.count > 1 }.count
            return "\(map.count) contacts, \(tags) tags (\(withExtras) with legacy extras)"
        }
        AppLog.log("%@", "[ChatService] Aliases - incoming: \(aliasSummary(conversationAliases)); ours: \(aliasSummary(ourAliases)); routing states: \(routingStates.count)")
        if currentSettings.verboseAPILogging {
            AppLog.log("%@", "[ChatService] Current aliases: \(conversationAliases)")
            AppLog.log("%@", "[ChatService] Our aliases: \(ourAliases)")
        }
        if let active = activeAddress {
            let completed = await fetchContextualMessagesForActive(
                contactAddress: active,
                myAddress: wallet.publicAddress,
                privateKey: privateKey,
                fallbackSince: fallbackSince,
                nowMs: nowMs
            )
            activeFetchSucceeded = completed
            if !completed { allPhasesSucceeded = false }
        } else {
            let completed = await fetchContextualMessages(
                myAddress: wallet.publicAddress,
                privateKey: privateKey,
                fallbackSince: fallbackSince,
                nowMs: nowMs
            )
            if !completed { allPhasesSucceeded = false }
        }

        // A contextual pass can come back false because the wallet changed mid-fetch; never
        // persist this run's aliases/cursors into the new wallet's state in that case.
        guard isActiveWallet(wallet.publicAddress) else {
            AppLog.log("%@", "[ChatService] Wallet changed mid-sync - skipping finalization for \(wallet.publicAddress.suffix(10))")
            return
        }

        await retryIncomingWarningResolutionsOnSync(
            myAddress: wallet.publicAddress,
            privateKey: privateKey
        )

        // Note: saveMessages() is handled by defer block via endSyncBlockTime() to leverage batching
        // Only save metadata that doesn't go through MessageStore
        saveConversationAliases()
        saveOurAliases()
        saveConversationIds()
        saveRoutingStates()

        // Cycle-level success (advances the global lastPollTime fallback cursor via
        // endSyncBlockTime and drives connection status) requires every cursor-bearing phase to
        // have succeeded. The saved-handshake recovery scan is deliberately excluded: it always
        // re-scans from block_time 0, so skipping it has zero cursor cost and must not make an
        // otherwise-healthy cycle look failed while one indexer endpoint is broken.
        if allPhasesSucceeded {
            // Update last successful sync date for connection status
            lastSuccessfulSyncDate = Date()
            if isFullFetch {
                await apiClient.recordIndexerSyncSuccess()
            }
        }

        syncSucceeded = allPhasesSucceeded
        AppLog.log("%@", "[ChatService] Fetch complete (allPhases=\(allPhasesSucceeded ? "ok" : "partial")). Total conversations: \(conversations.count), lastPollTime updated to: \(lastPollTime)")
    }

    func getConversation(for contact: Contact) -> Conversation? {
        return conversations.first { $0.contact.id == contact.id }
    }

    /// Your chat with yourself - notes to self, and where messages from unknown senders land -
    /// exists for every account from the start and cannot be deleted: created here if missing
    /// (a new or freshly imported account has no messages to build it from), and any earlier
    /// deletion of it is undone. The chat list pins it first.
    func ensureSelfConversation() {
        guard let mine = WalletManager.shared.currentWallet?.publicAddress, !mine.isEmpty,
              isActiveWallet(mine) else { return }
        contactsManager.clearDeletionTombstone(mine)
        let contact = contactsManager.getOrCreateContact(address: mine)
        _ = getOrCreateConversation(for: contact)
    }

    func getOrCreateConversation(for contact: Contact) -> Conversation {
        if let existing = getConversation(for: contact) {
            return existing
        }

        let conversation = Conversation(contact: contact)
        conversations.append(conversation)
        markConversationDirty(contact.address)
        saveMessages()
        return conversation
    }

    func fetchSendUtxos(for walletAddress: String) async throws -> [UTXO] {
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([walletAddress])
        updateWalletBalanceIfNeeded(address: walletAddress, utxos: utxos)
        return utxos
    }

    func formatInsufficientBalanceError(plannedSpendSompi: UInt64, availableSompi: UInt64) -> KasiaError {
        let planned = formatKasAmount(plannedSpendSompi)
        let available = formatKasAmount(availableSompi)
        let template = KaspaUnit.label(AppLocalization.string("Planned spend %@ KAS, but available balance %@ KAS is less than required."))
        let message = String(format: template, locale: AppLocalization.locale, planned, available)
        return KasiaError.networkError(
            message
        )
    }

    func noSpendableFundsYetMessage() -> String {
        AppLocalization.string("No spendable funds available yet. Wait for confirmations and try again.")
    }

    func matchesLocalizedTemplate(_ message: String, key: String) -> Bool {
        let lowered = message.lowercased()
        let localized = KaspaUnit.label(AppLocalization.string(key)).lowercased()
        let segments = localized.components(separatedBy: "%@").filter { !$0.isEmpty }
        guard !segments.isEmpty else { return lowered == localized }

        var searchStart = lowered.startIndex
        for segment in segments {
            guard let range = lowered.range(of: segment, range: searchStart..<lowered.endIndex) else {
                return false
            }
            searchStart = range.upperBound
        }
        return true
    }

    func isInsufficientFundsError(_ error: Error) -> Bool {
        if case let KasiaError.networkError(message) = error {
            return message.lowercased().contains("insufficient funds")
        }
        return error.localizedDescription.lowercased().contains("insufficient funds")
    }

    func isInsufficientBalancePopupError(_ error: Error) -> Bool {
        if case let KasiaError.networkError(message) = error {
            return matchesLocalizedTemplate(
                message,
                key: "Planned spend %@ KAS, but available balance %@ KAS is less than required."
            )
        }
        return false
    }

    func shouldBypassBalancePrecheck(_ error: Error) -> Bool {
        guard case let KasiaError.networkError(message) = error else {
            return false
        }
        if isInsufficientBalancePopupError(error) {
            return false
        }

        let lowered = message.lowercased()
        return lowered.contains("timeout")
            || lowered.contains("connection")
            || lowered.contains("endpoint")
            || lowered.contains("no active nodes")
            || lowered.contains("all endpoints")
            || lowered.contains("unexpected response")
            || lowered.contains("all hedged requests failed")
            || lowered.contains("network path changed")
    }

    func addSompiSafely(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    func enqueueOutgoingTxOperation<T>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let previous = outgoingTxTail
        let operationTask = Task<T, Error> { @MainActor in
            if let previous {
                await previous.value
            }
            return try await operation()
        }
        outgoingTxTail = Task<Void, Never> { @MainActor in
            _ = try? await operationTask.value
        }
        return try await operationTask.value
    }

    func isNoConfirmedInputsError(_ error: Error) -> Bool {
        let localizedNoSpendableFunds = noSpendableFundsYetMessage().lowercased()
        if case let KasiaError.networkError(message) = error {
            let lowered = message.lowercased()
            return lowered.contains(localizedNoSpendableFunds)
                || lowered.contains("no spendable funds available yet")
                || lowered.contains("no confirmed spendable utxos available")
                || lowered.contains("no spendable utxos available")
                || lowered.contains("no utxos available")
        }
        let lowered = error.localizedDescription.lowercased()
        return lowered.contains(localizedNoSpendableFunds)
            || lowered.contains("no spendable funds available yet")
            || lowered.contains("no confirmed spendable utxos available")
            || lowered.contains("no spendable utxos available")
            || lowered.contains("no utxos available")
    }

    func nextNoInputRetryDelay(for pendingTxId: String) -> TimeInterval {
        let nextAttempt = (noInputRetryCounts[pendingTxId] ?? 0) + 1
        noInputRetryCounts[pendingTxId] = nextAttempt
        let base = min(60.0, pow(2.0, Double(max(0, nextAttempt - 1))))
        let jitter = Double.random(in: 0.10...0.35)
        return base + (base * jitter)
    }

    func clearNoInputRetryState(for pendingTxId: String?) {
        guard let pendingTxId else { return }
        noInputRetryCounts.removeValue(forKey: pendingTxId)
        scheduledSendRetries.remove(pendingTxId)
    }

    func shouldAttemptMessageUtxoCompaction(
        currentMessageTx: KaspaRpcTransaction,
        plannedFeeSompi: UInt64,
        singleInputFeeSompi: UInt64,
        availableUtxos: [UTXO]
    ) -> Bool {
        guard Date().timeIntervalSince(lastMessageCompactionAt) >= messageCompactionCooldown else {
            return false
        }
        let spendableCount = availableUtxos.filter { !$0.isCoinbase }.count
        guard spendableCount >= 2 else { return false }

        if currentMessageTx.inputs.count >= messageCompactionInputThreshold {
            return true
        }
        guard currentMessageTx.inputs.count > 1 else {
            return false
        }

        let extraFeeSompi = plannedFeeSompi > singleInputFeeSompi
            ? plannedFeeSompi - singleInputFeeSompi
            : 0
        return extraFeeSompi >= messageCompactionFeeThresholdSompi
    }

    func messageCompactionTargetOutputSompi(
        alias: String,
        content: String,
        recipientPublicKey: Data,
        senderScriptPubKey: Data
    ) -> UInt64 {
        let fallback = addSompiSafely(KasiaTransactionBuilder.dustThreshold, 30_000)
        guard let burstMultiplier = UInt64(exactly: messageCompactionTargetBurstMessages) else {
            return fallback
        }

        do {
            let payload = try KasiaTransactionBuilder.buildContextualMessagePayload(
                alias: alias,
                message: content,
                recipientPublicKey: recipientPublicKey
            )
            let singleInputFee = KasiaTransactionBuilder.estimateContextualMessageFee(
                payload: payload,
                inputCount: 1,
                senderScriptPubKey: senderScriptPubKey
            )
            let (burstTotal, overflow) = singleInputFee.multipliedReportingOverflow(by: burstMultiplier)
            let safeBurstTotal = overflow ? UInt64.max : burstTotal
            return addSompiSafely(KasiaTransactionBuilder.dustThreshold, safeBurstTotal)
        } catch {
            return fallback
        }
    }

    func autoCompactMessageUtxos(
        rpcManager: NodePoolService,
        walletAddress: String,
        privateKey: Data,
        senderScriptPubKey: Data,
        availableUtxos: [UTXO],
        minOutputAmount: UInt64
    ) async throws -> (txId: String, endpoint: String) {
        let spendableUtxos = availableUtxos.filter { !$0.isCoinbase }
        let compaction = try KasiaTransactionBuilder.buildMessageCompactionTx(
            from: walletAddress,
            senderPrivateKey: privateKey,
            utxos: spendableUtxos,
            minOutputAmount: minOutputAmount,
            maxInputs: messageCompactionMaxInputs
        )

        let usesUnconfirmedInputs = compaction.selectedUtxos.contains { $0.blockDaaScore == 0 }
        let submitted = try await rpcManager.submitTransaction(
            compaction.transaction,
            allowOrphan: usesUnconfirmedInputs
        )
        reserveMessageOutpoints(compaction.selectedUtxos)
        consumePendingUtxos(compaction.selectedUtxos)
        addPendingOutputs(from: compaction.transaction, txId: submitted.txId, senderScriptPubKey: senderScriptPubKey)
        lastMessageCompactionAt = Date()

        AppLog.log("[ChatService] Auto-compaction tx %@ submitted (inputs=%d, output=%llu, allowOrphan=%@)",
              String(submitted.txId.prefix(12)),
              compaction.selectedUtxos.count,
              compaction.outputAmount,
              usesUnconfirmedInputs ? "true" : "false")
        return submitted
    }

    func ensureSufficientBalanceForMessageSend(
        to contact: Contact,
        content: String,
        walletAddress: String,
        privateKey: Data
    ) async throws {
        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: walletAddress) else {
            throw KasiaError.invalidAddress
        }

        ensureRoutingState(for: contact.address, privateKey: privateKey)
        let alias = outgoingAlias(for: contact.address)
        let utxos = try await fetchSendUtxos(for: walletAddress)
        let availableUtxos = prepareMessageUtxos(confirmed: utxos)
        let confirmedSpendableTotal = utxos
            .filter { $0.blockDaaScore > 0 && !$0.isCoinbase }
            .reduce(UInt64(0)) { partial, utxo in
                addSompiSafely(partial, utxo.amount)
            }
        let availableBalance = availableUtxos.reduce(UInt64(0)) { partial, utxo in
            addSompiSafely(partial, utxo.amount)
        }
        let payload = try KasiaTransactionBuilder.buildContextualMessagePayload(
            alias: alias,
            message: content,
            recipientPublicKey: recipientPublicKey
        )
        let estimatedFee = KasiaTransactionBuilder.estimateContextualMessageFee(
            payload: payload,
            inputCount: 1,
            senderScriptPubKey: senderScriptPubKey
        )

        guard !availableUtxos.isEmpty else {
            if confirmedSpendableTotal > 0 {
                throw KasiaError.networkError(noSpendableFundsYetMessage())
            }
            throw formatInsufficientBalanceError(
                plannedSpendSompi: estimatedFee,
                availableSompi: availableBalance
            )
        }

        do {
            _ = try KasiaTransactionBuilder.buildContextualMessageTx(
                from: walletAddress,
                to: contact.address,
                alias: alias,
                message: content,
                senderPrivateKey: privateKey,
                recipientPublicKey: recipientPublicKey,
                utxos: availableUtxos
            )
        } catch {
            if isInsufficientFundsError(error) {
                throw formatInsufficientBalanceError(
                    plannedSpendSompi: estimatedFee,
                    availableSompi: availableBalance
                )
            }
            throw error
        }
    }

    func ensureSufficientBalanceForPaymentSend(
        to contact: Contact,
        amountSompi: UInt64,
        note: String,
        walletAddress: String,
        privateKey: Data
    ) async throws {
        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }
        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: contact.address),
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: walletAddress) else {
            throw KasiaError.invalidAddress
        }

        let utxos = try await fetchSendUtxos(for: walletAddress)
        let spendable = utxos.filter { $0.blockDaaScore > 0 && !$0.isCoinbase }
        let totalNonCoinbaseBalance = utxos
            .filter { !$0.isCoinbase }
            .reduce(UInt64(0)) { partial, utxo in
                addSompiSafely(partial, utxo.amount)
            }
        let availableBalance = spendable.reduce(UInt64(0)) { partial, utxo in
            addSompiSafely(partial, utxo.amount)
        }

        let paymentPayload = try KasiaTransactionBuilder.buildPaymentPayload(
            message: note,
            amount: amountSompi,
            recipientPublicKey: recipientPublicKey
        )
        let estimatedFee = (try? KasiaTransactionBuilder.estimatePaymentFee(
            utxos: spendable,
            payload: paymentPayload,
            amount: amountSompi,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey
        ))?.networkFee ?? KasiaTransactionBuilder.estimateSendAllFee(
            utxos: spendable,
            payload: paymentPayload,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey
        )
        let plannedSpend = addSompiSafely(amountSompi, estimatedFee)

        guard !spendable.isEmpty else {
            if totalNonCoinbaseBalance > 0 {
                throw KasiaError.networkError(noSpendableFundsYetMessage())
            }
            throw formatInsufficientBalanceError(
                plannedSpendSompi: plannedSpend,
                availableSompi: availableBalance
            )
        }

        do {
            _ = try KasiaTransactionBuilder.buildPaymentTx(
                from: walletAddress,
                to: contact.address,
                amount: amountSompi,
                note: note,
                senderPrivateKey: privateKey,
                recipientPublicKey: recipientPublicKey,
                utxos: spendable
            )
        } catch {
            if isInsufficientFundsError(error) {
                throw formatInsufficientBalanceError(
                    plannedSpendSompi: plannedSpend,
                    availableSompi: availableBalance
                )
            }
            throw error
        }
    }

    func ensureSufficientBalanceForHandshakeSend(
        to contact: Contact,
        isResponse: Bool,
        walletAddress: String,
        alias: String,
        conversationId: String?,
        privateKey: Data,
        recipientPublicKey: Data
    ) async throws {
        let utxos = try await fetchSendUtxos(for: walletAddress)
        let spendable = utxos.filter { $0.blockDaaScore > 0 && !$0.isCoinbase }
        let totalNonCoinbaseBalance = utxos
            .filter { !$0.isCoinbase }
            .reduce(UInt64(0)) { partial, utxo in
                addSompiSafely(partial, utxo.amount)
            }
        let (handshakeUtxos, _) = splitUtxosForHandshake(spendable)
        let availableBalance = handshakeUtxos.reduce(UInt64(0)) { partial, utxo in
            addSompiSafely(partial, utxo.amount)
        }
        let plannedSpend = KasiaTransactionBuilder.handshakeAmount

        guard !handshakeUtxos.isEmpty else {
            if totalNonCoinbaseBalance > 0 {
                throw KasiaError.networkError(noSpendableFundsYetMessage())
            }
            throw formatInsufficientBalanceError(
                plannedSpendSompi: plannedSpend,
                availableSompi: availableBalance
            )
        }

        do {
            _ = try KasiaTransactionBuilder.buildHandshakeTx(
                from: walletAddress,
                to: contact.address,
                alias: alias,
                conversationId: conversationId,
                isResponse: isResponse,
                senderPrivateKey: privateKey,
                recipientPublicKey: recipientPublicKey,
                utxos: handshakeUtxos
            )
        } catch {
            if isInsufficientFundsError(error) {
                throw formatInsufficientBalanceError(
                    plannedSpendSompi: plannedSpend,
                    availableSompi: availableBalance
                )
            }
            throw error
        }
    }

    func sendMessage(to contact: Contact, content: String, messageType: ChatMessage.MessageType = .contextual, feeOverride: UInt64? = nil) async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Writing to someone is consent: their chat is accepted, and a block on them lifts.
        acceptChat(contact.address)
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        // If replying, wrap the content in the shared reply envelope (matches public chats'
        // sendPublicChat) so the quote survives even if the original message is later pruned.
        // Never a call message: a call_invite/request/end sent while a reply was queued in the
        // chat went out as a reply, and the other phone never saw a call (the reply stays
        // queued for the person's next text).
        let isCallEnvelope = CallCodec.parseAny(trimmed) != nil
        let payload: String
        if let reply = replyingTo, !isCallEnvelope {
            let preview = MessageReplyCodec.previewText(for: reply.content)
            payload = MessageReplyCodec.encode(
                replyToId: reply.txId,
                replyToSender: reply.senderAddress,
                replyToPreview: preview,
                text: trimmed
            )
        } else {
            payload = trimmed
        }

        let pendingTxId = "pending_\(UUID().uuidString)"
        let pendingTimestamp = Date()
        let pendingMessage = ChatMessage(
            txId: pendingTxId,
            senderAddress: wallet.publicAddress,
            receiverAddress: contact.address,
            content: payload,
            timestamp: pendingTimestamp,
            blockTime: UInt64(pendingTimestamp.timeIntervalSince1970 * 1000),
            isOutgoing: true,
            messageType: messageType,
            deliveryStatus: .pending
        )
        addMessageToConversation(pendingMessage, contactAddress: contact.address)
        enqueuePendingOutgoing(contactAddress: contact.address, pendingTxId: pendingTxId, messageType: messageType, timestamp: pendingTimestamp)
        saveMessages()

        do {
            try await ensureSufficientBalanceForMessageSend(
                to: contact,
                content: payload,
                walletAddress: wallet.publicAddress,
                privateKey: privateKey
            )
        } catch {
            if isInsufficientBalancePopupError(error) {
                markPendingMessageFailed(pendingTxId, contactAddress: contact.address)
                throw error
            } else if isNoConfirmedInputsError(error) {
                AppLog.log("[ChatService] Message send precheck deferred: %@", error.localizedDescription)
            } else if shouldBypassBalancePrecheck(error) {
                AppLog.log("[ChatService] Message balance precheck unavailable, continuing send: %@", error.localizedDescription)
            } else {
                markPendingMessageFailed(pendingTxId, contactAddress: contact.address)
                throw error
            }
        }

        try await enqueueOutgoingTxOperation {
            try await self.sendMessageInternal(
                to: contact,
                content: payload,
                messageType: messageType,
                pendingTxId: pendingTxId,
                pendingMessageId: pendingMessage.id,
                feeOverride: feeOverride
            )
        }
        if !isCallEnvelope { replyingTo = nil }

        // Successful send: refresh the Share Extension's recents and donate an
        // INSendMessageIntent so iOS can surface this conversation as a share-sheet
        // direct target (requires IntentsSupported in the extension's Info.plist).
        SharedDataManager.recordRecentConversation(address: contact.address, alias: contact.alias)
        donateSendMessageIntent(for: contact)
    }

    /// Donates an INSendMessageIntent for this conversation. After a few donations iOS shows the
    /// conversation as a suggested direct target in the system share sheet; the Share Extension
    /// reads the donated `conversationIdentifier` (the contact address) back from
    /// `extensionContext.intent` to pre-select the contact.
    private func donateSendMessageIntent(for contact: Contact) {
        let trimmedAlias = contact.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedAlias.isEmpty ? Contact.generateDefaultAlias(from: contact.address) : trimmedAlias

        let recipient = INPerson(
            personHandle: INPersonHandle(value: contact.address, type: .unknown),
            nameComponents: nil,
            displayName: displayName,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: contact.address
        )

        let intent = INSendMessageIntent(
            recipients: [recipient],
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: INSpeakableString(spokenPhrase: displayName),
            conversationIdentifier: contact.address,
            serviceName: "KaChat",
            sender: nil,
            attachments: nil
        )

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.groupIdentifier = contact.address
        interaction.direction = .outgoing
        interaction.donate { error in
            if let error {
                AppLog.log("[ChatService] INSendMessageIntent donation failed: %@", error.localizedDescription)
            }
        }
    }

    func sendMessageInternal(
        to contact: Contact,
        content: String,
        messageType: ChatMessage.MessageType,
        pendingTxId: String?,
        pendingMessageId: UUID? = nil,
        spendableFundsRetryAttempt: Int = 0,
        feeOverride: UInt64? = nil
    ) async throws {
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }

        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        // Get recipient's public key from their address
        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }

        // "You start chatting back to someone who told you they are chatting with you": until
        // this very moment we had no routing state and no alias for them, so nothing they sent
        // us was ever queried (see recoverPreRelationshipHistory). Detect that transition BEFORE
        // ensureRoutingState creates the state, and pull their history in the background - the
        // send itself must not wait on a from-genesis fetch.
        let hadNoRelationship = routingStates[contact.address] == nil
            && (conversationAliases[contact.address]?.isEmpty ?? true)

        // Ensure routing state exists, then get our alias (deterministic preferred)
        ensureRoutingState(for: contact.address, privateKey: privateKey)
        let alias = outgoingAlias(for: contact.address)
        // First contact carries their inbox tag so they can find it (NO_HANDSHAKE_MESSAGING.md).
        let inboxTag = await firstContactInboxTag(for: contact.address)

        if hadNoRelationship {
            let recoveryAddress = contact.address
            Task { [weak self] in
                await self?.recoverPreRelationshipHistory(for: recoveryAddress)
            }
        }

        let resolvedPendingTxId = pendingTxId ?? "pending_\(UUID().uuidString)"
        var activePendingMessageId = pendingMessageId
        if pendingTxId == nil {
            let pendingTimestamp = Date()
            let pendingMessage = ChatMessage(
                txId: resolvedPendingTxId,
                senderAddress: wallet.publicAddress,
                receiverAddress: contact.address,
                content: content,
                timestamp: pendingTimestamp,
                blockTime: UInt64(pendingTimestamp.timeIntervalSince1970 * 1000),
                isOutgoing: true,
                messageType: messageType,
                deliveryStatus: .pending
            )
            // Animated publish: the outgoing bubble flows into the list (layout change +
            // the detail view's animated scroll ride the same transaction) - matching the
            // public chat room's send feel.
            withAnimation(.easeOut(duration: 0.25)) {
                addMessageToConversation(pendingMessage, contactAddress: contact.address)
            }
            enqueuePendingOutgoing(contactAddress: contact.address, pendingTxId: resolvedPendingTxId, messageType: messageType, timestamp: pendingTimestamp)
            activePendingMessageId = pendingMessage.id
        } else {
            resetPendingMessage(resolvedPendingTxId, contactAddress: contact.address)
        }
        saveMessages()

        let activePendingTxId = resolvedPendingTxId
        if activePendingMessageId == nil {
            activePendingMessageId = resolveMessageIdForPending(contactAddress: contact.address, pendingTxId: activePendingTxId)
        }
        if let activePendingMessageId {
            registerOutgoingAttempt(
                messageId: activePendingMessageId,
                pendingTxId: activePendingTxId,
                contactAddress: contact.address,
                messageType: messageType
            )
            markOutgoingAttemptSubmitting(messageId: activePendingMessageId)
        }

        /// The id this device computed for what it is about to submit (`acceptedTransactionId`).
        var builtTxId: String?
        do {
            // Connect to Kaspa node
            let rpcManager = NodePoolService.shared
            let settings = currentSettings

            AppLog.log("%@", "[ChatService] Starting message send to \(contact.address.suffix(10))")

            // Connect via gRPC manager
            if !rpcManager.isConnected {
                AppLog.log("%@", "[ChatService] RPC not connected, connecting...")
                try await rpcManager.connect(network: settings.networkType)
            } else {
                AppLog.log("%@", "[ChatService] RPC already connected")
            }

            // Fetch UTXOs for our address
            let utxos = try await rpcManager.getUtxosByAddresses([wallet.publicAddress])
            updateWalletBalanceIfNeeded(address: wallet.publicAddress, utxos: utxos)
            let availableUtxos = prepareMessageUtxos(confirmed: utxos)
            guard !availableUtxos.isEmpty else {
                let totalBalanceSompi = try utxos.totalAmount()
                if totalBalanceSompi == 0 {
                    AppLog.log("[ChatService] No confirmed UTXOs available - wallet balance is zero for %@",
                          String(activePendingTxId.prefix(12)))
                    throw KasiaError.networkError("Zero balance: add funds to your wallet and try again.")
                }

                AppLog.log("[ChatService] No confirmed spendable UTXOs available for %@",
                      String(activePendingTxId.prefix(12)))
                throw KasiaError.networkError(noSpendableFundsYetMessage())
            }

            AppLog.log("%@", "[ChatService] Found \(availableUtxos.count) available UTXOs for sending")

            let buildMessageTransaction: ([UTXO]) throws -> KaspaRpcTransaction = { candidateUtxos in
                try KasiaTransactionBuilder.buildContextualMessageTx(
                    from: wallet.publicAddress,
                    to: contact.address,
                    alias: alias,
                    message: content,
                    senderPrivateKey: privateKey,
                    recipientPublicKey: recipientPublicKey,
                    utxos: candidateUtxos,
                    feeOverride: feeOverride,
                    inboxTag: inboxTag
                )
            }

            var candidateUtxos = availableUtxos
            var transaction = try buildMessageTransaction(candidateUtxos)
            var spentUtxos = spentMessageUtxos(from: transaction, candidates: candidateUtxos)
            let initialMessageInputCount = transaction.inputs.count
            var totalInputSompi = spentUtxos.reduce(UInt64(0)) { partial, utxo in
                addSompiSafely(partial, utxo.amount)
            }
            var totalOutputSompi = transaction.outputs.reduce(UInt64(0)) { partial, output in
                addSompiSafely(partial, output.value)
            }
            var effectiveFeeSompi = totalInputSompi > totalOutputSompi
                ? totalInputSompi - totalOutputSompi
                : 0
            let singleInputFeeSompi = KasiaTransactionBuilder.estimateContextualMessageFee(
                payload: transaction.payload,
                inputCount: 1,
                senderScriptPubKey: senderScriptPubKey
            )

            if shouldAttemptMessageUtxoCompaction(
                currentMessageTx: transaction,
                plannedFeeSompi: effectiveFeeSompi,
                singleInputFeeSompi: singleInputFeeSompi,
                availableUtxos: candidateUtxos
            ) {
                let compactionTarget = messageCompactionTargetOutputSompi(
                    alias: alias,
                    content: content,
                    recipientPublicKey: recipientPublicKey,
                    senderScriptPubKey: senderScriptPubKey
                )
                var didSubmitCompaction = false
                do {
                    let compactionResult = try await autoCompactMessageUtxos(
                        rpcManager: rpcManager,
                        walletAddress: wallet.publicAddress,
                        privateKey: privateKey,
                        senderScriptPubKey: senderScriptPubKey,
                        availableUtxos: candidateUtxos,
                        minOutputAmount: compactionTarget
                    )
                    didSubmitCompaction = true
                    AppLog.log("%@", "[ChatService] Auto-compaction submitted: \(compactionResult.txId) via \(compactionResult.endpoint)")

                    candidateUtxos = prepareMessageUtxos(confirmed: utxos)
                    transaction = try buildMessageTransaction(candidateUtxos)
                    spentUtxos = spentMessageUtxos(from: transaction, candidates: candidateUtxos)
                    totalInputSompi = spentUtxos.reduce(UInt64(0)) { partial, utxo in
                        addSompiSafely(partial, utxo.amount)
                    }
                    totalOutputSompi = transaction.outputs.reduce(UInt64(0)) { partial, output in
                        addSompiSafely(partial, output.value)
                    }
                    effectiveFeeSompi = totalInputSompi > totalOutputSompi
                        ? totalInputSompi - totalOutputSompi
                        : 0
                    AppLog.log("[ChatService] Auto-compaction refreshed message inputs for %@: %d -> %d",
                          String(activePendingTxId.prefix(12)),
                          initialMessageInputCount,
                          transaction.inputs.count)
                } catch {
                    if didSubmitCompaction {
                        throw error
                    }
                    AppLog.log("[ChatService] Auto-compaction skipped for %@: %@",
                          String(activePendingTxId.prefix(12)),
                          error.localizedDescription)
                }
            }

            let usesUnconfirmedInputs = spentUtxos.contains { $0.blockDaaScore == 0 }
            let extraFeeSompi = effectiveFeeSompi > singleInputFeeSompi
                ? effectiveFeeSompi - singleInputFeeSompi
                : 0
            AppLog.log("[ChatService] Message tx plan %@: inputs=%d fee=%llu singleInputFee=%llu extra=%llu allowOrphan=%@",
                  String(activePendingTxId.prefix(12)),
                  transaction.inputs.count,
                  effectiveFeeSompi,
                  singleInputFeeSompi,
                  extraFeeSompi,
                  usesUnconfirmedInputs ? "true" : "false")

            let txId: String
            let endpoint: String
            do {
                builtTxId = KasiaTransactionBuilder.computeTransactionId(transaction)
                let submitted = try await rpcManager.submitTransaction(
                    transaction,
                    allowOrphan: usesUnconfirmedInputs
                )
                txId = submitted.txId
                endpoint = submitted.endpoint
            } catch {
                let signatureRejected = isSignatureRejection(error)
                if signatureRejected {
                    logSignatureRejection(pendingTxId: activePendingTxId, inputs: spentUtxos, senderScriptPubKey: senderScriptPubKey)
                    // a chained coin whose recorded amount or script is wrong would fail every retry
                    // until it expires: drop the pending coins this attempt used
                    consumePendingUtxos(spentUtxos.filter { $0.blockDaaScore == 0 })
                }
                let shouldFallbackToConfirmed = usesUnconfirmedInputs &&
                    (shouldRetrySendError(error) || shouldRetryNoSpendableFundsError(error) || signatureRejected)
                guard shouldFallbackToConfirmed else { throw error }

                let confirmedOnlyUtxos = candidateUtxos.filter { $0.blockDaaScore > 0 }
                guard !confirmedOnlyUtxos.isEmpty else { throw error }

                AppLog.log("[ChatService] Message submit fallback to confirmed-only inputs for %@",
                      String(activePendingTxId.prefix(12)))

                let confirmedOnlyTransaction = try buildMessageTransaction(confirmedOnlyUtxos)
                let confirmedOnlyInputs = confirmedOnlyTransaction.inputs.count
                if confirmedOnlyInputs > 2 {
                    AppLog.log("[ChatService] Skipping expensive confirmed-only fallback for %@ (inputs=%d)",
                          String(activePendingTxId.prefix(12)),
                          confirmedOnlyInputs)
                    throw error
                }

                transaction = confirmedOnlyTransaction
                spentUtxos = spentMessageUtxos(from: transaction, candidates: confirmedOnlyUtxos)

                builtTxId = KasiaTransactionBuilder.computeTransactionId(transaction)
                let submitted = try await rpcManager.submitTransaction(transaction, allowOrphan: false)
                txId = submitted.txId
                endpoint = submitted.endpoint
            }

            AppLog.log("%@", "[ChatService] Transaction submitted: \(txId) via \(endpoint)")
            // The one tagged first message is out - nothing after it to this address is tagged.
            if inboxTag != nil {
                updateChatRequests { $0.inboxTagged.insert(contact.address.lowercased()) }
            }

            reserveMessageOutpoints(spentUtxos)
            consumePendingUtxos(spentUtxos)
            addPendingOutputs(from: transaction, txId: txId, senderScriptPubKey: senderScriptPubKey)
            clearNoInputRetryState(for: activePendingTxId)

            // Update the pending message with the real transaction ID
            if let activePendingMessageId {
                _ = updatePendingMessageById(
                    activePendingMessageId,
                    newTxId: txId,
                    contactAddress: contact.address
                )
            } else {
                _ = updatePendingMessage(activePendingTxId, withRealTxId: txId, contactAddress: contact.address)
            }
            markOutgoingAttemptSubmitted(
                messageId: activePendingMessageId,
                pendingTxId: activePendingTxId,
                contactAddress: contact.address,
                messageType: messageType,
                txId: txId
            )

            // Store our alias for future messages
            addOurAlias(alias, for: contact.address, blockTime: nil)
            saveOurAliases()
            if conversationIds[contact.address] == nil, let pendingConvId = conversationIds["pending_\(contact.address)"] {
                conversationIds[contact.address] = pendingConvId
                conversationIds.removeValue(forKey: "pending_\(contact.address)")
                saveConversationIds()
            }

            saveMessages()

        } catch {
            releaseMessageOutpoints()
            if let acceptedTxId = acceptedTransactionId(from: error, expected: builtTxId) {
                AppLog.log("[ChatService] Message already accepted by consensus for %@ -> promoting pending to %@",
                      String(activePendingTxId.prefix(12)),
                      String(acceptedTxId.prefix(12)))
                if let activePendingMessageId {
                    _ = updatePendingMessageById(
                        activePendingMessageId,
                        newTxId: acceptedTxId,
                        contactAddress: contact.address
                    )
                } else {
                    _ = updatePendingMessage(activePendingTxId, withRealTxId: acceptedTxId, contactAddress: contact.address)
                }
                markOutgoingAttemptSubmitted(
                    messageId: activePendingMessageId,
                    pendingTxId: activePendingTxId,
                    contactAddress: contact.address,
                    messageType: messageType,
                    txId: acceptedTxId
                )
                clearNoInputRetryState(for: activePendingTxId)
                saveMessages()
                return
            }
            if shouldRetryNoSpendableFundsError(error),
               spendableFundsRetryAttempt < spendableFundsRetryAttempts {
                let retryNumber = spendableFundsRetryAttempt + 1
                let retryDelay = spendableFundsRetryDelay(for: retryNumber)
                if let jitterRatio = retryDelay.jitterRatio {
                    AppLog.log(
                        "[ChatService] Retrying send (no spendable funds) for %@ (%d/%d) in %.0fms (+%.0f%% jitter)",
                        String(activePendingTxId.prefix(12)),
                        retryNumber,
                        spendableFundsRetryAttempts,
                        retryDelay.seconds * 1000,
                        jitterRatio * 100
                    )
                } else {
                    AppLog.log(
                        "[ChatService] Retrying send (no spendable funds) for %@ (%d/%d) in %.0fms",
                        String(activePendingTxId.prefix(12)),
                        retryNumber,
                        spendableFundsRetryAttempts,
                        retryDelay.seconds * 1000
                    )
                }
                try await Task.sleep(nanoseconds: UInt64(retryDelay.seconds * 1_000_000_000))
                try await sendMessageInternal(
                    to: contact,
                    content: content,
                    messageType: messageType,
                    pendingTxId: activePendingTxId,
                    pendingMessageId: activePendingMessageId,
                    spendableFundsRetryAttempt: retryNumber
                )
                return
            }
            if shouldRetryNoSpendableFundsError(error) {
                let delay = nextNoInputRetryDelay(for: activePendingTxId)
                AppLog.log(
                    "[ChatService] Deferred retry (no confirmed inputs) for %@ in %.0fs",
                    String(activePendingTxId.prefix(12)),
                    delay
                )
                scheduleOutgoingRetry(
                    contact: contact,
                    pendingTxId: activePendingTxId,
                    pendingMessageId: activePendingMessageId,
                    messageType: messageType,
                    delaySeconds: delay
                )
                return
            }
            if shouldRetrySendError(error) {
                AppLog.log("[ChatService] Message send retry scheduled for %@: %@",
                      String(activePendingTxId.prefix(12)), error.localizedDescription)
                scheduleOutgoingRetry(
                    contact: contact,
                    pendingTxId: activePendingTxId,
                    pendingMessageId: activePendingMessageId,
                    messageType: messageType,
                    delaySeconds: 4
                )
                return
            }
            markOutgoingAttemptFailed(
                messageId: activePendingMessageId,
                pendingTxId: activePendingTxId
            )
            markPendingMessageFailed(activePendingTxId, contactAddress: contact.address)
            saveMessages()
            throw error
        }
    }

    func resolveMessageIdForPending(contactAddress: String, pendingTxId: String) -> UUID? {
        guard let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else {
            return nil
        }
        return conversations[convIndex].messages.first(where: { $0.txId == pendingTxId })?.id
    }

    func resolveMessageIdForTx(contactAddress: String, txId: String) -> UUID? {
        guard let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else {
            return nil
        }
        return conversations[convIndex].messages.first(where: { $0.txId == txId })?.id
    }

    func pruneOutgoingAttempts(now: Date = Date()) {
        let staleIds = outgoingAttemptsByMessageId.compactMap { messageId, attempt -> UUID? in
            if now.timeIntervalSince(attempt.updatedAt) > outgoingAttemptTTL {
                return messageId
            }
            return nil
        }

        for staleId in staleIds {
            guard let attempt = outgoingAttemptsByMessageId.removeValue(forKey: staleId) else { continue }
            outgoingAttemptByPendingTxId.removeValue(forKey: attempt.pendingTxId)
            if let txId = attempt.txId {
                outgoingAttemptByRealTxId.removeValue(forKey: txId)
            }
        }
    }

    func registerOutgoingAttempt(
        messageId: UUID,
        pendingTxId: String,
        contactAddress: String,
        messageType: ChatMessage.MessageType
    ) {
        pruneOutgoingAttempts()
        if let existing = outgoingAttemptsByMessageId[messageId] {
            outgoingAttemptByPendingTxId.removeValue(forKey: existing.pendingTxId)
            if let txId = existing.txId {
                outgoingAttemptByRealTxId.removeValue(forKey: txId)
            }
        }
        let now = Date()
        let attempt = OutgoingTxAttempt(
            messageId: messageId,
            pendingTxId: pendingTxId,
            contactAddress: contactAddress,
            messageType: messageType,
            txId: nil,
            phase: .queued,
            updatedAt: now
        )
        outgoingAttemptsByMessageId[messageId] = attempt
        outgoingAttemptByPendingTxId[pendingTxId] = messageId
    }

    func markOutgoingAttemptSubmitting(messageId: UUID?) {
        guard let messageId else { return }
        pruneOutgoingAttempts()
        guard var attempt = outgoingAttemptsByMessageId[messageId] else { return }
        attempt.phase = .submitting
        attempt.updatedAt = Date()
        outgoingAttemptsByMessageId[messageId] = attempt
    }

    func markOutgoingAttemptSubmitted(
        messageId: UUID?,
        pendingTxId: String,
        contactAddress: String,
        messageType: ChatMessage.MessageType,
        txId: String
    ) {
        pruneOutgoingAttempts()
        let resolvedMessageId = messageId
            ?? outgoingAttemptByPendingTxId[pendingTxId]
            ?? resolveMessageIdForTx(contactAddress: contactAddress, txId: txId)
            ?? resolveMessageIdForPending(contactAddress: contactAddress, pendingTxId: pendingTxId)

        guard let resolvedMessageId else { return }

        if let existing = outgoingAttemptsByMessageId[resolvedMessageId] {
            outgoingAttemptByPendingTxId.removeValue(forKey: existing.pendingTxId)
            if let existingTxId = existing.txId {
                outgoingAttemptByRealTxId.removeValue(forKey: existingTxId)
            }
        }

        let attempt = OutgoingTxAttempt(
            messageId: resolvedMessageId,
            pendingTxId: pendingTxId,
            contactAddress: contactAddress,
            messageType: messageType,
            txId: txId,
            phase: .submitted,
            updatedAt: Date()
        )
        outgoingAttemptsByMessageId[resolvedMessageId] = attempt
        outgoingAttemptByRealTxId[txId] = resolvedMessageId
    }

    func markOutgoingAttemptFailed(messageId: UUID?, pendingTxId: String?) {
        pruneOutgoingAttempts()

        if let messageId,
           let existing = outgoingAttemptsByMessageId.removeValue(forKey: messageId) {
            outgoingAttemptByPendingTxId.removeValue(forKey: existing.pendingTxId)
            if let existingTxId = existing.txId {
                outgoingAttemptByRealTxId.removeValue(forKey: existingTxId)
            }
            return
        }

        if let pendingTxId,
           let mappedMessageId = outgoingAttemptByPendingTxId.removeValue(forKey: pendingTxId),
           let existing = outgoingAttemptsByMessageId.removeValue(forKey: mappedMessageId),
           let existingTxId = existing.txId {
            outgoingAttemptByRealTxId.removeValue(forKey: existingTxId)
        }
    }

    func hasInFlightOutgoingAttemptWithoutTxId(for contactAddress: String) -> Bool {
        pruneOutgoingAttempts()
        return outgoingAttemptsByMessageId.values.contains {
            $0.contactAddress == contactAddress &&
            $0.txId == nil &&
            ($0.phase == .queued || $0.phase == .submitting)
        }
    }

    func isKnownOutgoingAttemptTxId(_ txId: String) -> Bool {
        pruneOutgoingAttempts()
        return outgoingAttemptByRealTxId[txId] != nil
    }

    func shouldDeferClassification(
        txId: String,
        txAddedAddresses: Set<String>,
        contactAddresses: Set<String>
    ) -> Bool {
        if isKnownOutgoingAttemptTxId(txId) {
            return false
        }

        let touchedContacts = txAddedAddresses.intersection(contactAddresses)
        guard !touchedContacts.isEmpty else { return false }

        for contact in touchedContacts {
            if hasInFlightOutgoingAttemptWithoutTxId(for: contact) {
                return true
            }
        }
        return false
    }

    func promoteKnownOutgoingAttempt(contactAddress: String, newTxId: String) -> Bool {
        pruneOutgoingAttempts()

        if let attemptId = outgoingAttemptByRealTxId[newTxId],
           let existing = outgoingAttemptsByMessageId[attemptId],
           existing.contactAddress == contactAddress {
            return true
        }

        let candidate = outgoingAttemptsByMessageId.values
            .filter {
                $0.contactAddress == contactAddress &&
                $0.txId == nil &&
                ($0.phase == .queued || $0.phase == .submitting)
            }
            .sorted { $0.updatedAt < $1.updatedAt }
            .first

        if let candidate,
           updatePendingMessageById(candidate.messageId, newTxId: newTxId, contactAddress: contactAddress) {
            markOutgoingAttemptSubmitted(
                messageId: candidate.messageId,
                pendingTxId: candidate.pendingTxId,
                contactAddress: contactAddress,
                messageType: candidate.messageType,
                txId: newTxId
            )
            saveMessages()
            return true
        }

        if updatePendingFromQueue(contactAddress: contactAddress, newTxId: newTxId, messageType: .payment) ||
            updateOldestPendingOutgoingMessage(contactAddress: contactAddress, newTxId: newTxId, messageType: .payment) {
            return true
        }

        return false
    }

    func outpointKey(_ outpoint: UTXO.Outpoint) -> String {
        "\(outpoint.transactionId):\(outpoint.index)"
    }

    func spentMessageUtxos(from transaction: KaspaRpcTransaction, candidates: [UTXO]) -> [UTXO] {
        let spentKeys = Set(transaction.inputs.map { outpointKey($0.previousOutpoint) })
        return candidates.filter { spentKeys.contains(outpointKey($0.outpoint)) }
    }

    func prepareMessageUtxos(confirmed: [UTXO]) -> [UTXO] {
        _ = unresolvedSends // after a relaunch, puts back the holds of "Not confirmed" sends
        let now = Date()
        pruneMessageUtxoCaches(confirmed: confirmed, now: now)
        let confirmedSpendable = confirmed
            .filter { $0.blockDaaScore > 0 && !$0.isCoinbase }
        // A pending coin is only ever signed by the chatting key, so only coins locked to the
        // chatting address may be offered. The cache is shared and outlives an account switch;
        // a coin locked to another address, signed with this key, is rejected by the network
        // ("false stack entry at end of script execution"). The script was written by
        // `addPendingOutputs` from `KaspaAddress.scriptPublicKey(from:)`, so it compares exactly.
        let chattingScript = WalletManager.shared.currentWallet.flatMap { KaspaAddress.scriptPublicKey(from: $0.publicAddress) }
        let pendingSpendable = pendingMessageUtxos.values
            .map(\.utxo)
            .filter { !$0.isCoinbase && (chattingScript == nil || $0.scriptPublicKey == chattingScript) }

        var merged: [UTXO] = []
        var seenOutpoints = Set<String>()
        for utxo in pendingSpendable + confirmedSpendable {
            let key = outpointKey(utxo.outpoint)
            guard reservedMessageOutpoints[key] == nil else { continue }
            guard seenOutpoints.insert(key).inserted else { continue }
            merged.append(utxo)
        }
        return merged
    }

    func pruneMessageUtxoCaches(confirmed: [UTXO], now: Date) {
        reservedMessageOutpoints = reservedMessageOutpoints.filter { $0.value > now }
        let confirmedKeys = Set(confirmed.map { outpointKey($0.outpoint) })
        pendingMessageUtxos = pendingMessageUtxos.filter { key, entry in
            entry.expiresAt > now && !confirmedKeys.contains(key)
        }
    }

    func reserveMessageOutpoints(_ utxos: [UTXO]) {
        let expiration = Date().addingTimeInterval(pendingMessageUtxoTTL)
        for utxo in utxos {
            reservedMessageOutpoints[outpointKey(utxo.outpoint)] = expiration
        }
    }

    /// A submitted transaction's inputs, held for every send in the app (`NodePoolService` calls
    /// this on a send and on an unknown outcome), so nothing picks those coins again before the node
    /// shows them spent. As in KaChat.
    func reserveSpentOutpoints(_ outpoints: [UTXO.Outpoint]) {
        let expiration = Date().addingTimeInterval(pendingMessageUtxoTTL)
        for outpoint in outpoints {
            let key = outpointKey(outpoint)
            if let until = reservedMessageOutpoints[key], until > expiration { continue }
            reservedMessageOutpoints[key] = expiration
            pendingMessageUtxos.removeValue(forKey: key)
        }
    }

    func consumePendingUtxos(_ utxos: [UTXO]) {
        for utxo in utxos {
            pendingMessageUtxos.removeValue(forKey: outpointKey(utxo.outpoint))
        }
    }

    func addPendingOutputs(from transaction: KaspaRpcTransaction, txId: String, senderScriptPubKey: Data) {
        let expiration = Date().addingTimeInterval(pendingMessageUtxoTTL)
        for (index, output) in transaction.outputs.enumerated() {
            guard output.scriptPublicKey.script == senderScriptPubKey else { continue }
            let utxo = UTXO(
                address: "",
                outpoint: UTXO.Outpoint(transactionId: txId, index: UInt32(index)),
                amount: output.value,
                scriptPublicKey: senderScriptPubKey,
                blockDaaScore: 0,
                isCoinbase: false
            )
            pendingMessageUtxos[outpointKey(utxo.outpoint)] = (utxo, expiration)
        }
    }

    func releaseMessageOutpoints() {
        let now = Date()
        reservedMessageOutpoints = reservedMessageOutpoints.filter { $0.value > now }
        pendingMessageUtxos = pendingMessageUtxos.filter { $0.value.expiresAt > now }
    }

    /// The node refused an input's signature (kaspad "failed to verify the signature script").
    func isSignatureRejection(_ error: Error) -> Bool {
        error.localizedDescription.lowercased().contains("signature script")
    }

    /// Every input of a rejected message, so a signature failure names its coin: amount, whether
    /// it was pending (a chained change output) or confirmed, and whether its script is the
    /// sender's own.
    func logSignatureRejection(pendingTxId: String, inputs: [UTXO], senderScriptPubKey: Data) {
        AppLog.log("[ChatService] Signature rejected for %@ - %d input(s):", String(pendingTxId.prefix(12)), inputs.count)
        for (index, utxo) in inputs.enumerated() {
            AppLog.log("[ChatService]   input %d %@:%d amount=%llu %@ script=%@ coinbase=%@",
                       index, String(utxo.outpoint.transactionId.prefix(16)), Int(utxo.outpoint.index), utxo.amount,
                       utxo.blockDaaScore == 0 ? "PENDING" : "confirmed",
                       utxo.scriptPublicKey == senderScriptPubKey ? "sender" : "OTHER(\(utxo.scriptPublicKey.count)B)",
                       utxo.isCoinbase ? "yes" : "no")
        }
    }

    func shouldRetrySendError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("orphan") || message.contains("already spent")
    }

    func shouldRetryNoSpendableFundsError(_ error: Error) -> Bool {
        isNoConfirmedInputsError(error)
    }

    func spendableFundsRetryDelay(for retryNumber: Int) -> (seconds: TimeInterval, jitterRatio: Double?) {
        let normalizedRetry = max(1, retryNumber)
        let baseDelay = spendableFundsRetryBaseDelay * pow(2.0, Double(normalizedRetry - 1))
        guard normalizedRetry > 2 else {
            return (baseDelay, nil)
        }

        let jitterRatio = Double.random(in: 0.10...0.40)
        let jitterDelay = baseDelay * jitterRatio
        return (baseDelay + jitterDelay, jitterRatio)
    }

    /// The id a node's "already accepted" rejection names. Nodes are unauthenticated, so that text is
    /// only trusted when it names the transaction this device built (`expected`): any node could
    /// send it with a made-up id and make an unpaid send look paid. Same as KaPost.
    func acceptedTransactionId(from error: Error, expected: String?) -> String? {
        let message = error.localizedDescription
        guard message.lowercased().contains("already accepted by the consensus"),
              let named = extractLikelyTxId(from: message) else { return nil }
        guard let expected, named.lowercased() == expected.lowercased() else {
            AppLog.log("[ChatService] ignored an \"already accepted\" answer naming another transaction")
            return nil
        }
        return named
    }

    func extractLikelyTxId(from text: String) -> String? {
        if let txIdAfterKeyword = extractTxId(after: "transaction", in: text) {
            return txIdAfterKeyword
        }
        return extractFirstHex64(in: text)
    }

    func extractTxId(after keyword: String, in text: String) -> String? {
        let lowered = text.lowercased()
        guard let range = lowered.range(of: keyword) else { return nil }
        let tail = String(lowered[range.upperBound...])
        return extractFirstHex64AllowingWhitespace(in: tail)
    }

    func extractFirstHex64(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "[0-9a-fA-F]{64}") else { return nil }
        let full = text as NSString
        let range = NSRange(location: 0, length: full.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return full.substring(with: match.range).lowercased()
    }

    func extractFirstHex64AllowingWhitespace(in text: String) -> String? {
        // Some node errors wrap txId across newlines/spaces. Accept and compact it.
        guard let regex = try? NSRegularExpression(pattern: "([0-9a-fA-F][0-9a-fA-F\\s]{63,200})") else { return nil }
        let full = text as NSString
        let range = NSRange(location: 0, length: full.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        let raw = full.substring(with: match.range)
        let compact = raw.filter { $0.isHexDigit }
        guard compact.count >= 64 else { return nil }
        return String(compact.prefix(64)).lowercased()
    }

    func scheduleOutgoingRetry(
        contact: Contact,
        pendingTxId: String,
        pendingMessageId: UUID?,
        messageType: ChatMessage.MessageType,
        delaySeconds: TimeInterval,
        paymentAmountSompi: UInt64? = nil,
        paymentNote: String = "",
        /// The spending address a payment was asked to come from (see `sendPayment`).
        paymentSourceIndex: Int? = nil,
        /// The payment's extra (Fast / Priority / custom) fee and coin-control selection.
        paymentExtraFeeSompi: UInt64 = 0,
        paymentManualUtxos: [UTXO]? = nil,
        handshakeIsResponse: Bool? = nil
    ) {
        guard !scheduledSendRetries.contains(pendingTxId) else { return }
        scheduledSendRetries.insert(pendingTxId)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let self else { return }
            self.scheduledSendRetries.remove(pendingTxId)
            guard let convIndex = self.conversations.firstIndex(where: { $0.contact.address == contact.address }),
                  let message = self.conversations[convIndex].messages.first(where: { $0.txId == pendingTxId || $0.id == pendingMessageId }) else {
                self.clearNoInputRetryState(for: pendingTxId)
                return
            }
            guard message.deliveryStatus != .sent else {
                self.clearNoInputRetryState(for: pendingTxId)
                return
            }

            let retryPendingTxId = message.txId
            let retryPendingMessageId = message.id
            do {
                try await self.enqueueOutgoingTxOperation {
                    switch messageType {
                    case .contextual, .audio:
                        try await self.sendMessageInternal(
                            to: contact,
                            content: message.content,
                            messageType: messageType,
                            pendingTxId: retryPendingTxId,
                            pendingMessageId: retryPendingMessageId
                        )
                    case .payment:
                        guard let paymentAmountSompi else { return }
                        try await self.sendPaymentInternal(
                            to: contact,
                            amountSompi: paymentAmountSompi,
                            note: paymentNote,
                            pendingTxId: retryPendingTxId,
                            extraFeeSompi: paymentExtraFeeSompi,
                            sourceSpendingIndex: paymentSourceIndex,
                            manualUtxos: paymentManualUtxos
                        )
                    case .handshake:
                        let isResponse = handshakeIsResponse ?? self.shouldRetryHandshakeAsResponse(for: contact.address)
                        try await self.sendHandshakeInternal(
                            to: contact,
                            isResponse: isResponse,
                            pendingTxId: retryPendingTxId
                        )
                    }
                }
            } catch {
                // Individual send handlers decide whether to reschedule or fail.
            }
        }
    }

    @discardableResult
    func sendPaymentInternal(
        to contact: Contact,
        amountSompi: UInt64,
        note: String = "",
        pendingTxId: String? = nil,
        /// Extra priority fee (Fast/Priority tiers) on top of the computed base fee.
        extraFeeSompi: UInt64 = 0,
        sourceSpendingIndex: Int? = nil,
        manualUtxos: [UTXO]? = nil,
        tip: KaPostTip? = nil
    ) async throws -> String? {
        guard amountSompi > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }
        // A tip stays a tip on a retry (which knows only the pending id), and is always paid
        // from the chatting address.
        let tip = tip ?? pendingTxId.flatMap { pendingTips[$0] }
        let sourceSpendingIndex = tip == nil ? sourceSpendingIndex : nil
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        // FUNDING SOURCE - keyed on the per-account Chats Payment Privacy toggle:
        //
        // The From the person chose: the chatting address (nil, the default) - funded with the
        // identity key, change back to it - or one of their spending addresses, whose change goes
        // to a never-used address (revealed in Manage Addresses). Estimators must agree - see
        // `paymentFundingSourceAddress`.
        let sourceAddress: String
        let sourcePrivateKey: Data
        let changeAddress: String?
        let freshChangeIndex: Int?
        if let spendingIndex = sourceSpendingIndex {
            guard let spendingAddress = WalletManager.shared.spendingAddress(at: spendingIndex),
                  let spendingPrivateKey = WalletManager.shared.spendingPrivateKey(at: spendingIndex) else {
                throw KasiaError.keychainError("Could not derive spending address")
            }
            // Change always lands on a brand-new quantum-safe slot (KIP-22): never an address
            // used before, and its key stays hidden until IT spends.
            // Slot and address from the account the source was derived from (IOS-109).
            let slot = await WalletManager.shared.verifiedFreshQuantumSlot()
            // A quantum source's spend reveals its key: change back to it would park funds on a
            // revealed key (IOS-104). A legacy source may still fall back to itself.
            if slot == nil, WalletManager.isQuantumIndex(spendingIndex) {
                throw KasiaError.keychainError(AppLocalization.string("Couldn't prepare the next address. Try again."))
            }
            sourceAddress = spendingAddress
            sourcePrivateKey = spendingPrivateKey
            changeAddress = slot?.address
            freshChangeIndex = slot?.index
        } else {
            guard let identityKey = WalletManager.shared.getPrivateKey() else {
                throw KasiaError.keychainError("Could not get private key")
            }
            sourceAddress = wallet.publicAddress
            sourcePrivateKey = identityKey
            changeAddress = nil
            freshChangeIndex = nil
        }
        let fromChattingAddress = sourceSpendingIndex == nil

        if pendingTxId == nil {
            do {
                try await ensureSufficientBalanceForPaymentSend(
                    to: contact,
                    amountSompi: amountSompi,
                    note: note,
                    walletAddress: sourceAddress,
                    privateKey: sourcePrivateKey
                )
            } catch {
                if isInsufficientBalancePopupError(error) {
                    throw error
                } else if isNoConfirmedInputsError(error) {
                    AppLog.log("[ChatService] Payment send precheck deferred: %@", error.localizedDescription)
                } else if shouldBypassBalancePrecheck(error) {
                    AppLog.log("[ChatService] Payment balance precheck unavailable, continuing send: %@", error.localizedDescription)
                } else {
                    throw error
                }
            }
        }

        let activePendingTxId = pendingTxId ?? "pending_\(UUID().uuidString)"
        if let tip { pendingTips[activePendingTxId] = tip }
        let pendingMessageId: UUID
        if pendingTxId == nil {
            let formattedAmount = formatKasAmount(amountSompi)
            let pendingTimestamp = Date()
            // The memo goes in now: it is encrypted to the recipient, so this device can never
            // read it back from the chain - the local bubble is the only place it can show.
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let pendingContent: String
            if trimmedNote.isEmpty {
                pendingContent = String(format: KaspaUnit.label(AppLocalization.string("Sent %@ KAS")), formattedAmount)
            } else {
                pendingContent = String(format: KaspaUnit.label(AppLocalization.string("Sent %@ KAS — %@")), formattedAmount, trimmedNote)
            }
            let pendingMessage = ChatMessage(
                txId: activePendingTxId,
                senderAddress: wallet.publicAddress,
                receiverAddress: contact.address,
                content: pendingContent,
                timestamp: pendingTimestamp,
                blockTime: UInt64(pendingTimestamp.timeIntervalSince1970 * 1000),
                acceptingBlock: nil,
                isOutgoing: true,
                messageType: .payment,
                deliveryStatus: .pending
            )
            pendingMessageId = pendingMessage.id
            addMessageToConversation(pendingMessage, contactAddress: contact.address)
            enqueuePendingOutgoing(contactAddress: contact.address, pendingTxId: activePendingTxId, messageType: .payment, timestamp: pendingTimestamp)
            saveMessages()
        } else {
            resetPendingMessage(activePendingTxId, contactAddress: contact.address)
            guard let existing = resolveMessageIdForPending(contactAddress: contact.address, pendingTxId: activePendingTxId) else {
                throw KasiaError.networkError("Pending payment not found for retry")
            }
            pendingMessageId = existing
        }

        registerOutgoingAttempt(
            messageId: pendingMessageId,
            pendingTxId: activePendingTxId,
            contactAddress: contact.address,
            messageType: .payment
        )
        markOutgoingAttemptSubmitting(messageId: pendingMessageId)

        // Paid to the contact's chatting address (the memo is encrypted to its key).
        if let reason = KaspaAddress.otherNetworkReason(contact.address) { throw KasiaError.networkError(reason) }
        let destinationAddress = contact.address

        /// The id this device computed for what it is about to submit (`acceptedTransactionId`).
        var builtTxId: String?
        /// The built transaction and the coins it chose from, for an unknown outcome's bookkeeping.
        var builtPayment: (tx: KaspaRpcTransaction, candidates: [UTXO])?
        do {
            let rpcManager = NodePoolService.shared
            let settings = currentSettings

            if !rpcManager.isConnected {
                try await rpcManager.connect(network: settings.networkType)
            }

            let utxos = try await rpcManager.getUtxosByAddresses([sourceAddress])
            // Not the coins a move, payment or withdrawal still in flight spent: the node lists
            // them until that spend is in a block.
            let confirmed = unreservedUtxos(utxos.filter { $0.blockDaaScore > 0 && !$0.isCoinbase })
            // Coin control: only the chosen coins (still unspent) - the builder picks from these.
            // If every chosen coin is gone, refuse: falling back to all coins would spend ones
            // the person deliberately left out (previews may fall back; the send may not).
            let spendable: [UTXO]
            if let manualUtxos, !manualUtxos.isEmpty {
                guard let resolved = resolveManualUtxos(manualUtxos, against: confirmed) else {
                    throw KasiaError.networkError("Selected UTXOs are no longer available - please reselect")
                }
                spendable = resolved
            } else {
                spendable = confirmed
            }
            guard !spendable.isEmpty else {
                throw KasiaError.networkError("No spendable UTXOs available")
            }

            // The payment's note is sealed to the contact's CHAT key, whichever address it pays:
            // that is the key every client decrypts payment payloads with (Android and Desktop
            // seal to it too). A pool address's key was readable by nobody.
            guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address),
                  KaspaAddress.publicKey(from: destinationAddress) != nil else {
                throw KasiaError.invalidAddress
            }

            // From a spending address it is a plain transfer, and the chatting address tells the
            // chat about it right after (`sendSpendingPaymentNotice`): the payee has never seen
            // that address, so a chat payment from it would open a stranger's Message Request on
            // their side instead of landing in this chat (XP-022).
            // KaPosts tips are not in KaChat Chess: no payment carries one.
            let tipPayload: Data? = nil
            let tx: KaspaRpcTransaction
            if fromChattingAddress {
                tx = try KasiaTransactionBuilder.buildPaymentTx(
                    from: sourceAddress,
                    to: destinationAddress,
                    amount: amountSompi,
                    note: note,
                    senderPrivateKey: sourcePrivateKey,
                    recipientPublicKey: recipientPublicKey,
                    utxos: spendable,
                    changeAddress: changeAddress,
                    extraFeeSompi: extraFeeSompi,
                    payloadOverride: tipPayload
                )
            } else {
                // A quantum-safe source (KIP-22) spends with its redeem script pushed after the
                // signature; nil for a quantum index means the seed is unreadable this instant.
                var senderRedeemScript: Data?
                if let spendingIndex = sourceSpendingIndex, WalletManager.isQuantumIndex(spendingIndex) {
                    guard let redeem = WalletManager.shared.quantumRedeemScript(at: spendingIndex) else {
                        throw KasiaError.keychainError("Could not derive the quantum address's key")
                    }
                    senderRedeemScript = redeem
                }
                tx = try KasiaTransactionBuilder.buildPlainTransferTx(
                    from: sourceAddress,
                    to: destinationAddress,
                    amount: amountSompi,
                    senderPrivateKey: sourcePrivateKey,
                    utxos: spendable,
                    extraFeeSompi: extraFeeSompi,
                    changeAddress: changeAddress,
                    senderRedeemScript: senderRedeemScript
                )
            }

            // Submit via RPC manager
            AppLog.log("[ChatService] Submitting payment via RPC manager...")
            builtTxId = KasiaTransactionBuilder.computeTransactionId(tx)
            builtPayment = (tx, spendable)
            let (txId, endpoint) = try await rpcManager.submitTransaction(tx, allowOrphan: false)
            AppLog.log("[ChatService] Payment submitted: \(txId) via \(endpoint)")
            if fromChattingAddress, let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: sourceAddress) {
                // Chatting-address-funded payment (privacy OFF) spends from the SAME UTXO set
                // message sends use - the same outpoint bookkeeping every message send does
                // keeps an immediately-following message from racing onto the just-spent
                // outpoints before the node reflects them. Spending-chain payments (ON) don't
                // touch that set, so they skip this exactly as before.
                let spentUtxos = spentMessageUtxos(from: tx, candidates: spendable)
                reserveMessageOutpoints(spentUtxos)
                consumePendingUtxos(spentUtxos)
                addPendingOutputs(from: tx, txId: txId, senderScriptPubKey: senderScriptPubKey)
            }
            _ = updatePendingMessageById(pendingMessageId, newTxId: txId, contactAddress: contact.address)
            markOutgoingAttemptSubmitted(
                messageId: pendingMessageId,
                pendingTxId: activePendingTxId,
                contactAddress: contact.address,
                messageType: .payment,
                txId: txId
            )
            clearNoInputRetryState(for: activePendingTxId)
            saveMessages()
            if let freshChangeIndex {
                // the account this send started on, even if another is active by now (IOS-109)
                await WalletManager.shared.revealSpendingAddress(at: freshChangeIndex, owner: wallet.publicAddress)
            }
            if !fromChattingAddress {
                // a spend reveals the key for good: the shield comes off (KIP-22)
                if let spendingIndex = sourceSpendingIndex, WalletManager.isQuantumIndex(spendingIndex) {
                    WalletManager.shared.markQuantumAddressSpent(sourceAddress, owner: wallet.publicAddress)
                }
                sendSpendingPaymentNotice(to: contact, txId: txId, amountSompi: amountSompi, memo: note)
            }
            return txId
        } catch {
            if let acceptedTxId = acceptedTransactionId(from: error, expected: builtTxId) {
                AppLog.log("[ChatService] Payment already accepted by consensus for %@ -> promoting pending to %@",
                      String(activePendingTxId.prefix(12)),
                      String(acceptedTxId.prefix(12)))
                _ = updatePendingMessageById(pendingMessageId, newTxId: acceptedTxId, contactAddress: contact.address)
                markOutgoingAttemptSubmitted(
                    messageId: pendingMessageId,
                    pendingTxId: activePendingTxId,
                    contactAddress: contact.address,
                    messageType: .payment,
                    txId: acceptedTxId
                )
                clearNoInputRetryState(for: activePendingTxId)
                saveMessages()
                if let freshChangeIndex {
                    await WalletManager.shared.revealSpendingAddress(at: freshChangeIndex, owner: wallet.publicAddress)
                }
                if !fromChattingAddress {
                    if let spendingIndex = sourceSpendingIndex, WalletManager.isQuantumIndex(spendingIndex) {
                        WalletManager.shared.markQuantumAddressSpent(sourceAddress, owner: wallet.publicAddress)
                    }
                    sendSpendingPaymentNotice(to: contact, txId: acceptedTxId, amountSompi: amountSompi, memo: note)
                }
                return acceptedTxId
            }

            if error is SendOutcomeUnknownError {
                // It may have landed: its coins stay out of the next move, payment and withdrawal,
                // its change may be on the fresh address, and its key on chain.
                if fromChattingAddress, let builtPayment {
                    recordPlainSend(builtPayment.tx, spent: builtPayment.candidates, txId: nil, changeScriptPubKey: nil)
                }
                if let freshChangeIndex {
                    await WalletManager.shared.revealSpendingAddress(at: freshChangeIndex, owner: wallet.publicAddress)
                }
                if !fromChattingAddress, let spendingIndex = sourceSpendingIndex, WalletManager.isQuantumIndex(spendingIndex) {
                    WalletManager.shared.markQuantumAddressSpent(sourceAddress, owner: wallet.publicAddress)
                }
            }

            if isNoConfirmedInputsError(error) {
                let delay = nextNoInputRetryDelay(for: activePendingTxId)
                AppLog.log(
                    "[ChatService] Payment deferred retry %@ in %.0fs (no confirmed inputs)",
                    String(activePendingTxId.prefix(12)),
                    delay
                )
                scheduleOutgoingRetry(
                    contact: contact,
                    pendingTxId: activePendingTxId,
                    pendingMessageId: pendingMessageId,
                    messageType: .payment,
                    delaySeconds: delay,
                    paymentAmountSompi: amountSompi,
                    paymentNote: note,
                    paymentSourceIndex: sourceSpendingIndex,
                    paymentExtraFeeSompi: extraFeeSompi,
                    paymentManualUtxos: manualUtxos
                )
                // Deferred, not sent - nothing to confirm yet.
                return nil
            }

            markOutgoingAttemptFailed(messageId: pendingMessageId, pendingTxId: activePendingTxId)
            markPendingMessageFailed(activePendingTxId, contactAddress: contact.address)
            clearNoInputRetryState(for: activePendingTxId)
            saveMessages()
            throw error
        }
    }

    /// Sends a plain KAS transfer from the wallet's identity address to an arbitrary
    /// recipient address (Profile > Chatting Address > Withdraw Kaspa). Unlike sendPayment,
    /// this carries no KaChat protocol payload and has no chat/conversation bookkeeping
    /// (pending message, delivery status, etc.) since the recipient isn't necessarily a
    /// contact. Returns the submitted transaction id.
    /// `expectedFeeSompi`: the fee the Review showed. A send built at the swipe that would pay more
    /// (its coins changed since the Review) throws `SendFeeChangedError` and sends nothing.
    func sendWithdrawal(toAddress: String, amountSompi: UInt64, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0, expectedFeeSompi: UInt64? = nil) async throws -> String {
        guard amountSompi > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }
        guard KaspaAddress.scriptPublicKey(from: toAddress) != nil else {
            throw KasiaError.invalidAddress
        }
        // the script ignores the prefix: a kaspatest: address on mainnet would pay real KAS
        if let reason = KaspaAddress.otherNetworkReason(toAddress) { throw KasiaError.networkError(reason) }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }
        try await refuseWhileSendUnresolved(to: toAddress)

        return try await enqueueOutgoingTxOperation {
            let rpcManager = NodePoolService.shared
            let settings = self.currentSettings

            if !rpcManager.isConnected {
                try await rpcManager.connect(network: settings.networkType)
            }

            let utxos = try await rpcManager.getUtxosByAddresses([wallet.publicAddress])
            self.updateWalletBalanceIfNeeded(address: wallet.publicAddress, utxos: utxos)
            let spendable = self.withdrawalSpendable(utxos)
            guard !spendable.isEmpty else {
                throw KasiaError.networkError("No spendable UTXOs available")
            }

            // Coin control passes back whichever UTXOs the user picked in the picker sheet,
            // which may be stale by the time the send actually fires - re-resolve by outpoint
            // against the fresh `spendable` fetch above rather than trusting the picker's
            // snapshot outright. Same pattern as sendFromSpendingAddress.
            var resolvedManualUtxos: [UTXO]?
            if let manualUtxos, !manualUtxos.isEmpty {
                func outpointKey(_ utxo: UTXO) -> String { "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)" }
                let spendableByOutpoint = Dictionary(uniqueKeysWithValues: spendable.map { (outpointKey($0), $0) })
                let resolved = manualUtxos.compactMap { spendableByOutpoint[outpointKey($0)] }
                guard !resolved.isEmpty else {
                    throw KasiaError.networkError("Selected UTXOs are no longer available - please reselect")
                }
                resolvedManualUtxos = resolved
            }

            let tx = try KasiaTransactionBuilder.buildPlainTransferTx(
                from: wallet.publicAddress,
                to: toAddress,
                amount: amountSompi,
                senderPrivateKey: privateKey,
                utxos: spendable,
                manualUtxos: resolvedManualUtxos,
                extraFeeSompi: extraFeeSompi
            )
            try self.checkFeeAgainstReview(tx, spending: spendable, expectedFeeSompi: expectedFeeSompi)

            AppLog.log("[ChatService] Submitting withdrawal via RPC manager...")
            let txId: String
            let endpoint: String
            do {
                (txId, endpoint) = try await rpcManager.submitTransaction(tx, allowOrphan: false)
            } catch let unknown as SendOutcomeUnknownError {
                // It may have landed: its coins stay out of the next send and the next move.
                self.recordPlainSend(tx, spent: spendable, txId: nil, changeScriptPubKey: nil)
                self.holdUnknownOutcomeSend(tx, txId: unknown.txId, source: wallet.publicAddress, recipient: toAddress)
                throw unknown
            }
            AppLog.log("[ChatService] Withdrawal submitted: \(txId) via \(endpoint)")
            // The same bookkeeping a chess move or a chat payment does: the node lists these coins
            // until the spend is in a block, so without it the next move (signed by this same
            // address) or send picks a coin this one already spent and is refused.
            self.recordPlainSend(tx, spent: spendable, txId: txId,
                                 changeScriptPubKey: KaspaAddress.scriptPublicKey(from: wallet.publicAddress))
            return txId
        }
    }

    /// Estimates the total fee (base + optional priority tip) for a withdrawal, without
    /// requiring a gRPC connection (uses the same REST-fallback UTXO fetch as other fee
    /// previews, since this only needs read access for the estimate).
    func estimateWithdrawalFee(toAddress: String, amountSompi: UInt64, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0) async throws -> SendFeeEstimate {
        guard amountSompi > 0 else { throw KasiaError.networkError("Amount is zero") }
        guard let wallet = WalletManager.shared.currentWallet else { throw KasiaError.walletNotFound }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress),
              let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: toAddress) else {
            throw KasiaError.invalidAddress
        }

        let spendable = try await withdrawalSpendableUtxos(for: wallet.publicAddress)
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        let resolvedManualUtxos = try resolveReviewSelection(manualUtxos, against: spendable)

        return try KasiaTransactionBuilder.estimatePlainTransferFee(
            utxos: spendable,
            amount: amountSompi,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey,
            manualUtxos: resolvedManualUtxos,
            extraFeeSompi: extraFeeSompi
        )
    }

    /// Maximum sendable amount for a withdrawal (balance minus the send-all fee, no change
    /// output). Mirrors estimateMaxPaymentAmount's approach for in-chat payments. With
    /// [manualUtxos] set (coin control active), "max" means max spendable from just that
    /// selected subset - same semantics as estimateMaxSpendingAddressAmount.
    /// `cappedAtInputLimit`: the address holds more coins than one transaction can spend, so this is
    /// the most its largest `maxInputsPerTransaction` coins can send (what the send itself picks,
    /// largest first) - not the whole balance, which no single transaction could carry.
    /// `feeMultiplier`: the speed tier (Fast 2, Priority 5). Its extra is worked out from the base
    /// fee of the send this Max builds, as the Review does (`maxSendAmount`); `extraFeeSompi` is a
    /// fixed extra on top (a custom fee).
    func estimateMaxWithdrawalAmount(toAddress: String, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0, feeMultiplier: UInt64 = 1) async throws -> (amountSompi: UInt64, cappedAtInputLimit: Bool) {
        guard let wallet = WalletManager.shared.currentWallet else { throw KasiaError.walletNotFound }
        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: toAddress),
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }

        let spendable = try await withdrawalSpendableUtxos(for: wallet.publicAddress)
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        let resolvedManualUtxos = try resolveReviewSelection(manualUtxos, against: spendable)
        let chunk = resolvedManualUtxos == nil ? Self.oneTransactionChunk(spendable) : nil
        let maxSet = resolvedManualUtxos ?? chunk ?? spendable

        let totalBalance = try maxSet.totalAmount()

        let amount = try Self.maxSendAmount(
            total: totalBalance,
            extraFeeSompi: extraFeeSompi,
            feeMultiplier: feeMultiplier,
            sendAllFee: { extra in
                KasiaTransactionBuilder.estimateSendAllFee(
                    utxos: maxSet,
                    payload: Data(),
                    recipientScriptPubKey: recipientScriptPubKey,
                    senderScriptPubKey: senderScriptPubKey,
                    extraFeeSompi: extra
                )
            },
            baseFee: { sompi in
                // the Review's Normal fee for this amount (`estimateWithdrawalFee` with no extra)
                (try? KasiaTransactionBuilder.estimatePlainTransferFee(
                    utxos: spendable,
                    amount: sompi,
                    recipientScriptPubKey: recipientScriptPubKey,
                    senderScriptPubKey: senderScriptPubKey,
                    manualUtxos: resolvedManualUtxos
                ))?.networkFee
            }
        )

        return (amount, chunk != nil)
    }

    /// Max at a speed tier. The Review prices a send's tier extra as a share of that same send's
    /// base (Normal) fee, so Max does too: worked out at one extra, then again at the extra the
    /// resulting amount's base fee gives, until the two agree. A tier extra taken from another
    /// amount's base fee (a typed amount, other coins) was too small for Max's own inputs, and
    /// the Review then could not price the Max at all ("Insufficient funds").
    static func maxSendAmount(
        total: UInt64,
        extraFeeSompi: UInt64,
        feeMultiplier: UInt64,
        sendAllFee: (UInt64) -> UInt64,
        baseFee: (UInt64) -> UInt64?
    ) throws -> UInt64 {
        func amount(extra: UInt64) throws -> UInt64 {
            let fee = sendAllFee(extra)
            guard total > fee else {
                throw KasiaError.networkError("Balance too low to cover fee")
            }
            return total - fee
        }
        var extra = extraFeeSompi
        var result = try amount(extra: extra)
        guard feeMultiplier > 1 else { return result }
        // two rounds settle it; the cap only guards against a shape that flips back and forth
        for _ in 0..<4 {
            guard let base = baseFee(result) else { break }
            let next = extraFeeSompi + base * (feeMultiplier - 1)
            if next == extra { break }
            extra = next
            result = try amount(extra: extra)
        }
        return result
    }

    /// The largest `maxInputsPerTransaction` coins, when there are more than one transaction can
    /// spend; nil when every coin fits. Largest first, the order `selectUtxosForPayment` adds them
    /// in, so a Max (or Compound) worked out from this chunk is exactly what the send then builds.
    static func oneTransactionChunk(_ spendable: [UTXO]) -> [UTXO]? {
        guard spendable.count > KasiaTransactionBuilder.maxInputsPerTransaction else { return nil }
        return Array(spendable.sorted { $0.amount > $1.amount }.prefix(KasiaTransactionBuilder.maxInputsPerTransaction))
    }

    /// What a plain send from the chatting address may spend, fetched fresh rather than from the
    /// 20-second `fetchUtxosWithFallback` cache: right after a send or a move that cache still
    /// lists the coins they spent, and a Max worked out from it was more than the address holds.
    /// The same filter `sendWithdrawal` builds with, so the estimate and the send agree.
    private func withdrawalSpendableUtxos(for address: String) async throws -> [UTXO] {
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
        updateWalletBalanceIfNeeded(address: address, utxos: utxos)
        return withdrawalSpendable(utxos)
    }

    /// What a plain send from the chatting address may spend out of `utxos`: confirmed, not mining
    /// rewards, and not just spent by this app (`unreservedUtxos`). The Wallet tab's Compound, the
    /// send's Available and Coin Control count the same coins the send does.
    func withdrawalSpendable(_ utxos: [UTXO]) -> [UTXO] {
        unreservedUtxos(utxos.filter { $0.blockDaaScore > 0 && !$0.isCoinbase })
    }

    /// Coin control for a Review's fee or Max: the picked coins that are still spendable, nil for
    /// automatic. When none of the picked coins are left it throws the send's own error, rather
    /// than estimating automatic selection for a send that would then refuse to go.
    private func resolveReviewSelection(_ manualUtxos: [UTXO]?, against spendable: [UTXO]) throws -> [UTXO]? {
        guard let manualUtxos, !manualUtxos.isEmpty else { return nil }
        guard let resolved = resolveManualUtxos(manualUtxos, against: spendable) else {
            throw KasiaError.networkError("Selected UTXOs are no longer available - please reselect")
        }
        return resolved
    }

    /// Within this of the Review's fee a rebuilt send still goes out.
    static let reviewFeeMarginSompi: UInt64 = 1_000

    /// A send is built again at the swipe, from the coins of that moment. If they changed since
    /// the Review (a move or claim spent one, a coin arrived) it can pick other coins and pay more,
    /// change too small to keep included: then nothing is sent and the Review shows the new fee.
    func checkFeeAgainstReview(_ tx: KaspaRpcTransaction, spending candidates: [UTXO], expectedFeeSompi: UInt64?) throws {
        guard let expectedFeeSompi else { return }
        let inputs = spentMessageUtxos(from: tx, candidates: candidates)
        guard inputs.count == tx.inputs.count else { return }
        let inTotal = inputs.reduce(UInt64(0)) { $0 + $1.amount }
        let outTotal = tx.outputs.reduce(UInt64(0)) { $0 + $1.value }
        guard inTotal >= outTotal else { return }
        let fee = inTotal - outTotal
        if fee > expectedFeeSompi + Self.reviewFeeMarginSompi {
            AppLog.log("[ChatService] send would pay \(fee) sompi, the Review showed \(expectedFeeSompi): not sent")
            throw SendFeeChangedError(feeSompi: fee)
        }
    }

    /// Leaves out coins a transaction from this app has just spent (`reservedMessageOutpoints`):
    /// the node goes on listing them until that spend is in a block.
    func unreservedUtxos(_ utxos: [UTXO]) -> [UTXO] {
        _ = unresolvedSends // after a relaunch, puts back the holds of "Not confirmed" sends
        let now = Date()
        return utxos.filter { utxo in
            guard let until = reservedMessageOutpoints[outpointKey(utxo.outpoint)] else { return true }
            return until <= now
        }
    }

    /// After a plain send, or one whose outcome is unknown: its coins are reserved so neither the
    /// next send nor the next chess move picks them again, and the UTXO cache is dropped. With a
    /// `txId` and `changeScriptPubKey` (the chatting address), its outputs back there are offered
    /// to the next move the way a move's own change is. Callers pass nil for an unknown outcome,
    /// since a move chained on a transaction that never landed would never land either.
    func recordPlainSend(_ tx: KaspaRpcTransaction, spent candidates: [UTXO], txId: String?, changeScriptPubKey: Data?) {
        let spentUtxos = spentMessageUtxos(from: tx, candidates: candidates)
        reserveMessageOutpoints(spentUtxos)
        consumePendingUtxos(spentUtxos)
        if let txId, let changeScriptPubKey {
            addPendingOutputs(from: tx, txId: txId, senderScriptPubKey: changeScriptPubKey)
        }
        invalidateUtxoCache()
    }

    /// Drops the 20-second UTXO cache: a send just spent some of what it holds.
    func invalidateUtxoCache() {
        cachedUtxos = []
        cachedUtxosTimestamp = nil
    }

    // MARK: - Sends that ended on "Not confirmed"

    /// How long a send with an unknown outcome keeps its coins, and stops the same payment being
    /// made again. A transaction a node really took is in a block within seconds, so one the
    /// network still doesn't have after this, its coins all unspent, never landed.
    static let unresolvedSendHold: TimeInterval = 600
    private static let unresolvedSendsKey = "kaplay_unresolved_sends_v1"
    private static var loadedUnresolvedSends: [UnresolvedSend]?

    /// Saved, so a relaunch doesn't forget one; the coins' hold is put back on the first read.
    private var unresolvedSends: [UnresolvedSend] {
        get {
            if let loaded = Self.loadedUnresolvedSends { return loaded }
            let stored = UserDefaults.standard.data(forKey: Self.unresolvedSendsKey)
                .flatMap { try? JSONDecoder().decode([UnresolvedSend].self, from: $0) } ?? []
            Self.loadedUnresolvedSends = stored
            let now = Date()
            for send in stored {
                let until = send.sentAt.addingTimeInterval(Self.unresolvedSendHold)
                guard until > now else { continue }
                for key in send.outpointKeys { reservedMessageOutpoints[key] = until }
            }
            return stored
        }
        set {
            Self.loadedUnresolvedSends = newValue
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.unresolvedSendsKey)
        }
    }

    /// A plain send that may have landed. Its coins stay out of every other send and move for the
    /// whole hold, not the usual 120 s, and `refuseWhileSendUnresolved` watches for a repeat.
    func holdUnknownOutcomeSend(_ tx: KaspaRpcTransaction, txId: String, source: String, recipient: String) {
        let keys = tx.inputs.map { outpointKey($0.previousOutpoint) }
        let until = Date().addingTimeInterval(Self.unresolvedSendHold)
        for key in keys { reservedMessageOutpoints[key] = until }
        var sends = unresolvedSends
        sends.removeAll { $0.txId == txId }
        sends.append(UnresolvedSend(txId: txId, source: source, recipient: recipient.lowercased(), outpointKeys: keys, sentAt: Date()))
        unresolvedSends = sends
    }

    /// Reserving coins alone can't stop a repeat paying twice: it would pick other coins and both
    /// could land. So before a send to someone a "Not confirmed" send went to, that send is looked
    /// up. Landed: the person is told once, and sending again after that is what they meant.
    /// Still undecided: nothing goes out. Never landed (the network doesn't have it and, after the
    /// hold, every coin is still unspent): its coins are released and the send goes ahead.
    func refuseWhileSendUnresolved(to recipient: String) async throws {
        let lowered = recipient.lowercased()
        for send in unresolvedSends {
            let landed: Bool
            if await NodePoolService.shared.networkHasTransaction(send.txId) {
                landed = true
            } else if let listed = try? await NodePoolService.shared.getUtxosByAddresses([send.source]) {
                let unspent = Set(listed.map { outpointKey($0.outpoint) })
                if send.outpointKeys.contains(where: { !unspent.contains($0) }) {
                    landed = true
                } else if Date().timeIntervalSince(send.sentAt) >= Self.unresolvedSendHold {
                    for key in send.outpointKeys { reservedMessageOutpoints[key] = nil }
                    unresolvedSends.removeAll { $0.txId == send.txId }
                    continue
                } else {
                    landed = false
                }
            } else {
                landed = false
            }
            if landed { unresolvedSends.removeAll { $0.txId == send.txId } }
            guard send.recipient == lowered else { continue }
            throw KasiaError.networkError(AppLocalization.string(landed
                ? "Your last send to this address went through. Check your balance, then send again only if you meant to pay twice."
                : "Your last send to this address isn't confirmed yet. Wait a few minutes before sending again, so it can't pay twice."))
        }
    }

    /// Sends a plain KAS transfer from a specific spending-chain address (Manage Addresses'
    /// per-row Withdraw action).
    ///
    /// For a NON-primary legacy index the change stays on the same address: that is a scoped,
    /// explicit single-address operation, and the row's own balance is what the user is
    /// managing. A quantum source's change always moves to a fresh slot (the spend reveals its
    /// key), but only a send from the primary moves the primary. The primary is different. A send from it puts its change on a fresh index and
    /// rotates the primary to that index - exactly what a chat payment does - so the address
    /// you spend from and hand out next has never been used before. This path used to leave
    /// the primary sitting on the address it had just spent from. The old primary keeps
    /// whatever it still holds, listed in Manage Addresses like any other revealed slot.
    func sendFromSpendingAddress(index: Int, toAddress: String, amountSompi: UInt64, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0, expectedFeeSompi: UInt64? = nil) async throws -> String {
        // the account this send belongs to: what it writes after the network answers goes here,
        // even if another account is active by then (IOS-109)
        let owner = WalletManager.shared.currentWallet?.publicAddress
        guard amountSompi > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }
        guard KaspaAddress.scriptPublicKey(from: toAddress) != nil else {
            throw KasiaError.invalidAddress
        }
        // the script ignores the prefix: a kaspatest: address on mainnet would pay real KAS
        if let reason = KaspaAddress.otherNetworkReason(toAddress) { throw KasiaError.networkError(reason) }
        guard let fromAddress = WalletManager.shared.spendingAddress(at: index),
              let privateKey = WalletManager.shared.spendingPrivateKey(at: index) else {
            throw KasiaError.keychainError("Could not derive this spending address")
        }
        try await refuseWhileSendUnresolved(to: toAddress)
        let wasPrimary = index == WalletManager.shared.currentSpendingAddressIndex
        // Fresh change index for the primary only: past the all-time max, so it has never been
        // revealed, funded or offered (the same rule `sendPaymentInternal` uses). Decided up
        // front and applied only after the node accepts the transaction, so a failed send moves
        // nothing. If the fresh address cannot be derived this instant, change stays put and
        // the primary stays put with it - rotating onto an address the change did not reach
        // would strand the funds behind a pointer. A self-send (the Compound action) moves
        // nothing out of the address, so it neither splits its consolidation onto a fresh
        // address nor rotates.
        var freshChangeIndex: Int?
        var changeAddress: String?
        let isSelfSend = toAddress.lowercased() == fromAddress.lowercased()
        // A quantum source's change must NEVER return to it - the spend reveals its key, and
        // change back would park funds on a revealed address (KIP-22). A legacy primary keeps
        // rotating as before; both rotate onto a fresh quantum slot now. A self-send (Compound)
        // still consolidates into the address itself, shield off.
        if !isSelfSend, WalletManager.isQuantumIndex(index) || index == WalletManager.shared.currentSpendingAddressIndex {
            if let slot = await WalletManager.shared.verifiedFreshQuantumSlot() {
                freshChangeIndex = slot.index
                changeAddress = slot.address
            } else if WalletManager.isQuantumIndex(index) {
                // never change back onto the key this spend reveals (IOS-104)
                throw KasiaError.keychainError(AppLocalization.string("Couldn't prepare the next address. Try again."))
            }
        }

        return try await enqueueOutgoingTxOperation {
            let rpcManager = NodePoolService.shared
            let settings = self.currentSettings

            if !rpcManager.isConnected {
                try await rpcManager.connect(network: settings.networkType)
            }

            let utxos = try await rpcManager.getUtxosByAddresses([fromAddress])
            // Spendable = non-coinbase + matured coinbase (mining rewards). The old `!isCoinbase`
            // gate dropped every coinbase UTXO, which is why compounding/withdrawing a mining
            // address failed with a bare "No spendable UTXOs".
            let vds = await self.resolveVirtualDaaScore(nil, utxos: utxos)
            var spendable = self.unreservedUtxos(ChatService.spendableUtxos(utxos, virtualDaaScore: vds))
            if spendable.isEmpty, let manualUtxos, !manualUtxos.isEmpty {
                // The fresh fetch came back empty (transient pool/node condition) but the caller
                // pinned an explicit set (e.g. a compound chunk) - fall back to it; the node will
                // reject any of those inputs that were actually already spent. Never a coin this
                // app just spent, though: that's why the fetch can look empty.
                spendable = self.unreservedUtxos(ChatService.spendableUtxos(manualUtxos, virtualDaaScore: vds))
            }
            guard !spendable.isEmpty else {
                throw KasiaError.networkError("No spendable UTXOs available")
            }

            // Coin control passes back whichever UTXOs the user picked in the picker sheet,
            // which may be stale by the time the send actually fires (spent by another device,
            // aged out, etc.) - re-resolve by outpoint against the fresh `spendable` fetch above
            // rather than trusting the picker's snapshot outright.
            var resolvedManualUtxos: [UTXO]?
            if let manualUtxos, !manualUtxos.isEmpty {
                func outpointKey(_ utxo: UTXO) -> String { "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)" }
                let spendableByOutpoint = Dictionary(uniqueKeysWithValues: spendable.map { (outpointKey($0), $0) })
                let resolved = manualUtxos.compactMap { spendableByOutpoint[outpointKey($0)] }
                guard !resolved.isEmpty else {
                    throw KasiaError.networkError("Selected UTXOs are no longer available - please reselect")
                }
                resolvedManualUtxos = resolved
            }

            var senderRedeemScript: Data?
            if WalletManager.isQuantumIndex(index) {
                guard let redeem = WalletManager.shared.quantumRedeemScript(at: index) else {
                    throw KasiaError.keychainError("Could not derive the quantum address's key")
                }
                senderRedeemScript = redeem
            }
            let tx = try KasiaTransactionBuilder.buildPlainTransferTx(
                from: fromAddress,
                to: toAddress,
                amount: amountSompi,
                senderPrivateKey: privateKey,
                utxos: spendable,
                manualUtxos: resolvedManualUtxos,
                extraFeeSompi: extraFeeSompi,
                changeAddress: changeAddress,
                virtualDaaScore: vds,
                senderRedeemScript: senderRedeemScript
            )
            try self.checkFeeAgainstReview(tx, spending: spendable, expectedFeeSompi: expectedFeeSompi)

            // These addresses are on chain now: never offered again as unused, though the "unused"
            // remembered this session would still say so. (The Receive QR relies on this.)
            @MainActor func markAddressesUsed() {
                self.markSpendingAddressUsed(fromAddress)
                if let changeAddress, let script = KaspaAddress.scriptPublicKey(from: changeAddress),
                   tx.outputs.contains(where: { $0.scriptPublicKey.script == script }) {
                    self.markSpendingAddressUsed(changeAddress)
                }
            }

            AppLog.log("[ChatService] Submitting spending-address withdrawal via RPC manager...")
            let txId: String
            let endpoint: String
            do {
                (txId, endpoint) = try await rpcManager.submitTransaction(tx, allowOrphan: false)
            } catch let unknown as SendOutcomeUnknownError {
                // It may have landed: its change may be on the fresh address, and its key on chain.
                self.recordPlainSend(tx, spent: spendable, txId: nil, changeScriptPubKey: nil)
                self.holdUnknownOutcomeSend(tx, txId: unknown.txId, source: fromAddress, recipient: toAddress)
                markAddressesUsed()
                if WalletManager.isQuantumIndex(index) {
                    WalletManager.shared.markQuantumAddressSpent(fromAddress, owner: owner)
                }
                if let freshChangeIndex {
                    await WalletManager.shared.revealSpendingAddress(at: freshChangeIndex, owner: owner)
                }
                throw unknown
            }
            AppLog.log("[ChatService] Spending-address withdrawal submitted: \(txId) via \(endpoint)")
            // its coins stay out of the next send from this address until the spend is in a block;
            // nothing here is offered to chess moves, which only spend the chatting address
            self.recordPlainSend(tx, spent: spendable, txId: nil, changeScriptPubKey: nil)
            markAddressesUsed()
            if WalletManager.isQuantumIndex(index) {
                // the spend put this address's key on chain for good (self-sends included)
                WalletManager.shared.markQuantumAddressSpent(fromAddress, owner: owner)
            }
            if let freshChangeIndex {
                if wasPrimary {
                    // The primary follows its change onto the fresh address. Manage Addresses
                    // listens for this and moves its star at once.
                    await WalletManager.shared.setActiveSpendingAddress(freshChangeIndex, owner: owner)
                } else {
                    // another quantum address's change: listed, its slot never handed out again
                    await WalletManager.shared.revealSpendingAddress(at: freshChangeIndex, owner: owner)
                }
            }
            return txId
        }
    }

    /// Kaspa coinbase (mining-reward) maturity, in DAA-score units: a coinbase UTXO is only
    /// spendable once `blockDaaScore + coinbaseMaturity < virtualDaaScore`. Matches Kaspa consensus
    /// and Kaspium (which uses the same 1000).
    static let coinbaseMaturity: UInt64 = 1000

    /// Filters a UTXO set to what's actually spendable *right now*. Non-coinbase UTXOs always are;
    /// coinbase (mining rewards) only once matured against `virtualDaaScore`. When the score is
    /// unknown (nil) coinbase is included and the node arbitrates - better than silently hiding a
    /// mining balance. This is why an address full of coinbase UTXOs used to fail every send/
    /// compound with a bare "No spendable UTXOs" (the old `!isCoinbase` filter dropped them all).
    static func spendableUtxos(_ utxos: [UTXO], virtualDaaScore: UInt64?) -> [UTXO] {
        utxos.filter { utxo in
            guard utxo.isCoinbase else { return true }
            guard let vds = virtualDaaScore else { return true }
            // overflow (a nonsense DAA score from a node) counts as not yet mature
            let (matureAt, overflow) = utxo.blockDaaScore.addingReportingOverflow(coinbaseMaturity)
            return !overflow && matureAt < vds
        }
    }

    /// Resolves the virtual DAA score needed for coinbase-maturity checks, fetching it from the
    /// pool only when it matters (the UTXO set actually contains coinbase). Non-mining addresses
    /// - the common case - never pay for a network round trip.
    func resolveVirtualDaaScore(_ provided: UInt64?, utxos: [UTXO]) async -> UInt64? {
        if let provided { return provided }
        guard utxos.contains(where: { $0.isCoinbase }) else { return nil }
        return await NodePoolService.shared.currentVirtualDaaScore()
    }

    /// The largest set of UTXOs that fit in a single mass-safe transaction (up to
    /// `KasiaTransactionBuilder.maxInputsPerTransaction`, largest-first), plus the max self-send
    /// amount for exactly that set. Kaspa caps a transaction's mass (~89 inputs), so the compound
    /// UI's "Max" uses this to reflect *one transaction's worth* of consolidatable value instead of
    /// the whole (over-mass) balance - the user consolidates that chunk, then repeats to reduce
    /// further. Returns the chunk so the send spends exactly those inputs.
    /// `selection`: the coins Coin Control picked, nil for all of them.
    func maxConsolidatableChunk(index: Int, selection: [UTXO]? = nil, extraFeeSompi: UInt64 = 0, feeMultiplier: UInt64 = 1, availableUtxos: [UTXO] = []) async throws -> (amountSompi: UInt64, utxos: [UTXO]) {
        guard let fromAddress = WalletManager.shared.spendingAddress(at: index) else {
            throw KasiaError.keychainError("Could not derive this spending address")
        }
        // Prefer the UTXOs the caller already loaded for this address (exactly what the user sees
        // in the list) so the estimate never depends on a second pooled fetch that can transiently
        // come back empty while the first succeeded. Only fetch (with one retry) if none supplied.
        var utxos = availableUtxos
        if utxos.isEmpty {
            let rpcManager = NodePoolService.shared
            if !rpcManager.isConnected {
                try await rpcManager.connect(network: currentSettings.networkType)
            }
            utxos = try await rpcManager.getUtxosByAddresses([fromAddress])
            if utxos.isEmpty {
                utxos = try await rpcManager.getUtxosByAddresses([fromAddress])
            }
        }
        // Spendable = non-coinbase (always) + matured coinbase. A pure `!isCoinbase` gate is what
        // broke compounding on mining-reward addresses: it dropped every one of their coinbase
        // UTXOs. Fetch the virtual DAA score only when coinbase is actually present.
        let virtualDaaScore = await resolveVirtualDaaScore(nil, utxos: utxos)
        let spendable = unreservedUtxos(ChatService.spendableUtxos(utxos, virtualDaaScore: virtualDaaScore))
        guard !spendable.isEmpty else {
            if utxos.contains(where: { $0.isCoinbase }) {
                throw KasiaError.networkError("These are mining (coinbase) rewards that haven't matured yet. Each becomes spendable a short time (about 1–2 minutes) after it's mined - try again shortly.")
            }
            throw KasiaError.networkError("No spendable UTXOs available")
        }
        // Largest-first, capped to what fits one transaction's mass.
        let candidates = try resolveReviewSelection(selection, against: spendable) ?? spendable
        let chunk = Array(candidates.sorted { $0.amount > $1.amount }.prefix(KasiaTransactionBuilder.maxInputsPerTransaction))
        let amount = try await estimateMaxSpendingAddressAmount(index: index, toAddress: fromAddress, manualUtxos: chunk, extraFeeSompi: extraFeeSompi, feeMultiplier: feeMultiplier, availableUtxos: utxos, virtualDaaScore: virtualDaaScore).amountSompi
        return (amount, chunk)
    }

    /// Estimates the total fee for a spending-address withdrawal. Calls NodePoolService
    /// directly rather than fetchUtxosWithFallback, whose single-address UTXO cache would
    /// return the wrong address's data when estimating for anything but the identity address.
    func estimateSpendingAddressWithdrawalFee(index: Int, toAddress: String, amountSompi: UInt64, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0, availableUtxos: [UTXO] = [], virtualDaaScore: UInt64? = nil) async throws -> SendFeeEstimate {
        guard amountSompi > 0 else { throw KasiaError.networkError("Amount is zero") }
        guard let fromAddress = WalletManager.shared.spendingAddress(at: index) else {
            throw KasiaError.keychainError("Could not derive this spending address")
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: fromAddress),
              let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: toAddress) else {
            throw KasiaError.invalidAddress
        }

        let utxos = availableUtxos.isEmpty ? try await NodePoolService.shared.getUtxosByAddresses([fromAddress]) : availableUtxos
        let vds = await resolveVirtualDaaScore(virtualDaaScore, utxos: utxos)
        // the send leaves out coins just spent, so the estimate does too
        let spendable = unreservedUtxos(ChatService.spendableUtxos(utxos, virtualDaaScore: vds))
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        let resolvedManualUtxos = try resolveReviewSelection(manualUtxos, against: spendable)

        return try KasiaTransactionBuilder.estimatePlainTransferFee(
            utxos: spendable,
            amount: amountSompi,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey,
            manualUtxos: resolvedManualUtxos,
            extraFeeSompi: extraFeeSompi,
            virtualDaaScore: vds,
            signatureScriptSize: WalletManager.isQuantumIndex(index)
                ? KasiaTransactionBuilder.kip22SignatureScriptSize : 66,
            changeScriptPubKey: plannedChangeScript(index: index, fromAddress: fromAddress, toAddress: toAddress)
        )
    }

    /// The change script `sendFromSpendingAddress` will use when it isn't the source's own: the
    /// next fresh quantum slot's. Its slot can move on before the swipe, but every slot's script
    /// is the same length, and length is all a fee sees. Nil when change stays on the source.
    private func plannedChangeScript(index: Int, fromAddress: String, toAddress: String) -> Data? {
        guard toAddress.lowercased() != fromAddress.lowercased(),
              WalletManager.isQuantumIndex(index) || index == WalletManager.shared.currentSpendingAddressIndex,
              let fresh = WalletManager.shared.spendingAddress(at: WalletManager.shared.nextFreshQuantumIndex()) else { return nil }
        return KaspaAddress.scriptPublicKey(from: fresh)
    }

    /// Maximum sendable amount from a specific spending address (balance minus the send-all
    /// fee, no change output). With coin control active (`manualUtxos` non-empty and still
    /// resolvable), "max" means max spendable from just the selected UTXOs, not the whole
    /// address - same semantics `KasiaTransactionBuilder.estimateSendAllFee` already applies.
    /// `cappedAtInputLimit` as in `estimateMaxWithdrawalAmount`.
    /// `feeMultiplier` as in `estimateMaxWithdrawalAmount`.
    func estimateMaxSpendingAddressAmount(index: Int, toAddress: String, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0, feeMultiplier: UInt64 = 1, availableUtxos: [UTXO] = [], virtualDaaScore: UInt64? = nil) async throws -> (amountSompi: UInt64, cappedAtInputLimit: Bool) {
        guard let fromAddress = WalletManager.shared.spendingAddress(at: index) else {
            throw KasiaError.keychainError("Could not derive this spending address")
        }
        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: toAddress),
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: fromAddress) else {
            throw KasiaError.invalidAddress
        }

        let utxos = availableUtxos.isEmpty ? try await NodePoolService.shared.getUtxosByAddresses([fromAddress]) : availableUtxos
        let vds = await resolveVirtualDaaScore(virtualDaaScore, utxos: utxos)
        // the send leaves out coins just spent, so the estimate does too
        let spendable = unreservedUtxos(ChatService.spendableUtxos(utxos, virtualDaaScore: vds))
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        let resolvedManualUtxos = try resolveReviewSelection(manualUtxos, against: spendable)
        // more coins than one transaction can spend: Max is what its largest coins can send
        let chunk = resolvedManualUtxos == nil ? Self.oneTransactionChunk(spendable) : nil
        let maxSet = resolvedManualUtxos ?? chunk ?? spendable

        let totalBalance = try maxSet.totalAmount()
        let signatureScriptSize = WalletManager.isQuantumIndex(index)
            ? KasiaTransactionBuilder.kip22SignatureScriptSize : 66
        let changeScript = plannedChangeScript(index: index, fromAddress: fromAddress, toAddress: toAddress)

        let amount = try Self.maxSendAmount(
            total: totalBalance,
            extraFeeSompi: extraFeeSompi,
            feeMultiplier: feeMultiplier,
            sendAllFee: { extra in
                KasiaTransactionBuilder.estimateSendAllFee(
                    utxos: maxSet,
                    payload: Data(),
                    recipientScriptPubKey: recipientScriptPubKey,
                    senderScriptPubKey: senderScriptPubKey,
                    extraFeeSompi: extra,
                    virtualDaaScore: vds,
                    signatureScriptSize: signatureScriptSize
                )
            },
            baseFee: { sompi in
                // the Review's Normal fee for this amount (`estimateSpendingAddressWithdrawalFee`)
                (try? KasiaTransactionBuilder.estimatePlainTransferFee(
                    utxos: spendable,
                    amount: sompi,
                    recipientScriptPubKey: recipientScriptPubKey,
                    senderScriptPubKey: senderScriptPubKey,
                    manualUtxos: resolvedManualUtxos,
                    virtualDaaScore: vds,
                    signatureScriptSize: signatureScriptSize,
                    changeScriptPubKey: changeScript
                ))?.networkFee
            }
        )

        return (amount, chunk != nil)
    }

    /// Re-resolves a coin-control selection by outpoint against a freshly-fetched spendable
    /// list, since the selection may be stale by the time a fee/max preview or the actual send
    /// runs (spent by another device, aged out, etc.). Returns nil (fall back to automatic
    /// selection) if nothing manual was passed, or if every previously-selected UTXO is gone -
    /// callers that need to distinguish "gone" from "never selected" (i.e. the actual send,
    /// where silently falling back to automatic would spend UTXOs the user didn't choose) do
    /// their own stricter check instead of using this helper - see `sendFromSpendingAddress`.
    private func resolveManualUtxos(_ manualUtxos: [UTXO]?, against spendable: [UTXO]) -> [UTXO]? {
        guard let manualUtxos, !manualUtxos.isEmpty else { return nil }
        func outpointKey(_ utxo: UTXO) -> String { "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)" }
        let spendableByOutpoint = Dictionary(uniqueKeysWithValues: spendable.map { (outpointKey($0), $0) })
        let resolved = manualUtxos.compactMap { spendableByOutpoint[outpointKey($0)] }
        return resolved.isEmpty ? nil : resolved
    }

    /// Whether an address has ever appeared in a transaction, independent of its current
    /// balance (a swept-to-zero address still counts as used) — powers the "Used"/"Unused"
    /// badge in Manage Addresses. A transaction-count lookup, not a balance check.
    ///
    /// "Used" is MONOTONIC and address-intrinsic: once true it can never become false again,
    /// so positive answers are cached persistently and answered without a network round-trip
    /// forever after. Negative ("unused") answers are cached ONLY for this process's lifetime
    /// (`sessionUnusedAddresses`) — an unused address can become used at any moment, but only
    /// via our own sends or an external deposit, and a deposit means a nonzero balance, which
    /// every list load short-circuits to "used" before consulting any cache. Never persisted
    /// across launches. This is what makes Manage Addresses / Address Visibility (and cold
    /// storage discovery, which shares this primitive) open instantly instead of re-deriving
    /// used-ness over the network every time.
    private static let usedAddressCacheKey = "kachat_used_addresses_v1"
    /// Session-only memory of CONFIRMED-unused probe results. In-memory by design: it must
    /// die with the process so a stale "unused" can never survive into a later launch.
    private static var sessionUnusedAddresses: Set<String> = []

    /// Cache-only, synchronous view of used-ness: `true` = persistently confirmed used,
    /// `false` = confirmed unused earlier THIS session, `nil` = no cached answer (a network
    /// probe is needed). Lets list loads label rows on the first frame without a round-trip.
    func cachedSpendingAddressUsedState(_ address: String) -> Bool? {
        let cached = UserDefaults.standard.array(forKey: Self.usedAddressCacheKey) as? [String] ?? []
        if cached.contains(address) { return true }
        if Self.sessionUnusedAddresses.contains(address) { return false }
        return nil
    }

    /// Marks an address confirmed-used without a probe — e.g. it holds a balance right now,
    /// which proves history. "Used" is monotonic, so persisting this is always safe and makes
    /// every future launch answer instantly even after the balance is swept back to zero.
    func markSpendingAddressUsed(_ address: String) {
        Self.sessionUnusedAddresses.remove(address)
        var updated = UserDefaults.standard.array(forKey: Self.usedAddressCacheKey) as? [String] ?? []
        guard !updated.contains(address) else { return }
        updated.append(address)
        UserDefaults.standard.set(updated, forKey: Self.usedAddressCacheKey)
    }

    /// Tri-state variant of `hasSpendingAddressBeenUsed`: `true` = confirmed used (cached or a
    /// successful count lookup found history), `false` = CONFIRMED unused (the REST probe
    /// succeeded and the count is genuinely zero), `nil` = the probe FAILED (network error,
    /// non-2xx, decode failure) so used-ness is unknown right now. Callers that make
    /// decisions off "unused" (the Generate recyclers, the Used/Unused badge) must treat `nil`
    /// as "don't know" - never as "unused" - so a rate-limited or offline probe can't recycle
    /// or mislabel an address that actually has history.
    ///
    /// The network probe is `GET /addresses/{address}/transactions-count` — a one-integer JSON
    /// body ({"total": N}, ~14 bytes) instead of the old `full-transactions?limit=1&
    /// resolve_previous_outpoints=light`, which made the server assemble (and us download and
    /// decode) an entire transaction with resolved outpoints just to answer a yes/no question.
    /// A short per-request timeout keeps a hung host from pinning a sweep's concurrency slot.
    ///
    /// `ignoringSessionCache`: ask the network even if this session remembers "unused". For an
    /// address about to be handed out: a payment to a spending address raises no event in KaPlay,
    /// so that memory can be out of date.
    func spendingAddressUsedState(_ address: String, ignoringSessionCache: Bool = false) async -> Bool? {
        if let cached = cachedSpendingAddressUsedState(address), cached || !ignoringSessionCache { return cached }
        guard let url = kaspaRestURL(path: "/addresses/\(address)/transactions-count") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            let count = try JSONDecoder().decode(KaspaAddressTransactionsCountResponse.self, from: data)
            let used = count.total > 0
            if used {
                markSpendingAddressUsed(address)
            } else {
                Self.sessionUnusedAddresses.insert(address)
            }
            return used
        } catch {
            return nil
        }
    }

    /// The payload a payment will carry, for pricing it: a tip carries the larger `kchat:1:tip:`
    /// one (signed, naming the post), so it is built the same way with a stand-in signature of
    /// the real length instead of asking for one (AND-041).
    private func estimationPayload(note: String, amount: UInt64, recipientPublicKey: Data, tip: KaPostTip?) throws -> Data {
        try KasiaTransactionBuilder.buildPaymentPayload(message: note, amount: amount, recipientPublicKey: recipientPublicKey)
    }

    /// The base (Normal) fee; a Fast / Priority / custom extra goes on top (see the Send KAS sheet).
    func estimatePaymentFee(to contact: Contact, amountSompi: UInt64, note: String = "", sourceSpendingIndex: Int? = nil, manualUtxos: [UTXO]? = nil, tip: KaPostTip? = nil) async throws -> SendFeeEstimate {
        guard amountSompi > 0 else { throw KasiaError.networkError("Amount is zero") }
        // Must source from whatever `sendPaymentInternal` will actually spend from - the
        // spending chain with Chats Payment Privacy ON, the chatting address with it OFF (see
        // `paymentFundingSourceAddress`). Estimating from a hardcoded source here used to
        // silently compute against the wrong balance/UTXO set whenever it differed from the
        // address actually spent from.
        let sourceAddress = try paymentFundingSourceAddress(spendingIndex: sourceSpendingIndex)
        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }

        let payload = try estimationPayload(note: note, amount: amountSompi, recipientPublicKey: recipientPublicKey, tip: tip)
        // Use fallback method - doesn't require gRPC connection
        let utxos = try await fetchUtxosWithFallback(for: sourceAddress)
        let candidates = unreservedUtxos(utxos.filter { !$0.isCoinbase })
        let spendable = resolveManualUtxos(manualUtxos, against: candidates) ?? candidates
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }

        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: sourceAddress),
              let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }

        return try KasiaTransactionBuilder.estimatePaymentFee(
            utxos: spendable,
            payload: payload,
            amount: amountSompi,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey,
            signatureScriptSize: sourceSpendingIndex.map(WalletManager.isQuantumIndex) == true
                ? KasiaTransactionBuilder.kip22SignatureScriptSize : 66
        )
    }

    func sendHandshakeInternal(to contact: Contact, isResponse: Bool, pendingTxId: String? = nil) async throws {
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }

        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }

        // Ensure routing state exists for this contact before sending
        ensureRoutingState(for: contact.address, privateKey: privateKey)
        let alias = outgoingAlias(for: contact.address)
        let conversationId = conversationIds[contact.address] ?? generateConversationId()

        if pendingTxId == nil {
            do {
                try await ensureSufficientBalanceForHandshakeSend(
                    to: contact,
                    isResponse: isResponse,
                    walletAddress: wallet.publicAddress,
                    alias: alias,
                    conversationId: conversationId,
                    privateKey: privateKey,
                    recipientPublicKey: recipientPublicKey
                )
            } catch {
                if isInsufficientBalancePopupError(error) {
                    throw error
                } else if isNoConfirmedInputsError(error) {
                    AppLog.log("[ChatService] Handshake send precheck deferred: %@", error.localizedDescription)
                } else if shouldBypassBalancePrecheck(error) {
                    AppLog.log("[ChatService] Handshake balance precheck unavailable, continuing send: %@", error.localizedDescription)
                } else {
                    throw error
                }
            }
        }

        let activePendingTxId = pendingTxId ?? "pending_\(UUID().uuidString)"
        var activePendingMessageId: UUID?
        if pendingTxId == nil {
            let pendingTimestamp = Date()
            let handshakeContent = isResponse ? "[Request accepted]" : "[Request to communicate]"
            let pendingMessage = ChatMessage(
                txId: activePendingTxId,
                senderAddress: wallet.publicAddress,
                receiverAddress: contact.address,
                content: handshakeContent,
                timestamp: pendingTimestamp,
                blockTime: UInt64(pendingTimestamp.timeIntervalSince1970 * 1000),
                isOutgoing: true,
                messageType: .handshake,
                deliveryStatus: .pending
            )
            activePendingMessageId = pendingMessage.id
            addMessageToConversation(pendingMessage, contactAddress: contact.address)
            enqueuePendingOutgoing(
                contactAddress: contact.address,
                pendingTxId: activePendingTxId,
                messageType: .handshake,
                timestamp: pendingTimestamp
            )
        } else {
            resetPendingMessage(activePendingTxId, contactAddress: contact.address)
            activePendingMessageId = resolveMessageIdForPending(contactAddress: contact.address, pendingTxId: activePendingTxId)
        }
        saveMessages()
        if let activePendingMessageId {
            registerOutgoingAttempt(
                messageId: activePendingMessageId,
                pendingTxId: activePendingTxId,
                contactAddress: contact.address,
                messageType: .handshake
            )
            markOutgoingAttemptSubmitting(messageId: activePendingMessageId)
        }

        /// The id this device computed for what it is about to submit (`acceptedTransactionId`).
        var builtTxId: String?
        do {
            let rpcManager = NodePoolService.shared
            let settings = currentSettings

            if !rpcManager.isConnected {
                try await rpcManager.connect(network: settings.networkType)
            }

            let utxos = try await rpcManager.getUtxosByAddresses([wallet.publicAddress])
            updateWalletBalanceIfNeeded(address: wallet.publicAddress, utxos: utxos)
            let spendable = utxos.filter { $0.blockDaaScore > 0 && !$0.isCoinbase }
            guard !spendable.isEmpty else {
                throw KasiaError.networkError("No UTXOs available. Your account may be empty.")
            }

            // Split UTXOs so we can send self-stash as a second tx without double-spend
            let (handshakeUtxos, stashUtxos) = splitUtxosForHandshake(spendable)

            let transaction = try KasiaTransactionBuilder.buildHandshakeTx(
                from: wallet.publicAddress,
                to: contact.address,
                alias: alias,
                conversationId: conversationId,
                isResponse: isResponse,
                senderPrivateKey: privateKey,
                recipientPublicKey: recipientPublicKey,
                utxos: handshakeUtxos
            )

            builtTxId = KasiaTransactionBuilder.computeTransactionId(transaction)
            let (txId, endpoint) = try await rpcManager.submitTransaction(transaction, allowOrphan: false)
            AppLog.log("[ChatService] Handshake submitted: \(txId) via \(endpoint)")
            if let activePendingMessageId {
                _ = updatePendingMessageById(activePendingMessageId, newTxId: txId, contactAddress: contact.address)
            } else {
                _ = updatePendingMessage(activePendingTxId, withRealTxId: txId, contactAddress: contact.address)
            }
            markOutgoingAttemptSubmitted(
                messageId: activePendingMessageId,
                pendingTxId: activePendingTxId,
                contactAddress: contact.address,
                messageType: .handshake,
                txId: txId
            )
            clearNoInputRetryState(for: activePendingTxId)

            addOurAlias(alias, for: contact.address, blockTime: nil)
            saveOurAliases()
            conversationIds[contact.address] = conversationId
            saveConversationIds()

            saveMessages()

            // Create self-stash to persist handshake metadata (separate tx)
            await sendOrQueueSelfStash(
                contactAddress: contact.address,
                ourAlias: alias,
                theirAlias: primaryConversationAlias(for: contact.address),
                isResponse: isResponse,
                walletAddress: wallet.publicAddress,
                privateKey: privateKey,
                utxos: stashUtxos,
                handshakeTx: transaction,
                handshakeTxId: txId,
                senderScriptPubKey: senderScriptPubKey
            )
        } catch {
            if let acceptedTxId = acceptedTransactionId(from: error, expected: builtTxId) {
                AppLog.log("[ChatService] Handshake already accepted by consensus for %@ -> promoting pending to %@",
                      String(activePendingTxId.prefix(12)),
                      String(acceptedTxId.prefix(12)))
                if let activePendingMessageId {
                    _ = updatePendingMessageById(activePendingMessageId, newTxId: acceptedTxId, contactAddress: contact.address)
                } else {
                    _ = updatePendingMessage(activePendingTxId, withRealTxId: acceptedTxId, contactAddress: contact.address)
                }
                markOutgoingAttemptSubmitted(
                    messageId: activePendingMessageId,
                    pendingTxId: activePendingTxId,
                    contactAddress: contact.address,
                    messageType: .handshake,
                    txId: acceptedTxId
                )
                clearNoInputRetryState(for: activePendingTxId)
                saveMessages()
                return
            }

            if isNoConfirmedInputsError(error) {
                let delay = nextNoInputRetryDelay(for: activePendingTxId)
                AppLog.log(
                    "[ChatService] Handshake deferred retry %@ in %.0fs (no confirmed inputs)",
                    String(activePendingTxId.prefix(12)),
                    delay
                )
                scheduleOutgoingRetry(
                    contact: contact,
                    pendingTxId: activePendingTxId,
                    pendingMessageId: activePendingMessageId,
                    messageType: .handshake,
                    delaySeconds: delay,
                    handshakeIsResponse: isResponse
                )
                return
            }

            markOutgoingAttemptFailed(messageId: activePendingMessageId, pendingTxId: activePendingTxId)
            markPendingMessageFailed(activePendingTxId, contactAddress: contact.address)
            clearNoInputRetryState(for: activePendingTxId)
            saveMessages()
            throw error
        }
    }

    func shouldRetryHandshakeAsResponse(for contactAddress: String) -> Bool {
        guard let conversation = conversations.first(where: { $0.contact.address == contactAddress }) else {
            return false
        }
        return conversation.messages.contains {
            $0.messageType == .handshake && !$0.isOutgoing && $0.deliveryStatus != .failed
        }
    }

    /// Re-fetches a contact's ENTIRE contextual history from block time 0 and decrypts it, once,
    /// at the moment the relationship with them is established (we accept their handshake, or we
    /// message them back).
    ///
    /// Why it is needed - two separate gates conspired to hide the earlier messages:
    ///
    /// 1. Discovery. The contextual endpoint is queried per (sender address, alias) pair, and the
    ///    sweep in `fetchContextualMessages` only visits addresses in
    ///    `routingStates ∪ conversationAliases`. A stranger who has only sent us things is in
    ///    neither, so their messages were never requested at all.
    /// 2. The cursor. Even once they ARE in that set, a contact with no stored
    ///    `SyncObjectCursor` falls back to `lastPollTime - 10 minutes`
    ///    (`syncStartBlockTime`), so the sync asks only for the last few minutes and everything
    ///    older is skipped forever - the cursor is monotonic and never rewinds.
    ///
    /// Nothing is unrecoverable here: contextual messages are stateless ECIES whose ephemeral
    /// public key travels inside the on-chain payload (`KasiaCipher.decrypt`), keyed only by our
    /// long-term wallet key, and deterministic aliases derive from our own seed plus their
    /// address (`DeterministicAlias`). So the whole history can always be re-derived and
    /// re-decrypted after the fact.
    ///
    /// `syncContactHistoryFromGenesis` is the existing routine that does exactly this
    /// (`ensureRoutingState` + `fetchContextualMessagesForActive(fallbackSince: 0,
    /// forceExactBlockTime: true)`, which bypasses both the cursor and the retention clamp and
    /// deliberately does not advance the cursor). It was previously only wired to manual
    /// "Add Contact". Storage is idempotent - `addMessageToConversation` dedupes by txId - so a
    /// redundant run costs bandwidth, never duplicates.
    func recoverPreRelationshipHistory(for contactAddress: String) async {
        await syncContactHistoryFromGenesis(contactAddress)
    }

    func isConversationDeclined(_ address: String) -> Bool {
        declinedContacts.contains(address)
    }

    /// The chat list: not declined, not blocked, and not a Message Request (those sit behind
    /// the list's Message Requests row).
    func isConversationVisibleInChatList(_ conversation: Conversation, settings: AppSettings? = nil) -> Bool {
        !isConversationDeclined(conversation.contact.address)
            && !isChatBlocked(conversation.contact.address)
            && !isMessageRequest(conversation)
    }

    // MARK: - Message Requests (NO_HANDSHAKE_MESSAGING.md)

    private func chatRequestsKey(_ wallet: String) -> String {
        "kachat_chat_requests_v1.\(wallet.lowercased())"
    }

    /// The active wallet's Message Requests state, loaded (or started) on first use. Safe to
    /// read from a view's body: the cache is not published - changes go through
    /// `updateChatRequests`, which bumps `chatRequestsRevision`.
    func chatRequestState() -> ChatRequestState {
        guard let wallet = WalletManager.shared.currentWallet?.publicAddress.lowercased() else {
            return ChatRequestState()
        }
        if let cached = chatRequestCache[wallet] { return cached }
        let key = chatRequestsKey(wallet)
        let state: ChatRequestState
        if let data = userDefaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(ChatRequestState.self, from: data) {
            state = decoded
        } else {
            // First run with Message Requests: everything already here stays an ordinary chat.
            state = ChatRequestState()
            if let data = try? JSONEncoder().encode(state) { userDefaults.set(data, forKey: key) }
        }
        chatRequestCache[wallet] = state
        return state
    }

    func updateChatRequests(_ change: (inout ChatRequestState) -> Void) {
        guard let wallet = WalletManager.shared.currentWallet?.publicAddress.lowercased() else { return }
        var state = chatRequestState()
        change(&state)
        chatRequestCache[wallet] = state
        if let data = try? JSONEncoder().encode(state) {
            userDefaults.set(data, forKey: chatRequestsKey(wallet))
        }
        chatRequestsRevision &+= 1
    }

    func isChatBlocked(_ address: String) -> Bool {
        chatRequestState().blocked.contains(address.lowercased())
    }

    func isPrivateChat(_ address: String) -> Bool {
        chatRequestState().privateChats.contains(address.lowercased())
    }

    /// A conversation someone else started that the user hasn't accepted. Writing to them, a
    /// manually added contact, an explicit Accept, or a chat that already existed when Message
    /// Requests arrived (its first message predates `startedAt`) all make it an ordinary chat.
    func isMessageRequest(_ conversation: Conversation) -> Bool {
        let address = conversation.contact.address.lowercased()
        if address == WalletManager.shared.currentWallet?.publicAddress.lowercased() { return false }
        let state = chatRequestState()
        if state.accepted.contains(address) || state.privateChats.contains(address) || state.blocked.contains(address) {
            return false
        }
        let contact = contactsManager.getContact(byAddress: conversation.contact.address) ?? conversation.contact
        guard contact.isAutoAdded, !contact.hasSentOutgoingMessage else { return false }
        if conversation.messages.contains(where: { $0.isOutgoing }) { return false }
        guard let first = conversation.messages.lazy.map(\.timestamp).min() else { return false }
        return first >= state.startedAt
    }

    /// Chats that existed before Message Requests arrived stay ordinary chats for good. Decided
    /// from the oldest STORED message, once, and recorded as accepted: `isMessageRequest` only
    /// sees the messages held in memory (the newest 160), so an old chat whose early messages
    /// were trimmed (or removed by retention) used to turn into a request - leaving the chat list
    /// and the push watch list. Runs after the initial sync.
    func grandfatherPreexistingChats() async {
        let state = chatRequestState()
        let candidates = conversations.filter { conversation in
            let address = conversation.contact.address.lowercased()
            if state.accepted.contains(address) || state.privateChats.contains(address) || state.blocked.contains(address) { return false }
            let contact = contactsManager.getContact(byAddress: conversation.contact.address) ?? conversation.contact
            return contact.isAutoAdded && !contact.hasSentOutgoingMessage
        }
        var preexisting: [String] = []
        for conversation in candidates {
            if let first = await messageStore.earliestMessageDate(contactAddress: conversation.contact.address),
               first < state.startedAt {
                preexisting.append(conversation.contact.address.lowercased())
            }
        }
        guard !preexisting.isEmpty else { return }
        AppLog.log("[ChatService] %d chat(s) from before Message Requests kept as ordinary chats", preexisting.count)
        updateChatRequests { $0.accepted.formUnion(preexisting) }
    }

    /// How many chats wait in Message Requests - the chat list's row reads this on every draw,
    /// so it counts without building and sorting the list.
    var messageRequestCount: Int {
        conversations.lazy.filter { self.isMessageRequest($0) }.count
    }

    /// Message Requests, newest first.
    var messageRequests: [Conversation] {
        conversations
            .filter { isMessageRequest($0) }
            .sorted { ($0.lastMessage?.timestamp ?? .distantPast) > ($1.lastMessage?.timestamp ?? .distantPast) }
    }

    /// Accept: the chat joins the chat list. Nothing is sent on chain. Also what writing to
    /// someone does - and it lifts a block, since messaging them is consent.
    func acceptChat(_ address: String) {
        let key = address.lowercased()
        let state = chatRequestState()
        if state.accepted.contains(key), !state.blocked.contains(key), !declinedContacts.contains(address) { return }
        updateChatRequests {
            $0.accepted.insert(key)
            $0.blocked.remove(key)
        }
        clearDeclined(address)
    }

    /// Whether the configured indexer answers inbox lookups - probed once per indexer URL; an
    /// unreachable indexer is asked again next time.
    func inboxSupported() async -> Bool {
        let base = apiClient.currentBaseURL ?? ""
        if let known = inboxSupportByIndexer[base] { return known }
        guard let answer = await apiClient.probeInboxSupport() else { return false }
        inboxSupportByIndexer[base] = answer
        return answer
    }

    /// The inbox tag for a message to `address`, or nil to send it untagged. Only the FIRST
    /// message carries it - one tagged message tells the recipient who wrote, and their app
    /// fetches everything after it by sender and alias, unlinked; tagging more would show how
    /// often you wrote. So: not once a tagged message has gone out to them (`inboxTagged`, set on
    /// a successful submit, so a failed one doesn't use it up), not once they have written to us,
    /// never in a Private chat, and only when the indexer files `dm` - one that doesn't know it
    /// drops the transaction from its index altogether.
    ///
    /// Only a MESSAGE from them counts as "written to us" - a payment does not. Someone who just
    /// sent KAS (a wallet send, or a chat payment) may have no chat with us at all, so an untagged
    /// reply would never reach them. Tagging costs nothing there: the payment already links the
    /// two addresses on chain.
    func firstContactInboxTag(for address: String) async -> String? {
        let me = WalletManager.shared.currentWallet?.publicAddress.lowercased()
        guard address.lowercased() != me, !isPrivateChat(address),
              !chatRequestState().inboxTagged.contains(address.lowercased()) else { return nil }
        // addresses compare case-insensitively everywhere else in this check: an address typed
        // or scanned in upper case is still the established conversation
        let lowered = address.lowercased()
        let heardFrom = conversations.first { $0.contact.address.lowercased() == lowered }?
            .messages.contains { !$0.isOutgoing && $0.messageType != .payment } ?? false
        guard !heardFrom, await inboxSupported() else { return nil }
        return InboxTag.compute(for: address)
    }

    /// Finds people who wrote to this wallet first: asks the indexer for our inbox tag, then pulls
    /// each new sender's whole history the normal way (sender + alias). Blocked senders are
    /// skipped. Their chat lands in Message Requests (`isMessageRequest`).
    func syncInbox() async {
        guard !inboxSyncInFlight,
              let wallet = WalletManager.shared.currentWallet?.publicAddress,
              await inboxSupported() else { return }
        inboxSyncInFlight = true
        defer { inboxSyncInFlight = false }
        let since = chatRequestState().inboxCursor
        guard let found = try? await apiClient.getContextualMessagesByInbox(
            tag: InboxTag.compute(for: wallet),
            blockTime: since
        ), isActiveWallet(wallet) else { return }
        // The cursor moves to the newest entry - but never past one whose sender the indexer
        // hasn't resolved yet (it answers with an empty sender until the spent input is known):
        // that entry is asked for again next time, or its sender would never be found.
        let unresolvedTimes = found.filter { $0.sender.isEmpty }.compactMap(\.blockTime)
        let resolvedNewest = found.filter { !$0.sender.isEmpty }.compactMap(\.blockTime).max()
        let nextCursor = unresolvedTimes.min().map { min($0 > 0 ? $0 - 1 : 0, resolvedNewest ?? 0) } ?? resolvedNewest
        if let nextCursor, nextCursor > since {
            updateChatRequests { $0.inboxCursor = nextCursor }
        }
        var senders: [String] = []
        for message in found {
            let sender = message.sender
            guard !sender.isEmpty, sender.lowercased() != wallet.lowercased(),
                  !isChatBlocked(sender), !senders.contains(sender) else { continue }
            senders.append(sender)
        }
        // Someone already known is fetched by the ordinary sweep (it has their aliases); only a
        // new sender needs their whole history pulled once.
        for sender in senders where routingStates[sender] == nil {
            guard isActiveWallet(wallet) else { return }
            _ = contactsManager.getOrCreateContact(address: sender)
            await syncContactHistoryFromGenesis(sender)
        }
    }

    func pushEligibleConversationAddresses(settings: AppSettings? = nil) -> [String] {
        let settings = settings ?? currentSettings
        var addresses = Set<String>()
        for conversation in conversations {
            guard isConversationVisibleInChatList(conversation, settings: settings) else { continue }
            let contact = contactsManager.getContact(byAddress: conversation.contact.address) ?? conversation.contact
            guard settings.shouldDeliverIncomingNotification(for: contact) else { continue }
            let candidate = contact.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard contactsManager.isValidKaspaAddress(candidate) else { continue }
            addresses.insert(candidate.lowercased())
        }
        return Array(addresses)
    }

    /// Generate a random alias for a new conversation
    func generateAlias() -> String {
        // Generate 6 random bytes and convert to hex (12 characters)
        var bytes = [UInt8](repeating: 0, count: 6)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Fallback: use UUID bytes for non-security-critical alias
            let uuid = UUID()
            return withUnsafeBytes(of: uuid.uuid) { Data($0).prefix(6).map { String(format: "%02x", $0) }.joined() }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func generateConversationId() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return String(uuid.prefix(12)).lowercased()
    }

    func updateWalletBalanceIfNeeded(address: String, utxos: [UTXO]) {
        WalletManager.shared.updateBalanceIfCurrentWallet(address: address, utxos: utxos)
    }

    /// Split UTXOs so that handshake gets a minimal covering set and self-stash can use the rest
    func splitUtxosForHandshake(_ utxos: [UTXO]) -> ([UTXO], [UTXO]) {
        guard utxos.count > 1 else {
            return (utxos, [])
        }

        // Reserve the smallest UTXO for self-stash if possible; the handshake takes the largest
        // of the rest first, so it needs as few inputs as possible.
        let sortedAsc = utxos.sorted { $0.amount < $1.amount }
        let remaining = Array(sortedAsc.dropFirst().reversed())

        let target: UInt64 = KasiaTransactionBuilder.handshakeAmount + 50_000 // padding for fee
        var selected: [UTXO] = []
        var total: UInt64 = 0
        for utxo in remaining {
            selected.append(utxo)
            let (nextTotal, overflow) = total.addingReportingOverflow(utxo.amount)
            if overflow {
                AppLog.log("[ChatService] Overflow while splitting handshake UTXOs; falling back to full set")
                return (utxos, [])
            }
            total = nextTotal
            if total >= target {
                break
            }
        }

        if total >= target {
            let handshakeIds = Set(selected.map { "\($0.outpoint.transactionId):\($0.outpoint.index)" })
            let stashUtxos = utxos.filter { !handshakeIds.contains("\($0.outpoint.transactionId):\($0.outpoint.index)") }
            return (selected, stashUtxos)
        } else {
            // Not enough without reserved; fall back to all UTXOs (stash later)
            return (utxos, [])
        }
    }

    func connectRpcIfNeeded(timeout: TimeInterval = 30.0) async throws {
        let rpcManager = NodePoolService.shared
        if rpcManager.isConnected {
            return
        }

        let settings = currentSettings

        // Use gRPC manager for connection with timeout
        AppLog.log("[ChatService] Connecting via RPC manager (timeout: %.1fs)...", timeout)

        // Race between connection and timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await rpcManager.connect(network: settings.networkType)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw KasiaError.networkError("RPC connection timeout")
            }

            // Wait for first to complete (either success or timeout)
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// The address `cachedUtxos` was read for: the cache holds one address at a time, and another
    /// address's coins must never be answered from it.
    private static var cachedUtxosAddress: String?

    func fetchCachedUtxos(for address: String) async throws -> [UTXO] {
        if Self.cachedUtxosAddress == address,
           let timestamp = cachedUtxosTimestamp,
           Date().timeIntervalSince(timestamp) < utxoCacheInterval,
           !cachedUtxos.isEmpty {
            return cachedUtxos
        }

        let utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
        updateWalletBalanceIfNeeded(address: address, utxos: utxos)
        cachedUtxos = utxos
        cachedUtxosTimestamp = Date()
        Self.cachedUtxosAddress = address
        return utxos
    }

    /// Fetch UTXOs with automatic fallback - tries gRPC if connected, otherwise uses REST API
    /// This is useful for fee estimation where we don't want to block waiting for gRPC connection
    func fetchUtxosWithFallback(for address: String) async throws -> [UTXO] {
        // Check cache first
        if Self.cachedUtxosAddress == address,
           let timestamp = cachedUtxosTimestamp,
           Date().timeIntervalSince(timestamp) < utxoCacheInterval,
           !cachedUtxos.isEmpty {
            return cachedUtxos
        }

        // getUtxosByAddresses already has REST fallback built in
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
        updateWalletBalanceIfNeeded(address: address, utxos: utxos)
        cachedUtxos = utxos
        cachedUtxosTimestamp = Date()
        Self.cachedUtxosAddress = address
        return utxos
    }

    func splitUtxosForSelfStash(_ utxos: [UTXO]) -> ([UTXO], [UTXO]) {
        guard let first = utxos.first else { return ([], []) }
        return ([first], Array(utxos.dropFirst()))
    }

    func sendOrQueueSelfStash(
        contactAddress: String,
        ourAlias: String,
        theirAlias: String?,
        isResponse: Bool,
        walletAddress: String,
        privateKey: Data,
        utxos: [UTXO],
        handshakeTx: KaspaRpcTransaction?,
        handshakeTxId: String?,
        senderScriptPubKey: Data?
    ) async {
        guard !utxos.isEmpty else {
            // Try to build from handshake change if possible
            if let handshakeTx = handshakeTx,
               let senderScriptPubKey = senderScriptPubKey,
               let change = changeUtxo(from: handshakeTx, txId: handshakeTxId, senderScript: senderScriptPubKey) {
                await submitSelfStashTx(
                    contactAddress: contactAddress,
                    ourAlias: ourAlias,
                    theirAlias: theirAlias,
                    isResponse: isResponse,
                    walletAddress: walletAddress,
                    privateKey: privateKey,
                    utxos: [change],
                    allowOrphan: true
                )
                return
            }

            queueSelfStash(contactAddress: contactAddress, ourAlias: ourAlias, theirAlias: theirAlias, isResponse: isResponse)
            return
        }
        await submitSelfStashTx(
            contactAddress: contactAddress,
            ourAlias: ourAlias,
            theirAlias: theirAlias,
            isResponse: isResponse,
            walletAddress: walletAddress,
            privateKey: privateKey,
            utxos: utxos,
            allowOrphan: false
        )
    }

    func queueSelfStash(contactAddress: String, ourAlias: String, theirAlias: String?, isResponse: Bool) {
        let job = PendingSelfStash(partnerAddress: contactAddress, ourAlias: ourAlias, theirAlias: theirAlias, isResponse: isResponse)
        pendingSelfStash.append(job)
        savePendingSelfStash()
        AppLog.log("%@", "[ChatService] Queued self-stash for \(contactAddress.suffix(10))")
    }

    // MARK: - Contact notes for chats without a handshake

    /// A chat that never had a handshake (deterministic aliases) leaves nothing on chain that a
    /// fresh import of the seed could find it by: its messages carry aliases derived from both
    /// keys, and an alias cannot be turned back into an address. So the first time you message
    /// such a contact, a contact-only `saved_handshake` note is written - the partner's address,
    /// encrypted to yourself, in a transaction to yourself - and `fetchSavedHandshakes` on the
    /// new device turns it back into the chat. Once per contact, and only after a complete
    /// read-back of the notes already on chain, so it never writes one that exists.
    func ensureContactStash(for contactAddress: String, flushQueuedStashes: Bool = true) {
        guard let wallet = WalletManager.shared.currentWallet?.publicAddress,
              contactAddress != wallet else { return }
        loadContactStashStateIfNeeded(wallet: wallet)
        guard contactStashIndexComplete,
              !contactStashKnownAddresses.contains(contactAddress),
              !pendingSelfStash.contains(where: { $0.partnerAddress == contactAddress }),
              needsContactStash(contactAddress) else { return }
        let job = PendingSelfStash(partnerAddress: contactAddress, ourAlias: "", theirAlias: nil, isResponse: false, contactOnly: true)
        pendingSelfStash.append(job)
        savePendingSelfStash()
        AppLog.log("%@", "[ChatService] Queued contact note for \(contactAddress.suffix(10))")
        if flushQueuedStashes { Task { [weak self] in await self?.attemptPendingSelfStashSends() } }
    }

    /// Only chats with no handshake need one: a handshake chat is found again by its handshake
    /// (and already writes its own note). Deterministic-only routing and no handshake message.
    private func needsContactStash(_ contactAddress: String) -> Bool {
        guard routingStates[contactAddress]?.mode == .deterministicOnly else { return false }
        if let conversation = conversations.first(where: { $0.contact.address == contactAddress }),
           conversation.messages.contains(where: { $0.messageType == .handshake }) {
            return false
        }
        return true
    }

    /// Old chats, from before notes were written for them: every chat without a handshake that
    /// you have sent a message in and that has no note gets one. Runs after each complete
    /// read-back (`fetchSavedHandshakes`); a chat already noted or queued is skipped, so it only
    /// ever writes what is missing. Each note is its own small transaction through the pending
    /// queue, which sends as many as there are spare coins and keeps the rest for the next sync.
    func backfillContactStashes() {
        guard let wallet = WalletManager.shared.currentWallet?.publicAddress else { return }
        loadContactStashStateIfNeeded(wallet: wallet)
        guard contactStashIndexComplete else { return }
        for conversation in conversations {
            let address = conversation.contact.address
            let hasSent = conversation.contact.hasSentOutgoingMessage
                || contactsManager.getContact(byAddress: address)?.hasSentOutgoingMessage == true
                || conversation.messages.contains(where: { $0.isOutgoing })
            guard hasSent else { continue }
            ensureContactStash(for: address, flushQueuedStashes: false)
        }
        // One send pass for the whole batch, not one per queued note.
        Task { [weak self] in await self?.attemptPendingSelfStashSends() }
    }

    /// Records that `contactAddress` has (or is getting) a note.
    func noteContactStashed(_ contactAddress: String) {
        guard let wallet = WalletManager.shared.currentWallet?.publicAddress, !contactAddress.isEmpty else { return }
        loadContactStashStateIfNeeded(wallet: wallet)
        guard contactStashKnownAddresses.insert(contactAddress).inserted else { return }
        saveContactStashState(wallet: wallet)
    }

    /// Called by `fetchSavedHandshakes` with every contact a note was read back for, and whether
    /// the read-back covered the whole history (a full scan).
    func recordContactStashes(_ addresses: Set<String>, completeScan: Bool, wallet: String) {
        loadContactStashStateIfNeeded(wallet: wallet)
        let before = contactStashKnownAddresses.count
        contactStashKnownAddresses.formUnion(addresses.filter { !$0.isEmpty })
        let becameComplete = completeScan && !contactStashIndexComplete
        if becameComplete { contactStashIndexComplete = true }
        if contactStashKnownAddresses.count != before || becameComplete {
            saveContactStashState(wallet: wallet)
        }
    }

    func loadContactStashStateIfNeeded(wallet: String) {
        guard contactStashStateWallet != wallet else { return }
        contactStashStateWallet = wallet
        let known = userDefaults.stringArray(forKey: "kachat_contact_stash_known_\(wallet)") ?? []
        contactStashKnownAddresses = Set(known)
        contactStashIndexComplete = userDefaults.bool(forKey: "kachat_contact_stash_complete_\(wallet)")
    }

    private func saveContactStashState(wallet: String) {
        userDefaults.set(Array(contactStashKnownAddresses), forKey: "kachat_contact_stash_known_\(wallet)")
        userDefaults.set(contactStashIndexComplete, forKey: "kachat_contact_stash_complete_\(wallet)")
    }

    func submitSelfStashTx(
        contactAddress: String,
        ourAlias: String,
        theirAlias: String?,
        isResponse: Bool,
        walletAddress: String,
        privateKey: Data,
        utxos: [UTXO],
        allowOrphan: Bool
    ) async {
        do {
            let stashTx = try KasiaTransactionBuilder.buildHandshakeSelfStashTx(
                from: walletAddress,
                partnerAddress: contactAddress,
                ourAlias: ourAlias,
                theirAlias: theirAlias,
                isResponse: isResponse,
                senderPrivateKey: privateKey,
                utxos: utxos
            )
            let txId = try await NodePoolService.shared.submitTransaction(stashTx, allowOrphan: allowOrphan)
            AppLog.log("%@", "[ChatService] Self-stash handshake submitted: \(txId)")
        } catch {
            AppLog.log("%@", "[ChatService] Failed to submit self-stash handshake tx: \(error.localizedDescription)")
            queueSelfStash(contactAddress: contactAddress, ourAlias: ourAlias, theirAlias: theirAlias, isResponse: isResponse)
        }
    }

    func changeUtxo(from handshakeTx: KaspaRpcTransaction, txId: String?, senderScript: Data) -> UTXO? {
        guard let txId = txId else { return nil }
        for (idx, output) in handshakeTx.outputs.enumerated() {
            if output.scriptPublicKey.script == senderScript, output.value > 0 {
                return UTXO(
                    address: "",
                    outpoint: UTXO.Outpoint(transactionId: txId, index: UInt32(idx)),
                    amount: output.value,
                    scriptPublicKey: senderScript,
                    blockDaaScore: 0,
                    isCoinbase: false
                )
            }
        }
        return nil
    }

    /// Attempt to send any queued self-stash handshake transactions using current UTXOs
    func attemptPendingSelfStashSends() async {
        guard let wallet = WalletManager.shared.currentWallet,
              let privateKey = WalletManager.shared.getPrivateKey(),
              !pendingSelfStash.isEmpty,
              !isFlushingSelfStash else { return }
        // One pass at a time: two overlapping passes read the same queue, and the second could
        // spend the first one's fresh change on the same note - a duplicate and a second fee.
        isFlushingSelfStash = true
        defer { isFlushingSelfStash = false }

        do {
            let rpcManager = NodePoolService.shared
            if !rpcManager.isConnected {
                let settings = currentSettings
                try await rpcManager.connect(network: settings.networkType)
            }

            let utxos = try await rpcManager.getUtxosByAddresses([wallet.publicAddress])
            updateWalletBalanceIfNeeded(address: wallet.publicAddress, utxos: utxos)
            guard !utxos.isEmpty else { return }

            var remaining = utxos
            var succeeded: [PendingSelfStash] = []

            for job in pendingSelfStash {
                guard !remaining.isEmpty else { break }
                let (first, rest) = splitUtxosForSelfStash(remaining)
                remaining = rest
                do {
                    let stashTx = job.contactOnly == true
                        ? try KasiaTransactionBuilder.buildContactSelfStashTx(
                            from: wallet.publicAddress,
                            partnerAddress: job.partnerAddress,
                            senderPrivateKey: privateKey,
                            utxos: first
                        )
                        : try KasiaTransactionBuilder.buildHandshakeSelfStashTx(
                            from: wallet.publicAddress,
                            partnerAddress: job.partnerAddress,
                            ourAlias: job.ourAlias,
                            theirAlias: job.theirAlias,
                            isResponse: job.isResponse,
                            senderPrivateKey: privateKey,
                            utxos: first
                        )
                    let (txId, endpoint) = try await rpcManager.submitTransaction(stashTx, allowOrphan: false)
                    AppLog.log("[ChatService] Self-stash submitted: \(txId) via \(endpoint)")
                    succeeded.append(job)
                    // Noted only once it is actually on its way: the queue does not survive a
                    // wallet switch, and a note marked at queue time would never be written.
                    noteContactStashed(job.partnerAddress)
                } catch {
                    AppLog.log("%@", "[ChatService] Pending self-stash failed: \(error.localizedDescription)")
                }
            }

            if !succeeded.isEmpty {
                pendingSelfStash.removeAll { job in
                    succeeded.contains(where: { $0.id == job.id })
                }
                savePendingSelfStash()
            }
        } catch {
            AppLog.log("%@", "[ChatService] attemptPendingSelfStashSends error: \(error.localizedDescription)")
        }
    }

    /// Update a pending message with the real transaction ID
    @discardableResult
    func updatePendingMessage(_ pendingTxId: String, withRealTxId txId: String, contactAddress: String) -> Bool {
        if let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            if updatePendingMessage(in: convIndex, pendingTxId: pendingTxId, withRealTxId: txId) {
                removePendingOutgoingGlobally(pendingTxId)
                return true
            }
        }

        if let convIndex = conversations.firstIndex(where: { conversation in
            conversation.messages.contains(where: { $0.txId == pendingTxId })
        }) {
            if updatePendingMessage(in: convIndex, pendingTxId: pendingTxId, withRealTxId: txId) {
                removePendingOutgoingGlobally(pendingTxId)
                return true
            }
        }

        return false
    }

    @discardableResult
    func updatePendingMessage(in convIndex: Int, pendingTxId: String, withRealTxId txId: String) -> Bool {
        updateConversation(at: convIndex) { conversation in
            guard let msgIndex = conversation.messages.firstIndex(where: { $0.txId == pendingTxId }) else { return }
            let oldMessage = conversation.messages[msgIndex]
            if pendingTxId != txId {
                conversation.messages.removeAll(where: { $0.txId == txId })
            }
            let newMessage = ChatMessage(
                id: oldMessage.id,
                txId: txId,
                senderAddress: oldMessage.senderAddress,
                receiverAddress: oldMessage.receiverAddress,
                content: oldMessage.content,
                timestamp: oldMessage.timestamp,
                blockTime: oldMessage.blockTime,
                acceptingBlock: "mempool",
                isOutgoing: oldMessage.isOutgoing,
                messageType: oldMessage.messageType,
                deliveryStatus: .sent
            )
            conversation.messages[msgIndex] = newMessage
        }

        return true
    }

    /// Mark a pending message as failed (keeps it in the conversation for retry)
    func markPendingMessageFailed(_ pendingTxId: String, contactAddress: String) {
        if let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            updateConversation(at: convIndex) { conversation in
                if let msgIndex = conversation.messages.firstIndex(where: { $0.txId == pendingTxId }) {
                    let oldMessage = conversation.messages[msgIndex]
                    let updatedMessage = ChatMessage(
                        id: oldMessage.id,
                        txId: oldMessage.txId,
                        senderAddress: oldMessage.senderAddress,
                        receiverAddress: oldMessage.receiverAddress,
                        content: oldMessage.content,
                        timestamp: oldMessage.timestamp,
                        blockTime: oldMessage.blockTime,
                        acceptingBlock: oldMessage.acceptingBlock,
                        isOutgoing: oldMessage.isOutgoing,
                        messageType: oldMessage.messageType,
                        deliveryStatus: .failed
                    )
                    conversation.messages[msgIndex] = updatedMessage
                }
            }
        }
        markOutgoingAttemptFailed(messageId: resolveMessageIdForPending(contactAddress: contactAddress, pendingTxId: pendingTxId), pendingTxId: pendingTxId)
        removePendingOutgoing(contactAddress: contactAddress, pendingTxId: pendingTxId)
        clearNoInputRetryState(for: pendingTxId)
    }

    func resetPendingMessage(_ pendingTxId: String, contactAddress: String) {
        if let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            updateConversation(at: convIndex) { conversation in
                if let msgIndex = conversation.messages.firstIndex(where: { $0.txId == pendingTxId }) {
                    let oldMessage = conversation.messages[msgIndex]
                    let updatedMessage = ChatMessage(
                        id: oldMessage.id,
                        txId: oldMessage.txId,
                        senderAddress: oldMessage.senderAddress,
                        receiverAddress: oldMessage.receiverAddress,
                        content: oldMessage.content,
                        timestamp: oldMessage.timestamp,
                        blockTime: oldMessage.blockTime,
                        acceptingBlock: oldMessage.acceptingBlock,
                        isOutgoing: oldMessage.isOutgoing,
                        messageType: oldMessage.messageType,
                        deliveryStatus: .pending
                    )
                    conversation.messages[msgIndex] = updatedMessage
                }
            }
        }
        if let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            let pending = conversations[convIndex].messages.first(where: { $0.txId == pendingTxId })
            if let pending {
                enqueuePendingOutgoing(contactAddress: contactAddress, pendingTxId: pendingTxId, messageType: pending.messageType, timestamp: pending.timestamp)
            }
        }
    }

    func updateOutgoingPendingMessageIfMatch(
        contactAddress: String,
        newTxId: String,
        content: String,
        messageType: ChatMessage.MessageType
    ) -> Bool {
        guard let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else {
            return false
        }

        var didUpdate = false
        updateConversation(at: convIndex) { conversation in
            if let existingIndex = conversation.messages.firstIndex(where: { $0.txId == newTxId }) {
                let existing = conversation.messages[existingIndex]
                if existing.isOutgoing && existing.deliveryStatus != .sent {
                    let updated = ChatMessage(
                        id: existing.id,
                        txId: existing.txId,
                        senderAddress: existing.senderAddress,
                        receiverAddress: existing.receiverAddress,
                        content: existing.content,
                        timestamp: existing.timestamp,
                        blockTime: existing.blockTime,
                        acceptingBlock: existing.acceptingBlock ?? "mempool",
                        isOutgoing: existing.isOutgoing,
                        messageType: existing.messageType,
                        deliveryStatus: .sent
                    )
                    conversation.messages[existingIndex] = updated
                }
                didUpdate = true
                return
            }

            // Do not match by content; duplicates are allowed. Pending promotion is handled by queue order.
        }

        return didUpdate
    }

    @discardableResult
    func updatePendingMessageById(
        _ messageId: UUID,
        newTxId: String,
        contactAddress: String? = nil
    ) -> Bool {
        let targetIndex: Int?
        if let contactAddress,
           let index = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            targetIndex = index
        } else {
            targetIndex = conversations.firstIndex(where: { conversation in
                conversation.messages.contains(where: { $0.id == messageId })
            })
        }

        guard let convIndex = targetIndex else { return false }

        var didUpdate = false
        var oldPendingTxId: String?
        updateConversation(at: convIndex) { conversation in
            guard let msgIndex = conversation.messages.firstIndex(where: { $0.id == messageId }) else { return }
            let oldMessage = conversation.messages[msgIndex]
            oldPendingTxId = oldMessage.txId
            if oldMessage.txId != newTxId {
                conversation.messages.removeAll(where: { $0.txId == newTxId })
            }
            let newMessage = ChatMessage(
                id: oldMessage.id,
                txId: newTxId,
                senderAddress: oldMessage.senderAddress,
                receiverAddress: oldMessage.receiverAddress,
                content: oldMessage.content,
                timestamp: oldMessage.timestamp,
                blockTime: oldMessage.blockTime,
                acceptingBlock: "mempool",
                isOutgoing: oldMessage.isOutgoing,
                messageType: oldMessage.messageType,
                deliveryStatus: .sent
            )
            conversation.messages[msgIndex] = newMessage
            didUpdate = true
        }

        guard didUpdate, let oldPendingTxId else { return false }
        removePendingOutgoingGlobally(oldPendingTxId)
        return true
    }

    func updateOldestPendingOutgoingMessage(
        contactAddress: String,
        newTxId: String,
        messageType: ChatMessage.MessageType
    ) -> Bool {
        guard let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else {
            return false
        }

        var didUpdate = false
        var oldPendingTxId: String?
        updateConversation(at: convIndex) { conversation in
            let candidates = conversation.messages
                .filter { $0.isOutgoing && $0.deliveryStatus != .sent && $0.messageType == messageType }
                .sorted(by: Self.isMessageOrderedBefore)
            guard let candidate = candidates.first,
                  let msgIndex = conversation.messages.firstIndex(where: { $0.id == candidate.id }) else { return }

            if candidate.txId != newTxId {
                conversation.messages.removeAll(where: { $0.txId == newTxId })
            }
            oldPendingTxId = candidate.txId
            let newMessage = ChatMessage(
                id: candidate.id,
                txId: newTxId,
                senderAddress: candidate.senderAddress,
                receiverAddress: candidate.receiverAddress,
                content: candidate.content,
                timestamp: candidate.timestamp,
                blockTime: candidate.blockTime,
                acceptingBlock: candidate.acceptingBlock ?? "mempool",
                isOutgoing: candidate.isOutgoing,
                messageType: candidate.messageType,
                deliveryStatus: .sent
            )
            conversation.messages[msgIndex] = newMessage
            didUpdate = true
        }

        guard didUpdate, let oldPendingTxId else { return false }
        removePendingOutgoing(contactAddress: contactAddress, pendingTxId: oldPendingTxId)
        return true
    }

    // MARK: - Private Methods

    /// Check the Kasia indexer for a handshake matching the given txId
    /// Used as fallback when the Kaspa REST API doesn't return the transaction payload
}

/// Response of `GET /addresses/{address}/transactions-count` on the Kaspa REST API — the
/// one-integer body backing `spendingAddressUsedState`. Extra fields (e.g. `limit_exceeded`
/// on newer servers) are ignored by the decoder.
private struct KaspaAddressTransactionsCountResponse: Decodable {
    let total: Int
}

/// The post a KaPosts tip is for (KAPOSTS_INDEXER.md 5.11): its txid and its author's pubkey.
struct KaPostTip: Equatable {
    let postId: String
    let authorPubkey: String
}

/// A send built at the swipe would pay more than its Review showed: its coins changed in between
/// (`ChatService.checkFeeAgainstReview`). Nothing was sent; the Review works its fee out again.
struct SendFeeChangedError: LocalizedError {
    let feeSompi: UInt64
    var errorDescription: String? {
        String(format: AppLocalization.string("The network fee is now %@ KAS, more than the Review showed. Nothing was sent: check the new fee and swipe again."),
               locale: AppLocalization.locale, KaspaUnit.plain(feeSompi))
    }
}

/// A plain send that ended on "Not confirmed" (`ChatService.holdUnknownOutcomeSend`).
private struct UnresolvedSend: Codable {
    let txId: String
    let source: String
    let recipient: String
    let outpointKeys: [String]
    let sentAt: Date
}
