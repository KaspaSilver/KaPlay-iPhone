import Foundation
import Combine
import UIKit
import UserNotifications
import CryptoKit

// MARK: - Push notifications, sync orchestration, UTXO subscriptions, archive

extension ChatService {
    /// Retry RPC subscription with 1s wait when all nodes exhausted
    /// Public method to re-setup UTXO subscription after manual reconnect
    /// Pause UTXO subscription on iOS when remote push is enabled and app goes to background
    /// Resume UTXO subscription on iOS when app becomes active in remote push mode
    /// Update UTXO subscription to include a new contact address
    /// Force a one-contact historical contextual sync from genesis (`blockTime = 0`).
    /// Used after manually adding a new contact so old messages are not skipped by adaptive cursors.
    /// Check if resubscription is needed due to new conversations/contacts
    /// Defers resubscription until sync completes to avoid interrupting sync
    /// Called at the end of sync to trigger deferred resubscription if needed
    // MARK: - Push Notification Message Handling

    /// Add a message that was decrypted by the notification extension or fetched from push
    struct ChatHistoryImportSummary {
        let conversationCount: Int
        let messageCount: Int
        let filledSentContentCount: Int
    }

    /// Stage events emitted by `importChatHistoryArchive` so the restore progress modal can
    /// show a determinate bar. `.importing` advances per conversation as the Core Data write
    /// in `MessageStore.syncFromConversations` progresses (real work, not simulated).
    enum ChatHistoryImportProgress {
        case validating
        case preparing
        case importing(done: Int, total: Int)
        case finalizing
    }

    enum ChatHistoryArchiveError: LocalizedError {
        case encryptionKeyUnavailable
        case unsupportedVersion(Int)
        case emptyArchive
        case remoteBackupUnreadable
        case remoteBackupIncompatible(Int)
        case remoteBackupForeignWallet

        var errorDescription: String? {
            switch self {
            case .encryptionKeyUnavailable:
                return "Failed to access wallet encryption key."
            case .unsupportedVersion(let version):
                return "Unsupported chat history format (version \(version))."
            case .emptyArchive:
                return "No messages found in the selected archive."
            case .remoteBackupUnreadable:
                return "The file already on the server isn't a KaChat backup. Nothing was uploaded and it was left untouched. Pick a different backup folder."
            case .remoteBackupIncompatible(let version):
                return "The backup already on the server uses schema version \(version), which this version can't merge. Nothing was uploaded and it was left untouched."
            case .remoteBackupForeignWallet:
                return "The backup already on the server belongs to a different wallet. Nothing was uploaded. Choose a separate backup folder for this account."
            }
        }
    }

    func maybeRunCatchUpSync(trigger: CatchUpSyncTrigger, force: Bool = false) async {
        refreshPushReliabilityPrerequisites()

        let shouldDebounce = !force &&
            isPushChannelOperational() &&
            pushReliabilityState == .reliable

        if shouldDebounce,
           let last = lastCatchUpSyncAt,
           Date().timeIntervalSince(last) < reliablePushCatchUpDebounce {
            AppLog.log("[ChatService] Skipping catch-up sync (%@) - push reliable and debounce active",
                  trigger.rawValue)
            // Pushes cover messages, but a plain KAS payment gets none: the payments a gap may
            // have missed are still fetched (two requests).
            await fetchMissedPaymentsIfNeeded()
            return
        }

        if catchUpSyncInFlight {
            AppLog.log("[ChatService] Skipping catch-up sync (%@) - catch-up already in flight",
                  trigger.rawValue)
            return
        }

        catchUpSyncInFlight = true
        defer { catchUpSyncInFlight = false }

        AppLog.log("[ChatService] Running catch-up sync (%@), pushState=%@ force=%@",
              trigger.rawValue, pushReliabilityState.rawValue, force ? "true" : "false")
        await fetchNewMessages()
        lastCatchUpSyncAt = Date()
        persistPushReliabilityState()
    }

    func startPolling(interval: TimeInterval = 10.0) {
        guard WalletManager.shared.currentWallet != nil else {
            startPollingWhenStoreReadyTask?.cancel()
            startPollingWhenStoreReadyTask = nil
            return
        }
        // The setup wizard owns the screen: nothing syncs underneath it. `releaseSyncForOnboarding`
        // calls back in here once the user is through.
        guard !onboardingSyncHeld else {
            AppLog.log("%@", "[ChatService] startPolling deferred: onboarding in progress")
            return
        }
        guard isMessageStoreReadyForCurrentWallet() else {
            scheduleStartPollingWhenStoreReady(interval: interval)
            return
        }
        startPollingWhenStoreReadyTask?.cancel()
        startPollingWhenStoreReadyTask = nil

        // Wallet loaded + store ready: make sure the foreground contact sweep is running (no-op
        // if it already is). It self-gates on app-active and on the initial sync having finished,
        // so starting it here is safe on every startPolling() call, including tab re-entry.
        if Self.syncsChats { startForegroundContactSweep() }

        // If initial sync already completed (e.g. Mac Catalyst window reopen),
        // just ensure subscription/polling is running — skip the heavy 4-phase sync.
        if hasCompletedInitialSync {
            AppLog.log("[ChatService] Initial sync already done, ensuring subscription/polling")
            // Fallback polling keys off the subscription alone, NOT the push mode: while the
            // app runs, its own sync paths must detect everything (new handshakes included)
            // even with remote push on. Backgrounded, the process suspends before the 60s
            // delay elapses, so push stays the background source either way.
            if !isUtxoSubscribed && pollTask == nil {
                startFallbackPolling()
            }
            return
        }

        // An initial sync is already running (the task exists and hasn't been cancelled by a wallet
        // switch/logout). Don't cancel + restart it: repeated startPolling() calls - e.g. re-entering
        // the chat tab, or app-active resyncs - would otherwise keep restarting the heavy 4-phase sync
        // from scratch, hammering the main actor and freezing the UI. Let the in-flight run finish.
        if let task = initialSyncTask, !task.isCancelled {
            AppLog.log("[ChatService] Initial sync already in progress - not restarting")
            return
        }

        stopPollingTimerOnly()
        subscriptionRetryTask?.cancel()
        subscriptionRetryTask = nil
        subscriptionRetryAttempts = 0
        pendingResubscriptionTask?.cancel()
        pendingResubscriptionTask = nil
        subscriptionBalanceRefreshTask?.cancel()
        subscriptionBalanceRefreshTask = nil
        needsResubscriptionAfterSync = false
        AppLog.log("[ChatService] Starting message sync...")

        // Tracked in `initialSyncTask` so a wallet switch/import/logout can cancel this run; an
        // untracked Task here would keep syncing the old wallet after the active wallet changed.
        initialSyncTask?.cancel()
        initialSyncTask = Task {
            AppLog.log("[ChatService] Sync task started")

            AppLog.log("[ChatService] Configuring API...")
            await configureAPIIfNeeded()
            AppLog.log("[ChatService] API configured")

            // Phase 1: Fetch handshakes first (needed to decrypt messages)
            // This is lightweight and establishes encryption keys
            if Self.syncsChats {
                AppLog.log("[ChatService] Phase 1: Fetching handshakes...")
                setInitialSyncPhase(.handshakes)
                await fetchHandshakesOnly()
                AppLog.log("[ChatService] Phase 1 complete")
            }

            // Phase 2: Setup UTXO subscription for real-time updates
            AppLog.log("[ChatService] Phase 2: Setting up UTXO subscription...")
            setInitialSyncPhase(.subscribing)
            await setupUtxoSubscription()
            AppLog.log("[ChatService] Phase 2 complete, isUtxoSubscribed=%d", isUtxoSubscribed ? 1 : 0)

            // Phase 3: Hydrate memory from the local store before the indexer re-sync. The Core
            // Data store holds existing messages and, critically, their persisted read cursors
            // (`CDConversation.lastReadBlockTime`). Loading it first means Phase 4's full
            // re-fetch short-circuits on already-known messages (`addMessageToConversation`'s
            // txId check) instead of recounting every historical message as unread from an empty
            // list - skipping this is exactly why previously-read chats once reappeared unread
            // after logout->login.
            if Self.syncsChats {
                AppLog.log("[ChatService] Phase 3: Loading messages from local store...")
                setInitialSyncPhase(.localStore)
                await loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
                AppLog.log("[ChatService] Phase 3 complete")
            }

            // Phase 4: Full indexer sync (diff-only writes to reduce DB churn)
            // NOTE: syncFromConversations() will preserve stored content and not
            // overwrite with placeholders thanks to the !isPlaceholder check
            if Self.syncsChats {
                AppLog.log("[ChatService] Phase 4: Full indexer sync...")
                setInitialSyncPhase(.indexer)
                await fetchNewMessages()
                AppLog.log("[ChatService] Phase 4 complete")
            }

            // After initial sync, enable notifications (they were suppressed during wallet import)
            suppressNotificationsUntilSynced = false
            hasCompletedInitialSync = true
            // old chats whose first messages fell out of memory stay ordinary chats
            Task { await self.grandfatherPreexistingChats() }
            setInitialSyncPhase(.finished)

            // No remote-push early-out here: fallback polling depends only on whether the
            // subscription came up. While the app runs, its own sync paths must detect
            // everything regardless of push registration; backgrounded, the process suspends
            // before the 60s poll delay elapses, so push stays the background source.
            if isUtxoSubscribed {
                // RPC subscription active - no polling needed, rely on notifications
                let protocolName = NodePoolService.shared.activeProtocol
                AppLog.log("[ChatService] %@ subscription active - using real-time notifications (no polling)", protocolName)
            } else {
                // RPC subscription failed - use polling as fallback
                // Poll with 60s delay after each sync completes (not fixed interval)
                self.startFallbackPolling()
                AppLog.log("[ChatService] RPC unavailable - using fallback polling (%.0fs delay after each sync)", pollDelayAfterSync)
            }
        }
    }

    private func isMessageStoreReadyForCurrentWallet() -> Bool {
        guard let walletAddress = WalletManager.shared.currentWallet?.publicAddress else { return false }
        return messageStore.isStoreLoaded && messageStore.currentWalletAddress == walletAddress
    }

    private func scheduleStartPollingWhenStoreReady(interval: TimeInterval) {
        guard startPollingWhenStoreReadyTask == nil else { return }
        AppLog.log("[ChatService] Delaying message sync until wallet message store is ready")
        startPollingWhenStoreReadyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.startPollingWhenStoreReadyTask = nil
            self.startPolling(interval: interval)
        }
    }

    func startFallbackPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                // Wait before next sync
                try? await Task.sleep(nanoseconds: UInt64(self.pollDelayAfterSync * 1_000_000_000))

                guard !Task.isCancelled else { break }

                // Perform sync - but not from the background. The loop stays alive so the next
                // tick after returning to the foreground syncs promptly; it just does no
                // network work while the app is not active (same gate as the open-chat poll).
                guard UIApplication.shared.applicationState == .active else { continue }
                await self.fetchNewMessages()
            }
        }
    }

    func setupUtxoSubscription() async {
        guard let wallet = WalletManager.shared.currentWallet else {
            AppLog.log("[ChatService] setupUtxoSubscription: No wallet available")
            subscriptionRetryTask?.cancel()
            subscriptionRetryTask = nil
            return
        }

        AppLog.log("[ChatService] setupUtxoSubscription: Starting, isConnected=%@",
              NodePoolService.shared.isConnected ? "true" : "false")

        // Remove old subscription handler if any
        if let token = utxoSubscriptionToken {
            NodePoolService.shared.removeNotificationHandler(token)
            utxoSubscriptionToken = nil
        }
        isUtxoSubscribed = false

        do {
            try await connectRpcIfNeeded()
            let nodePool = NodePoolService.shared
            AppLog.log("[ChatService] setupUtxoSubscription: RPC connected=%@", nodePool.isConnected ? "true" : "false")

            // Collect all addresses to subscribe: our wallet + active contacts + our own spending
            // and cold-storage addresses.
            var addressesToSubscribe = Set<String>()
            addressesToSubscribe.insert(wallet.publicAddress)

            let contacts = await MainActor.run { contactsManager.activeContacts }
            let contactCount = contacts.count
            for contact in contacts {
                addressesToSubscribe.insert(contact.address)
            }

            AppLog.log("[ChatService] Subscription setup: %d active contacts", contactCount)

            let addressList = Array(addressesToSubscribe)
            try await nodePool.subscribeUtxosChanged(addresses: addressList)

            // A run cancelled while it waited (polling stopped, push took over) or one for a wallet
            // that is no longer current must not put a handler back.
            guard !Task.isCancelled, WalletManager.shared.currentWallet?.publicAddress == wallet.publicAddress else {
                AppLog.log("[ChatService] setupUtxoSubscription: superseded while subscribing; no handler added")
                return
            }

            // Add notification handler for UTXO changes. Two setups overlapping across the await
            // above would each add one - every batch processed twice - so whatever another run
            // registered in the meantime goes first.
            if let token = utxoSubscriptionToken {
                nodePool.removeNotificationHandler(token)
            }
            utxoSubscriptionToken = nodePool.addNotificationHandler { [weak self] notification, payload in
                guard let self = self, notification == .utxosChanged else { return }
                self.handleUtxoChangeNotification(payload: payload)
            }

            // Detect if this is a restart (was subscribed before, got disconnected, now resubscribed)
            let isRestart = hasEverBeenSubscribed

            isUtxoSubscribed = true
            hasEverBeenSubscribed = true
            subscriptionRetryAttempts = 0
            subscriptionRetryTask?.cancel()
            subscriptionRetryTask = nil

            // Stop polling task since we have real-time notifications now
            if pollTask != nil {
                pollTask?.cancel()
                pollTask = nil
                AppLog.log("[ChatService] Stopped fallback polling - using real-time notifications")
            }

            // Update connected node info
            currentConnectedNode = nodePool.connectedNodeURL
            currentNodeLatencyMs = nodePool.lastPingLatencyMs

            // Track subscribed address count for resubscription detection
            lastSubscribedAddressCount = addressList.count
            lastSubscribedAddresses = Set(addressList)
            AppLog.log("[ChatService] Real-time notifications active for %d addresses", addressList.count)
            scheduleBalanceRefreshAfterSubscriptionEnabled()

            // If this is a restart, sync messages/payments to catch anything missed during downtime
            if isRestart {
                AppLog.log("[ChatService] Subscription restarted - evaluating catch-up sync policy")
                Task {
                    await self.maybeRunCatchUpSync(trigger: .subscriptionRestart)
                }
            }

        } catch {
            AppLog.log("[ChatService] RPC subscription failed: %@", error.localizedDescription)
            isUtxoSubscribed = false

            // Start retry loop with 1s wait between full pool attempts
            scheduleSubscriptionRetry()
        }
    }

    func scheduleSubscriptionRetry() {
        guard WalletManager.shared.currentWallet != nil else {
            subscriptionRetryTask?.cancel()
            subscriptionRetryTask = nil
            return
        }

        // Cancel existing retry if any
        subscriptionRetryTask?.cancel()

        // Capped exponential backoff (1s -> 2s -> 4s ... 30s cap), mirroring
        // GRPCStreamConnection.scheduleAutoReconnect. The old fixed 1s forever meant a dead
        // pool (airplane mode, captive portal, node outage) burned a full-pool subscription
        // attempt every second indefinitely - real data on metered paths. The counter resets
        // on the next successful subscription.
        let delaySeconds = min(30.0, pow(2.0, Double(subscriptionRetryAttempts)))
        subscriptionRetryAttempts += 1

        subscriptionRetryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))

            guard !Task.isCancelled else { return }

            AppLog.log("[ChatService] Retrying RPC subscription with all pool nodes...")
            await setupUtxoSubscription()

            guard !Task.isCancelled else { return }

            // If still not subscribed after retry, schedule another retry
            if !isUtxoSubscribed {
                AppLog.log("[ChatService] All pool nodes failed, retrying with backoff...")
                scheduleSubscriptionRetry()
            }
        }
    }

    func scheduleBalanceRefreshAfterSubscriptionEnabled() {
        subscriptionBalanceRefreshTask?.cancel()
        subscriptionBalanceRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let delaysNs: [UInt64] = [0, 500_000_000, 1_500_000_000]
            for (attemptIndex, delayNs) in delaysNs.enumerated() {
                if delayNs > 0 {
                    try? await Task.sleep(nanoseconds: delayNs)
                }
                guard !Task.isCancelled else { return }
                guard self.isUtxoSubscribed else { return }

                do {
                    let total = try await WalletManager.shared.refreshBalance(force: true)
                    AppLog.log("[ChatService] Post-subscription balance refreshed on attempt %d: %@ sompi",
                          attemptIndex + 1, String(total))
                    return
                } catch {
                    AppLog.log("[ChatService] Post-subscription balance refresh attempt %d failed: %@",
                          attemptIndex + 1, error.localizedDescription)
                }
            }
        }
    }

    func setupUtxoSubscriptionAfterReconnect() async {
        await setupUtxoSubscription()
    }

    func pauseUtxoSubscriptionForRemotePush() {
#if targetEnvironment(macCatalyst)
        // Keep realtime subscriptions active on desktop while app focus changes.
        return
#else
        guard settingsViewModel?.settings.notificationMode == .remotePush else { return }

        if let token = utxoSubscriptionToken {
            NodePoolService.shared.removeNotificationHandler(token)
            utxoSubscriptionToken = nil
        }
        NodePoolService.shared.unsubscribeUtxosChanged()
        isUtxoSubscribed = false
        // UTXO changes while paused are never replayed, and a plain payment gets no push: the
        // first sync back in the foreground fetches payments from here on.
        requestPaymentCatchUp(lookBackMs: 2 * 60 * 1000)
        AppLog.log("[ChatService] Remote push active - UTXO subscription paused for background")
#endif
    }

    /// Only the payments since `paymentCatchUpSince` - for a foreground whose full catch-up is
    /// debounced. A payment from an unknown address lands in the self-chat as usual.
    func fetchMissedPaymentsIfNeeded() async {
        guard let since = paymentCatchUpSince, !paymentCatchUpInFlight,
              let wallet = WalletManager.shared.currentWallet else { return }
        paymentCatchUpInFlight = true
        defer { paymentCatchUpInFlight = false }
        do {
            let incoming = try await fetchIncomingPayments(for: wallet.publicAddress, blockTime: since)
            let outgoing = try await fetchOutgoingPayments(for: wallet.publicAddress, blockTime: since)
            guard isActiveWallet(wallet.publicAddress) else { return }
            let privateKey = WalletManager.shared.getPrivateKey()
            await processPayments(incoming, isOutgoing: false, myAddress: wallet.publicAddress, privateKey: privateKey)
            await processPayments(outgoing, isOutgoing: true, myAddress: wallet.publicAddress, privateKey: privateKey)
            if paymentCatchUpSince == since { paymentCatchUpSince = nil }
            AppLog.log("[ChatService] Payment catch-up: in=%d, out=%d", incoming.count, outgoing.count)
        } catch {
            AppLog.log("[ChatService] Payment catch-up failed, kept for the next sync: %@", error.localizedDescription)
        }
    }

    /// Payments may have been missed: the next full sync fetches them from `lookBackMs` ago (the
    /// earliest such moment wins), even with the UTXO subscription up.
    func requestPaymentCatchUp(lookBackMs: UInt64) {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let since = now > lookBackMs ? now - lookBackMs : 0
        paymentCatchUpSince = min(paymentCatchUpSince ?? since, since)
    }

    func resumeUtxoSubscriptionForRemotePush() async {
#if targetEnvironment(macCatalyst)
        // No-op: Catalyst does not pause on focus loss.
        return
#else
        guard settingsViewModel?.settings.notificationMode == .remotePush else { return }
        guard utxoSubscriptionToken == nil && !isUtxoSubscribed else { return }

        await setupUtxoSubscription()
#endif
    }

    func addContactToUtxoSubscription(_ contactAddress: String) async {
        guard isUtxoSubscribed else { return }
        guard let wallet = WalletManager.shared.currentWallet else { return }

        // Rebuild subscription with all active addresses including the new one (and, as in
        // setupUtxoSubscription).
        var addressesToSubscribe = Set<String>()
        addressesToSubscribe.insert(wallet.publicAddress)

        let contactAddresses = await MainActor.run { contactsManager.activeContacts.map { $0.address } }
        for address in contactAddresses {
            addressesToSubscribe.insert(address)
        }
        addressesToSubscribe.insert(contactAddress)

        let addressList = Array(addressesToSubscribe)
        lastSubscribedAddressCount = addressList.count
        lastSubscribedAddresses = Set(addressList)
        let _ = try? await NodePoolService.shared.subscribeUtxosChanged(addresses: addressList)
    }

    func syncContactHistoryFromGenesis(_ contactAddress: String) async {
        guard let wallet = WalletManager.shared.currentWallet else { return }

        await configureAPIIfNeeded()
        guard isConfigured, apiClient.hasIndexer else { return }

        let privateKey = WalletManager.shared.getPrivateKey()
        ensureRoutingState(for: contactAddress, privateKey: privateKey)

        // Ensure realtime updates include this new contact as soon as possible.
        await addContactToUtxoSubscription(contactAddress)

        let completed = await fetchContextualMessagesForActive(
            contactAddress: contactAddress,
            myAddress: wallet.publicAddress,
            privateKey: privateKey,
            fallbackSince: 0,
            nowMs: currentTimeMs(),
            forceExactBlockTime: true
        )
        guard completed else { return }

        saveMessages()
    }

    func checkAndResubscribeIfNeeded() {
        guard isUtxoSubscribed else { return }
        guard let wallet = WalletManager.shared.currentWallet else { return }

        // Calculate current active address set. Must mirror setupUtxoSubscription's full set
        // (contacts + own spending/cold addresses) - comparing a
        // partial set against lastSubscribedAddresses would read as "changed" on every call
        // and thrash resubscription.
        var addressesToSubscribe = Set<String>()
        addressesToSubscribe.insert(wallet.publicAddress)
        for contact in activeContacts {
            addressesToSubscribe.insert(contact.address)
        }

        let currentAddressCount = addressesToSubscribe.count

        // Resubscribe whenever active address set changes (additions or removals)
        guard addressesToSubscribe != lastSubscribedAddresses else { return }

        // If sync is in progress, mark for resubscription after sync completes
        if isLoading {
            needsResubscriptionAfterSync = true
            AppLog.log("[ChatService] Address count changed: %d -> %d, deferring resubscription until sync completes",
                  lastSubscribedAddressCount, currentAddressCount)
            return
        }

        AppLog.log("[ChatService] Address count changed: %d -> %d, executing resubscription",
              lastSubscribedAddressCount, currentAddressCount)

        // Cancel any pending resubscription task
        pendingResubscriptionTask?.cancel()

        // Execute resubscription
        pendingResubscriptionTask = Task {
            await setupUtxoSubscription()
        }
    }

    func executeResubscriptionIfNeeded() {
        guard needsResubscriptionAfterSync else { return }
        needsResubscriptionAfterSync = false

        AppLog.log("[ChatService] Sync complete, executing deferred resubscription")

        pendingResubscriptionTask?.cancel()
        pendingResubscriptionTask = Task {
            await setupUtxoSubscription()
        }
    }

    func addMessageFromPush(txId: String, sender: String, content: String, timestamp: Int64) async {
        guard let wallet = WalletManager.shared.currentWallet else {
            AppLog.log("[ChatService] No wallet for push message")
            return
        }

        // Check if message already exists
        if await findLocalMessage(txId: txId) != nil {
            AppLog.log("[ChatService] Push message already exists: %@", txId)
            return
        }

        // Determine message type
        let msgType: ChatMessage.MessageType = content.hasPrefix("{\"type\":\"audio\"") ? .audio : .contextual

        // Create message using the correct ChatMessage initializer
        let message = ChatMessage(
            txId: txId,
            senderAddress: sender,
            receiverAddress: wallet.publicAddress,
            content: content,
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000),
            blockTime: UInt64(timestamp),
            acceptingBlock: nil,
            isOutgoing: false,
            messageType: msgType
        )

        // Add to conversation using existing method
        addMessageToConversation(message, contactAddress: sender)
        saveMessages()

        AppLog.log("[ChatService] Added message from push: %@ from %@", txId, String(sender.suffix(10)))
    }

    /// Build a Kaspa REST API URL using URLComponents for safe encoding.
    func kaspaRestURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        let settings = currentSettings
        guard var components = URLComponents(string: settings.kaspaRestAPIURL) else { return nil }
        components.path += path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }

    /// A GET for one of the REST endpoints with a real timeout. `URLSession.shared.data(from:)`
    /// takes the session default of 60s per request, so a stalled indexer or explorer held a
    /// sync phase (and the flags it holds - see `retryUntilSuccess`) for a full minute per
    /// attempt. 20s matches the other REST clients in the app.
    nonisolated static func timedRequest(_ url: URL, timeout: TimeInterval = 20) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        return request
    }

    /// JSON decode off the main actor. ChatService is `@MainActor`, so a plain
    /// `JSONDecoder().decode` inside it runs on the main thread - fine for one transaction, a
    /// visible hitch for a 200-item history page.
    nonisolated static func decodeOffMain<T: Decodable>(_ type: T.Type, from data: Data) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(T.self, from: data)
        }.value
    }

}

// MARK: - Shared-file backup merge (upload side)
//
// Mirrors Android's `ChatHistoryExportImportService.mergeArchives` and desktop's
// `mergeChatArchives`, including the abort-rather-than-destroy contract. Everything here is
// untyped JSON-tree work on purpose: round-tripping through the typed `ChatHistoryArchive`
// model would silently drop every key this app doesn't model - desktop keeps its whole state
// in an additive `desktopState` key - and wipe it on the next iOS backup. Unknown keys at the
// archive, conversation and message level are all carried through verbatim.
extension ChatService {
    private nonisolated static let archiveStatusPriority: [String: Int] = [
        "pending": 0, "warning": 1, "failed": 2, "sent": 3,
    ]
    private nonisolated static let archiveValidMessageTypes: Set<String> = [
        "handshake", "contextual", "payment", "audio",
    ]
    private nonisolated static let archiveValidDeliveryStatuses: Set<String> = [
        "pending", "sent", "failed", "warning",
    ]

    // MARK: JSON accessors (tolerant of NSNumber/String cross-typing)

    private nonisolated static func jsonString(_ dict: [String: Any], _ key: String) -> String {
        if let value = dict[key] as? String { return value }
        return ""
    }

    // MARK: Deterministic archive UUIDs

    // MARK: Message-level merge helpers

    private final class ArchiveConversationMerge {
        let contactAddress: String
        var base: [String: Any]
        var conversationId = ""
        var contactAlias = ""
        var contactPhoto = ""
        var unreadCount: Int64 = 0
        var messages: [String: [String: Any]] = [:]
        var messageOrder: [String] = []

        init(contactAddress: String, base: [String: Any]) {
            self.contactAddress = contactAddress
            self.base = base
        }
    }

}
