import Foundation

extension KachatNames {
    /// A registration in flight: commit -> wait `tCommit` DAA -> register. Kept per wallet in
    /// Application Support (the salt in the Keychain), so it resumes after a relaunch.
    struct PendingRegistration: Codable, Identifiable, Equatable {
        enum Stage: String, Codable {
            /// the commit transaction was built and is being submitted
            case committing
            /// the commit is on chain (or about to be); waiting until it is `tCommit` deep
            case waiting
            /// the registration was submitted
            case registering
            case registered
            /// someone registered the name first; the commit can be cancelled
            case taken
            case failed
            case cancelling
            case cancelled
        }

        /// Names the salt in the Keychain.
        var id: String
        var name: String
        var years: Int64
        /// x-only owner key, hex
        var owner: String
        var commitTxId: String
        /// the commit's P2SH script, hex
        var commitScript: String
        /// the commit UTXO's DAA score once seen
        var commitDaa: UInt64?
        var registerTxId: String?
        /// Every register sent (a resend after two minutes replaces `registerTxId`), so one that
        /// lands late still counts as this claim's registration.
        var registerTxIds: [String]? = nil
        /// The reclaim this registration sent to free a lapsed old record of the name first, and
        /// the gap it reopens (hex), which is that reclaim's output 0.
        var reclaimTxId: String? = nil
        var reclaimLo: String? = nil
        var reclaimHi: String? = nil
        /// When the current commit went out, and how many times it was sent again after a node
        /// dropped it (a busy network evicts low-fee transactions).
        var commitSentAt: Int64? = nil
        var commitResends: Int? = nil
        /// Every commit sent: an earlier one can still be waiting in a mempool, or land after a
        /// resend (`findCommit` follows whichever did).
        var commitTxIds: [String]? = nil
        var cancelTxId: String?
        var stage: Stage
        var createdAt: Int64
        var updatedAt: Int64
        var lastError: String?
        /// The price the person confirmed for the whole registration (sompi). The registration
        /// never pays more (registry v4's prices are fixed, so it never has to).
        var maxPrice: UInt64?
        /// The fee speed chosen when claiming (`WithdrawFeeTier` raw value), applied to the commit
        /// and, at the current network rate, to the register. nil (claims from before): Priority.
        var feeTier: String? = nil
        /// A fee of the person's own (the claim review's Edit), as a rate in sompi per gram: used
        /// for the commit and the register in place of `feeTier`.
        var customFeerate: Double? = nil

        /// Still shown on the hub.
        var isOpen: Bool { stage != .cancelled }
        /// The driver has work to do.
        var needsDriving: Bool { [.committing, .waiting, .registering, .cancelling].contains(stage) }
    }
}

/// The `.kachat` registration driver, kept so a claim started in an older build (commit sent,
/// reveal pending, its salt in the Keychain) still finishes or fails on its own: claiming,
/// renewing, selling, transferring and offers are KaPay's (owner's call, 2026-11-18). Plus the
/// read side the bell and Your Domains use (this wallet's keys and names). `resume()` runs when
/// the app becomes active (`KaChatChessApp`).
@MainActor
final class KachatNamesActions {
    static let shared = KachatNamesActions()

    private var pending: [KachatNames.PendingRegistration] = []
    private var pendingWallet: String?
    private var driver: Task<Void, Never>?

    private init() {}

    private var service: KachatNamesService { KachatNamesService.shared }
    private var registry: KachatNamesRegistry { KachatNamesRegistry.shared }

    enum ActionError: LocalizedError {
        case noWallet
        case keyMismatch
        case noSalt
        /// the record has no periodStart (an indexer without the field), so its state is unknown
        case periodUnknown
        /// the transaction would pay more than the price the person confirmed
        case priceChanged(UInt64)
        /// registry v5: registering opens at the migration deadline, once the old registry's names
        /// are imported
        case registrationNotOpen(opensMs: Int64)

        var errorDescription: String? {
            switch self {
            case .noWallet: return AppLocalization.string("No wallet is open.")
            case .keyMismatch: return AppLocalization.string("This wallet's key does not match its address.")
            case .noSalt: return AppLocalization.string("The secret for this registration is missing on this device.")
            case .periodUnknown:
                return AppLocalization.string("The names indexer didn't send this name's paid period. Pull to refresh and try again.")
            case .priceChanged(let price):
                return String(format: AppLocalization.string("The price changed to %@ since you confirmed. Nothing was sent. Check the new price and confirm again."),
                              KaspaUnit.amount(price))
            case .registrationNotOpen(let opens):
                return String(format: AppLocalization.string("Names are moving to the new registry. New names can be claimed from %@."),
                              KachatNamesActions.dayString(opens))
            }
        }
    }


    /// Registry v5 refuses `register` until the migration deadline; checked against the wall clock
    /// with the 3-minute margin `registerNow` takes off it.
    static func requireRegistrationOpen(_ m: KachatNames.Manifest) async throws {
        guard let deadline = m.params.migration?.deadlineMs,
              KachatNames.nowMs() - 180_000 < deadline else { return }
        throw ActionError.registrationNotOpen(opensMs: deadline + 180_000)
    }

    /// A unix-ms day ("Oct 12, 2027") in the in-app language, with the time when it is within two
    /// days (testnet's 24-hour periods, or a renewal that opens tomorrow).
    nonisolated static func dayString(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.locale = AppLocalization.locale
        f.dateStyle = .medium
        // in Double: a junk time from a server must not trap the subtraction
        f.timeStyle = abs(Double(ms) - Double(KachatNames.nowMs())) < 2 * 86_400_000 ? .short : .none
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    // MARK: - Wallet

    struct Signer {
        let address: String
        let privateKey: Data
        let me: Data
    }

    /// The current wallet's address on this network, its key and x-only key (they must agree).
    func signer() throws -> Signer {
        try service.requireLaunched()
        guard let address = WalletManager.shared.currentWallet?.publicAddress.lowercased(), address.hasPrefix(KachatNamesService.addressPrefix + ":"),
              let key = WalletManager.shared.getPrivateKey() else { throw ActionError.noWallet }
        let me = try KachatNamesService.xonlyKey(privateKey: key)
        guard KachatNamesRegistry.keyOf(address) == me else { throw ActionError.keyMismatch }
        return Signer(address: address, privateKey: key, me: me)
    }

    /// Which of this wallet's own addresses holds a name.
    enum OwnAddress: Equatable {
        case chatting
        /// A spending address: the app derives its key, so owner actions sign with it.
        case spending(index: Int, address: String)
    }

    /// Whether `owner` (an x-only key) is one of this wallet's addresses, and which: the chatting
    /// address or a revealed spending address. nil = someone else.
    func ownAddress(of owner: Data) -> OwnAddress? {
        if owner == myKey { return .chatting }
        let wallet = WalletManager.shared
        let spending = wallet.spendingAddresses(inRange: 0..<(max(0, wallet.maxSpendingAddressIndex) + 1))
        for (index, address) in spending.sorted(by: { $0.key < $1.key }) where KachatNamesRegistry.keyOf(address) == owner {
            return .spending(index: index, address: address)
        }
        return nil
    }

    /// A spending address's signer, checked against the key it must have.
    private func spendingSigner(index: Int, address: String, expected: Data?) throws -> Signer {
        try service.requireLaunched()
        guard address.lowercased().hasPrefix(KachatNamesService.addressPrefix + ":"), NetworkType.isOnActiveNetwork(address) else {
            throw KachatNamesService.ServiceError.wrongAddressNetwork
        }
        guard let key = WalletManager.shared.spendingPrivateKey(at: index) else { throw ActionError.noWallet }
        let me = try KachatNamesService.xonlyKey(privateKey: key)
        guard me == (expected ?? KachatNamesRegistry.keyOf(address)) else { throw ActionError.keyMismatch }
        return Signer(address: address.lowercased(), privateKey: key, me: me)
    }

    /// The signer for whichever of this wallet's addresses holds `owner` (the chatting address or
    /// a spending address) - a claim in progress keeps the address it was started from.
    private func ownerSigner(_ owner: Data) throws -> Signer {
        switch ownAddress(of: owner) {
        case .chatting?: return try signer()
        case .spending(let index, let address)?: return try spendingSigner(index: index, address: address, expected: owner)
        default: throw ActionError.keyMismatch
        }
    }

    // MARK: - Addresses the marketplace bought with

    private var marketAddressesKey: String? {
        myAddress.map { "kachat_market_addresses.\($0)" }
    }

    /// Spending addresses an earlier build bought with (the retired Buy From picker), per wallet:
    /// Your Domains and the marketplace still list the names and offers they hold next to the
    /// chatting address's. Nothing adds to it any more.
    var marketAddresses: [String] {
        guard let key = marketAddressesKey else { return [] }
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    // MARK: - This wallet's keys (IOS-085 / XP-024)

    private var nameKeysCache: (key: String, at: Date, keys: [Data])?

    /// The keys worth asking the registry about (one lookup each): the chatting key, then every
    /// revealed spending address that has ever been used - a name or an offer needs KAS on its
    /// address - and the addresses Buy From was set to. The used/unused answers are cached (used
    /// is for good), so after the first time this costs no requests; the list itself is kept
    /// ten minutes.
    func ownNameKeys() async -> [Data] {
        guard let wallet = myAddress, let me = myKey else { return [] }
        let manager = WalletManager.shared
        let cacheKey = "\(wallet)|\(manager.maxSpendingAddressIndex)|\(marketAddresses.count)"
        if let cached = nameKeysCache, cached.key == cacheKey, Date().timeIntervalSince(cached.at) < 600 {
            return cached.keys
        }
        let spending = manager.spendingAddresses(inRange: 0..<(max(0, manager.maxSpendingAddressIndex) + 1))
            .sorted { $0.key < $1.key }.map(\.value)
        let hints = Set(marketAddresses)
        let chat = ChatService.shared
        var used: [String: Bool] = [:]
        var toProbe: [String] = []
        for address in spending {
            if hints.contains(address.lowercased()) { used[address] = true; continue }
            if let known = chat.cachedSpendingAddressUsedState(address) { used[address] = known } else { toProbe.append(address) }
        }
        var pending = toProbe.makeIterator()
        await withTaskGroup(of: (String, Bool?).self) { group in
            for _ in 0..<8 {
                guard let address = pending.next() else { break }
                group.addTask { (address, await chat.spendingAddressUsedState(address)) }
            }
            while let (address, answer) = await group.next() {
                used[address] = answer ?? false
                if let next = pending.next() {
                    group.addTask { (next, await chat.spendingAddressUsedState(next)) }
                }
            }
        }
        var keys = [me]
        for address in spending where used[address] == true {
            if let key = KachatNamesRegistry.keyOf(address), !keys.contains(key) { keys.append(key) }
        }
        for address in marketAddresses {
            if let key = KachatNamesRegistry.keyOf(address), !keys.contains(key) { keys.append(key) }
        }
        guard myAddress == wallet else { return [] }
        nameKeysCache = (cacheKey, Date(), keys)
        return keys
    }

    /// Every name (`includeInactive`) or held name on this wallet's keys (`ownNameKeys`), asked a
    /// few at a time. Offers are KaPay's, so none are read.
    func ownNames(heldOnly: Bool = true) async throws -> [KachatNames.NameInfo] {
        let keys = await ownNameKeys()
        let registry = KachatNamesRegistry.shared
        var names: [KachatNames.NameInfo] = []
        let lookUp: @MainActor (Data) async throws -> [KachatNames.NameInfo] = { key in
            heldOnly ? try await registry.heldNames(owner: key) : try await registry.names(owner: key, includeInactive: true)
        }
        try await withThrowingTaskGroup(of: [KachatNames.NameInfo].self) { group in
            var it = keys.makeIterator()
            for _ in 0..<4 {
                guard let key = it.next() else { break }
                group.addTask { try await lookUp(key) }
            }
            while let n = try await group.next() {
                names += n
                if let key = it.next() { group.addTask { try await lookUp(key) } }
            }
        }
        return names
    }

    /// `ownNames` in the shape the unshown full wallet's Your Domains reads (`FullWalletView`):
    /// the offers are always empty.
    func ownNamesAndOffers(heldOnly: Bool) async throws -> (names: [KachatNames.NameInfo], offers: [KachatNames.OfferInfo]) {
        (try await ownNames(heldOnly: heldOnly), [])
    }

    /// The current wallet's x-only key, without touching the private key.
    var myKey: Data? {
        guard let address = WalletManager.shared.currentWallet?.publicAddress else { return nil }
        return KachatNamesRegistry.keyOf(address)
    }

    var myAddress: String? { WalletManager.shared.currentWallet?.publicAddress.lowercased() }

    // MARK: - Fees

    /// The network's fee picture: what Normal pays (sompi per gram) and how long it is expected
    /// to wait, and the priority rate. From a node; the REST API only if no node answers.
    struct FeeEstimate: Equatable {
        var normal: Double
        var normalSeconds: Double
        var priority: Double
        var prioritySeconds: Double

        /// Busy: Normal costs above the relay floor, or isn't expected in the next few blocks.
        var isBusy: Bool { normal > KachatNames.minFeerate * 1.5 || normalSeconds > 10 }
    }

    private var feeEstimate: FeeEstimate?

    /// Reads the fee estimate (node first) and publishes it; nil when nothing answers.
    @discardableResult
    func refreshFeeEstimate() async -> FeeEstimate? {
        if let e = try? await NodePoolService.shared.feeEstimate(),
           let estimate = Self.sane(FeeEstimate(normal: e.normal.feerate, normalSeconds: e.normal.seconds,
                                                priority: e.priority.feerate, prioritySeconds: e.priority.seconds)) {
            feeEstimate = estimate
            return estimate
        }
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/info/fee-estimate"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let priority = j["priorityBucket"] as? [String: Any] else { return feeEstimate }
        let normal = (j["normalBuckets"] as? [[String: Any]])?.first ?? priority
        func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        guard let estimate = Self.sane(FeeEstimate(normal: num(normal, "feerate"), normalSeconds: num(normal, "estimatedSeconds"),
                                                   priority: num(priority, "feerate"), prioritySeconds: num(priority, "estimatedSeconds")))
        else { return feeEstimate }
        feeEstimate = estimate
        return estimate
    }

    /// An estimate only if every rate is a real, non-negative number at most `maxFeerate`: one
    /// node (any pool node, or the REST API) answering NaN, infinity or 1e300 is ignored rather
    /// than paid (IOS-061).
    private static func sane(_ e: FeeEstimate) -> FeeEstimate? {
        for rate in [e.normal, e.priority] {
            guard rate.isFinite, rate >= 0, rate <= KachatNames.maxFeerate else { return nil }
        }
        return FeeEstimate(normal: e.normal, normalSeconds: e.normalSeconds.isFinite ? max(0, e.normalSeconds) : 0,
                           priority: e.priority, prioritySeconds: e.prioritySeconds.isFinite ? max(0, e.prioritySeconds) : 0)
    }

    /// The most a transaction sent without a sheet pays per gram (the claim driver, returning
    /// expired offers, declining, withdrawing, freeing an expired name): 20x the floor, above the
    /// busiest rate seen, and a few hundredths of a KAS on these transactions (IOS-061).
    static let backgroundMaxFeerate = KachatNames.minFeerate * 20

    /// The rate a speed pays: the network's Normal rate (never under the relay floor) times the
    /// speed's multiplier, the same 1x / 2x / 5x the Send screens use.
    func feerate(for tier: WithdrawFeeTier) async -> Double {
        let estimate = await refreshFeeEstimate()
        let base = estimate.map { max(KachatNames.minFeerate, $0.normal) } ?? Self.unknownFeerate
        return KachatNames.safeFeerate(base * Double(tier.multiplier))
    }

    /// `max(100, the priority fee rate)` in sompi per gram.
    /// The rate for a transaction sent without a sheet (nobody saw its fee): the priority rate,
    /// capped at `backgroundMaxFeerate`.
    func feerate() async -> Double {
        guard let e = await refreshFeeEstimate(), e.priority > 0 else { return Self.unknownFeerate }
        return min(KachatNames.safeFeerate(e.priority), Self.backgroundMaxFeerate)
    }

    /// When the fee estimate can't be read: well above the floor, since the floor is exactly what
    /// a busy network drops (testnet-10 asked 115-894 sompi/gram on 2026-10-07). Still a tiny fee
    /// on these small transactions.
    private static let unknownFeerate = KachatNames.minFeerate * 10

    /// Builder, environment and the wallet's funding UTXOs for one transaction, at `feerate`
    /// (default: the priority rate).
    private func context(_ s: Signer, feerate rate: Double? = nil) async throws -> (KachatNames.Builder, KachatNames.Env, [KachatNames.Utxo]) {
        let builder = try await service.builder()
        let chosen: Double
        if let rate { chosen = rate } else { chosen = await feerate() }
        let env = try await service.environment(privateKey: s.privateKey, feerate: chosen)
        // not coins a send still in flight spent
        let utxos = ChatService.shared.unreservedUtxos(try await NodePoolService.shared.getUtxosByAddresses([s.address]))
        let funding = KachatNamesService.fundingUtxos(utxos, me: s.me, virtualDaaScore: env.blockDaa)
        return (builder, env, funding)
    }

    // MARK: - Live records

    private func liveName(_ n: KachatNames.NameInfo, _ m: KachatNames.Manifest) async throws -> KachatNames.NameRecord {
        guard let fields = n.fields else { throw ActionError.periodUnknown }
        let u = try await service.liveRegistryUtxo(script: m.name.script(fields.encoded), outpoint: n.outpoint)
        return KachatNames.NameRecord(fields: fields, value: u.entry.amount, utxo: u)
    }

    private func liveGap(_ g: KachatNames.GapInfo, _ m: KachatNames.Manifest) async throws -> KachatNames.GapRecord {
        let u = try await service.liveRegistryUtxo(script: m.gap.script(KachatNames.Codec.gapState(lo: g.lo, hi: g.hi)), outpoint: g.outpoint)
        return KachatNames.GapRecord(lo: g.lo, hi: g.hi, value: u.entry.amount, utxo: u)
    }

    // MARK: - Many small coins (mainnet, 2026-10-09)

    /// A name transaction takes at most a few funding inputs (`KachatNames.maxInputsFeeEntry`
    /// all in), so a wallet holding enough KAS in many small coins couldn't pay: "insufficient
    /// funds ... at most N funding inputs fit". The builder says that only when the spendable KAS
    /// would cover the transaction (IOS-075): a wallet that is simply short never combines.
    nonisolated static func isTooManyCoins(_ error: Error) -> Bool {
        (error as? KachatNames.Failure)?.message.contains("funding inputs fit") == true
    }

    /// Combines the wallet's coins into one: a plain send of up to `maxInputsPerTransaction`
    /// largest coins to the same address (a tiny network fee), then waits until a node has the
    /// combined coin, so the name transaction can be built from it. Never a coin carrying a
    /// covenant.
    @discardableResult
    func combineCoins(_ s: Signer) async throws -> String {
        // Queued behind every other send (moves, withdrawals, .kas), so no two pick the same
        // coins. The wait for the combined coin, below, is outside the queue.
        let (txId, combined): (String, Int) = try await ChatService.shared.enqueueOutgoingTxOperation {
            let utxos = try await NodePoolService.shared.getUtxosByAddresses([s.address])
            // Not a coin a send still in flight spent, nor a mining reward that may not be mature.
            let plain = Array(ChatService.shared.unreservedUtxos(utxos)
                .filter { $0.covenantId == nil && $0.blockDaaScore > 0 && !$0.isCoinbase }
                .sorted { $0.amount > $1.amount }
                .prefix(KasiaTransactionBuilder.maxInputsPerTransaction))
            let total = plain.reduce(UInt64(0)) { $0 + $1.amount }
            guard plain.count > 1, let script = KaspaAddress.scriptPublicKey(from: s.address) else {
                throw KachatNames.Failure(AppLocalization.string("Not enough KAS on your chatting address for this."))
            }
            // All of it, less the fee: a fixed fee allowance left change too small to keep, which
            // the builder gave to the network. (As KaPost.)
            let daa = await NodePoolService.shared.currentVirtualDaaScore()
            let fee = KasiaTransactionBuilder.estimateSendAllFee(
                utxos: plain, payload: Data(), recipientScriptPubKey: script, senderScriptPubKey: script, virtualDaaScore: daa
            )
            guard total > fee * 2 else {
                throw KachatNames.Failure(AppLocalization.string("Not enough KAS on your chatting address for this."))
            }
            let tx = try KasiaTransactionBuilder.buildPlainTransferTx(
                from: s.address, to: s.address, amount: total - fee,
                senderPrivateKey: s.privateKey, utxos: plain, virtualDaaScore: daa
            )
            // never parked in a node's orphan pool: the name transaction waits on this coin
            return (try await NodePoolService.shared.submitTransaction(tx, allowOrphan: false, escalateOrphan: false).txId, plain.count)
        }
        // a move between your own coins, not a payment to show in the chats
        ChatService.shared.registerSuppressedPaymentTxIds([txId], reason: "kachat-names")
        AppLog.log("[KachatNames] combined %d coins into one: %@", combined, txId)
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let now = (try? await NodePoolService.shared.getUtxosByAddresses([s.address])) ?? []
            if now.contains(where: { $0.outpoint.transactionId.lowercased() == txId.lowercased() }) { break }
        }
        return txId
    }

    /// Whether a node still holds what `found` rests on: the name's record, or the gap a free
    /// name falls in. The registry's answer can be behind the chain, or an indexer's word only.
    private func isLiveOnChain(_ found: KachatNames.Lookup) async -> Bool {
        switch found {
        case .registered(let n):
            return (try? await registry.confirmOnChain(n)) != nil
        case .free(_, let gap):
            guard let gap, let m = try? await registry.prepare() else { return false }
            return (try? await liveGap(gap, m)) != nil
        }
    }

    /// Frees a lapsed record (a reclaim): anyone may send it, its bond goes back to the old owner
    /// and its fee comes out of the freed deposit. Signed by the chatting address; the registry
    /// refreshes once it is accepted.
    private func reclaim(_ n: KachatNames.NameInfo, feerate rate: Double) async throws -> String {
        let s = try signer()
        let m = try await registry.prepare()
        let (b, env, _) = try await context(s, feerate: KachatNames.safeFeerate(rate))
        let gaps = try await registry.exitGaps(for: n)
        let plan = try b.reclaim(env: env, parts: KachatNames.ExitParts(
            below: try await liveGap(gaps.below, m), name: try await liveName(n, m), above: try await liveGap(gaps.above, m)))
        let txId = try await service.signAndSubmit(plan, privateKey: s.privateKey, env: env)
        registry.refreshAfter(txId: txId)
        return txId
    }

    // MARK: - Registrations started in an older build

    /// Loads the current wallet's registrations and drives the open ones to registered (or
    /// failed). Called when the app becomes active; nothing new is ever started here.
    func resume() {
        // Every network: a profile saved on another device (Android, Desktop, KaPay) shows here
        // too, instead of an older copy this device saved.
        if let address = myAddress {
            Task { await registry.syncOwnProfile(address: address) }
        }
        guard KachatNamesService.isLaunched, let address = myAddress else {
            driver?.cancel()
            driver = nil
            pending = []
            pendingWallet = nil
            return
        }
        loadPending(for: address)
        startDriver()
    }

    private func startDriver() {
        guard driver == nil, pending.contains(where: { $0.needsDriving }) else { return }
        driver = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard KachatNamesService.isLaunched, let address = self.myAddress, address == self.pendingWallet,
                      !self.service.registryUpgrading,
                      self.pending.contains(where: { $0.needsDriving }) else { break }
                for p in self.pending where p.needsDriving {
                    await self.advance(p)
                }
                // waiting for a registration's acceptance: check often, so the receipt shows
                // within a couple of seconds of it
                let registering = self.pending.contains { $0.stage == .registering }
                try? await Task.sleep(nanoseconds: registering ? 2_000_000_000 : 5_000_000_000)
            }
            self?.driver = nil
        }
    }


    private enum CommitLookup {
        case live(KachatNames.Utxo)
        /// no UTXO holds the commit script: spent, or not accepted yet
        case gone
        /// the node couldn't be asked
        case unknown
    }

    /// The commit UTXO from whichever send of it landed: a resend changes `commitTxId`, and the
    /// first send can still land after it. The salt makes the commit script unique, so any UTXO
    /// holding it is this claim's; when it isn't the latest send, `commitTxId` follows it, so a
    /// cancel or register spends the coin that is really there.
    private func findCommit(_ p: KachatNames.PendingRegistration) async -> CommitLookup {
        guard let script = try? KachatNames.unhex(p.commitScript),
              let found = try? await service.liveUtxos(script: script) else { return .unknown }
        let latest = try? KachatNames.unhex32(p.commitTxId)
        guard let u = found.first(where: { $0.outpoint.txid == latest }) ?? found.first else { return .gone }
        let txId = KachatNames.hex(u.outpoint.txid)
        if var q = pending.first(where: { $0.id == p.id }), q.commitTxId.lowercased() != txId {
            AppLog.log("[KachatNames] the commit for %@ that landed is %@", p.name, txId)
            q.commitTxId = txId
            upsert(q)
        }
        return .live(u)
    }

    /// The commit UTXO when a node has it (nil when spent, not yet accepted or not answered).
    private func liveCommit(_ p: KachatNames.PendingRegistration) async -> KachatNames.Utxo? {
        if case .live(let u) = await findCommit(p) { return u }
        return nil
    }

    /// true: the node says no UTXO holds the commit any more; false: one still does; nil: the
    /// node couldn't be asked (never read as "spent").
    private func commitSpent(_ p: KachatNames.PendingRegistration) async -> Bool? {
        switch await findCommit(p) {
        case .live: return false
        case .gone: return true
        case .unknown: return nil
        }
    }

    /// The rate the registration's chosen speed pays now (its claim-time choice), else Priority.
    private func registrationFeerate(_ p: KachatNames.PendingRegistration) async -> Double {
        // A fee the person typed on the review was shown for both transactions: it is kept.
        if let custom = p.customFeerate { return KachatNames.safeFeerate(max(KachatNames.minFeerate, custom)) }
        // The register goes out by itself a minute after the claim: the chosen speed, but never
        // above the background cap - its fee is not shown again.
        if let raw = p.feeTier, let tier = WithdrawFeeTier(rawValue: raw) {
            return min(await feerate(for: tier), Self.backgroundMaxFeerate)
        }
        return await feerate()
    }

    private func set(_ p: KachatNames.PendingRegistration, _ change: (inout KachatNames.PendingRegistration) -> Void) {
        var q = pending.first { $0.id == p.id } ?? p
        change(&q)
        q.updatedAt = KachatNames.nowMs()
        upsert(q)
    }

    /// One step of one registration.
    private func advance(_ p: KachatNames.PendingRegistration) async {
        let sinceUpdate = KachatNames.nowMs() - p.updatedAt
        switch p.stage {
        case .committing, .waiting:
            let found = await findCommit(p)
            if case .unknown = found { return } // the node couldn't be asked: the next tick
            guard case .live(let commit) = found else {
                if p.commitDaa == nil, await commitStillPending(p) { return }
                // the commit is gone: registered by us (another device?), or never confirmed
                let registers = p.registerTxIds ?? p.registerTxId.map { [$0] } ?? []
                // a register sent earlier that landed late spent it: the network says so before
                // a lagging registry does
                for tx in registers {
                    guard await KachatNamesRegistry.isAccepted(txId: tx) else { continue }
                    finishRegistered(p)
                    Task {
                        let daa = await NodePoolService.shared.currentVirtualDaaScore()
                        await registry.refreshUntilIncludes(txId: tx, daa: daa)
                    }
                    return
                }
                switch await ownsName(p.name) {
                case true?:
                    finishRegistered(p)
                case false? where !registers.isEmpty && sinceUpdate < 1_800_000:
                    // only this owner's register or cancel can spend the commit, and a register
                    // was sent: the registry is behind it, so it gets half an hour to catch up
                    break
                case false?:
                    let why = p.commitDaa == nil ? "The commit never reached the chain." : "The commit is no longer on chain."
                    set(p) { $0.stage = .failed; $0.lastError = AppLocalization.string(why) }
                case nil:
                    // the registry can't be read right now: asked again on the next tick, not failed
                    break
                }
                return
            }
            if p.commitDaa != commit.entry.blockDaaScore || p.stage == .committing {
                set(p) { $0.commitDaa = commit.entry.blockDaaScore; $0.stage = .waiting }
            }
            guard let m = service.manifest,
                  let dag = try? await NodePoolService.shared.currentDagPoint() else { return }
            // a little past maturity, so the block that takes it is surely deep enough
            guard dag.virtualDaaScore >= KachatNames.clampedSum(commit.entry.blockDaaScore, KachatNames.clampedSum(m.params.tCommit, 20)) else { return }
            await register(p, commit: commit)
        case .registering:
            // In a block: no node holds it in a mempool any more, and the commit it spends is gone
            // from the UTXO set (only this owner's register or cancel can spend it). Node only.
            if let tx = p.registerTxId, await NodePoolService.shared.getMempoolEntry(txId: tx) == nil,
               await commitSpent(p) == true {
                // Accepted is registered: the gap only accepts a register that mints this owner's
                // name. The receipt shows now; the registry catches up in the background instead
                // of first (a chain walk while the indexer follows another registry).
                finishRegistered(p)
                Task {
                    let daa = await NodePoolService.shared.currentVirtualDaaScore()
                    await registry.refreshUntilIncludes(txId: tx, daa: daa)
                }
                return
            }
            // not accepted after two minutes and the commit is still there: register again
            if sinceUpdate > 120_000, await liveCommit(p) != nil {
                set(p) { $0.stage = .waiting; $0.registerTxId = nil }
            }
        case .cancelling:
            if let tx = p.cancelTxId, await KachatNamesRegistry.isAccepted(txId: tx) {
                finishCancelled(p)
            } else if sinceUpdate > 120_000, await commitSpent(p) == true {
                // never on a node that couldn't be asked: the commit may still be there
                finishCancelled(p)
            }
        case .registered, .taken, .failed, .cancelled:
            break
        }
    }

    /// A commit not on chain yet: still waiting in a node's mempool (true), sent again because
    /// a node dropped it (true), or past saving (false: the caller fails it). On a busy network a
    /// low-fee transaction is evicted instead of mined, so silence must not mean "wait".
    private func commitStillPending(_ p: KachatNames.PendingRegistration) async -> Bool {
        let sinceSent = KachatNames.nowMs() - (p.commitSentAt ?? p.createdAt)
        if sinceSent < 30_000 { return true } // just sent: give it time to show up
        // any send of it: an earlier one can still be waiting
        var inMempool = false
        for tx in p.commitTxIds ?? [p.commitTxId] where !inMempool {
            inMempool = await NodePoolService.shared.getMempoolEntry(txId: tx) != nil
        }
        if inMempool {
            if sinceSent > 60_000, p.lastError == nil {
                set(p) { $0.lastError = AppLocalization.string("The network is busy. Your commit is waiting for a block.") }
            }
            return true
        }
        // Its coins stay held for two minutes after a send (`pendingMessageUtxoTTL`). Sent again
        // sooner, a one-coin wallet has nothing to pay with and a wallet with more coins spends
        // others, so both commits can land.
        if sinceSent < Self.commitCoinHoldMs { return true }
        guard (p.commitResends ?? 0) < 3 else { return false }
        await resendCommit(p)
        return true
    }

    private static let commitCoinHoldMs: Int64 = 130_000

    /// Sends the commit again - same name, owner and salt, so the same commit script - with
    /// the current fee, after a node dropped the first one.
    private func resendCommit(_ p: KachatNames.PendingRegistration) async {
        do {
            guard let s = try? ownerSigner(try KachatNames.unhex32(p.owner)) else { return }
            guard let salt = try KeychainService.shared.loadKachatCommitSalt(id: p.id, walletAddress: pendingWallet ?? s.address) else { throw ActionError.noSalt }
            let (b, env, wallet) = try await context(s, feerate: await registrationFeerate(p))
            let plan = try b.commit(env: env, wallet: wallet, name: p.name, salt: salt)
            guard let script = plan.newCommit?.utxo?.entry.script, KachatNames.hex(script) == p.commitScript else {
                throw KachatNames.Failure("commit: a different script")
            }
            let txId = try await service.signAndSubmit(plan, privateKey: s.privateKey, env: env)
            AppLog.log("[KachatNames] commit for %@ sent again: %@", p.name, txId)
            set(p) {
                $0.commitTxIds = ($0.commitTxIds ?? [$0.commitTxId]) + [txId]
                $0.commitTxId = txId
                $0.commitSentAt = KachatNames.nowMs()
                $0.commitResends = ($0.commitResends ?? 0) + 1
                $0.lastError = AppLocalization.string("The network is busy, so the commit was sent again.")
            }
        } catch {
            AppLog.log("[KachatNames] resending the commit for %@ failed: %@", p.name, error.localizedDescription)
            set(p) {
                $0.commitSentAt = KachatNames.nowMs()
                $0.commitResends = ($0.commitResends ?? 0) + 1
                $0.lastError = error.localizedDescription
            }
        }
    }

    /// Frees a lapsed old record of `p`'s name (a reclaim) and notes the gap it reopens.
    private func sendReclaim(of n: KachatNames.NameInfo, for p: KachatNames.PendingRegistration) async throws {
        let gaps = try await registry.exitGaps(for: n)
        // sent with no fee shown, like the register: the chosen speed under the background cap (IOS-061)
        let txId = try await reclaim(n, feerate: await registrationFeerate(p))
        set(p) {
            $0.reclaimTxId = txId
            $0.reclaimLo = KachatNames.hex(gaps.below.lo)
            $0.reclaimHi = KachatNames.hex(gaps.above.hi)
            $0.lastError = String(format: AppLocalization.string("Freeing %@ for you..."), KachatNameLabel.display(p.name))
        }
    }

    /// This wallet holds `name` as a live registration (a lapsed old record of it doesn't count:
    /// that is what claiming an expired name registers over).
    /// Nil when the registry can't say, or a node doesn't hold what it answered from.
    private func ownsName(_ name: String) async -> Bool? {
        guard let found = try? await registry.lookup(name), await isLiveOnChain(found) else { return nil }
        guard case .registered(let n) = found else { return false }
        return ownAddress(of: n.owner) != nil && n.status(graceMs: registry.graceMs) != .lapsed
    }

    private func register(_ p: KachatNames.PendingRegistration, commit: KachatNames.Utxo) async {
        do {
            // the address the claim was started from signs and pays, chatting or spending
            guard let s = try? ownerSigner(try KachatNames.unhex32(p.owner)) else { return }
            guard let salt = try KeychainService.shared.loadKachatCommitSalt(id: p.id, walletAddress: pendingWallet ?? s.address) else { throw ActionError.noSalt }
            await registry.refresh()
            let m = try await registry.prepare()
            // A commit isn't bound to a registry: one sent before a migration registers on the
            // new registry once its deadline passes. Until then it waits, saying why.
            do { try await Self.requireRegistrationOpen(m) } catch {
                set(p) { $0.lastError = error.localizedDescription }
                return
            }
            let gap: KachatNames.GapInfo
            switch try await registry.lookup(p.name) {
            case .registered(let n) where n.status(graceMs: registry.graceMs) == .lapsed:
                // An expired name is free to claim: this registration frees the old record first
                // (anyone may; its bond goes back to the old owner and the freed deposit comes to
                // you), then registers on a later tick once the registry shows the gap.
                // (Only sending the reclaim touches the record, so `updatedAt` is when it went out.)
                guard let tx = p.reclaimTxId else {
                    try await sendReclaim(of: n, for: p)
                    return
                }
                // The freed gap is the reclaim's output 0: register into it as soon as a node has
                // it, without waiting for the registry (a chain walk, or the indexer) to notice.
                if let lo = p.reclaimLo.flatMap({ try? KachatNames.unhex32($0) }), let hi = p.reclaimHi.flatMap({ try? KachatNames.unhex32($0) }),
                   let txid = try? KachatNames.unhex32(tx) {
                    let freed = KachatNames.GapInfo(lo: lo, hi: hi, outpoint: KachatNames.Outpoint(txid: txid, index: 0))
                    if (try? await liveGap(freed, m)) != nil {
                        gap = freed
                        break
                    }
                }
                if KachatNames.nowMs() - p.updatedAt > 120_000 {
                    set(p) { $0.reclaimTxId = nil } // never accepted: send it again
                }
                return
            case .registered(let n):
                // not on a copy that's behind: a throw is retried on the next tick
                try await registry.confirmOnChain(n)
                if n.owner == s.me { finishRegistered(p) } else { set(p) { $0.stage = .taken; $0.lastError = nil } }
                return
            case .free(_, let g):
                guard let g else { throw KachatNames.Failure("no gap for \(p.name) yet") }
                gap = g
            }
            let (b, env, wallet) = try await context(s, feerate: await registrationFeerate(p))
            let liveGapRecord = try await liveGap(gap, m)
            let plan: KachatNames.Plan
            do {
                plan = try b.register(
                    env: env, wallet: wallet, gap: liveGapRecord,
                    commit: KachatNames.CommitRecord(name: p.name, owner: s.me, salt: salt, value: commit.entry.amount, utxo: commit),
                    years: p.years, now: KachatNames.Builder.registerNow(env: env)
                )
            } catch let error where Self.isTooManyCoins(error) && !combinedFor.contains(p.id) {
                // the KAS is there in many small coins: combine them, then register on the next
                // tick with the same commit (once per registration; a second time it's real)
                combinedFor.insert(p.id)
                set(p) { $0.lastError = AppLocalization.string("Your KAS is in many small coins. Combining them into one first...") }
                try await combineCoins(s)
                set(p) { $0.lastError = nil }
                return
            }
            // Never pay more than the person confirmed (the fixed prices make this a safeguard).
            if let cap = p.maxPrice, plan.priceFee > cap { throw ActionError.priceChanged(plan.priceFee) }
            let txId = try await service.signAndSubmit(plan, privateKey: s.privateKey, env: env)
            set(p) {
                $0.stage = .registering
                $0.registerTxId = txId
                $0.registerTxIds = ($0.registerTxIds ?? []) + [txId]
                $0.lastError = nil
            }
            registry.refreshAfter(txId: txId)
        } catch {
            let message = error.localizedDescription
            AppLog.log("[KachatNames] register %@ failed: %@", p.name, message)
            // funds and a missing salt need the person; anything else (a gap that just moved, a
            // node hiccup) is retried on the next tick
            let fatal = message.contains("insufficient funds") || (error as? ActionError) != nil
            set(p) {
                $0.lastError = message
                if fatal { $0.stage = .failed }
            }
        }
    }

    /// Registrations this session already combined coins for (`combineCoins`).
    private var combinedFor: Set<String> = []

    private func finishRegistered(_ p: KachatNames.PendingRegistration) {
        if let address = pendingWallet { try? KeychainService.shared.deleteKachatCommitSalt(id: p.id, walletAddress: address) }
        set(p) { $0.stage = .registered; $0.lastError = nil }
    }

    private func finishCancelled(_ p: KachatNames.PendingRegistration) {
        if let address = pendingWallet { try? KeychainService.shared.deleteKachatCommitSalt(id: p.id, walletAddress: address) }
        set(p) { $0.stage = .cancelled; $0.lastError = nil }
        if let address = pendingWallet { remove(p.id, address: address) }
    }

    // MARK: - Persistence (Application Support/KachatNames/<network>/pending-<wallet>.json)

    private static func file(_ address: String) -> String { "pending-\(KachatNamesRegistry.walletSuffix(address)).json" }

    private func loadPending(for address: String) {
        let address = address.lowercased()
        guard pendingWallet != address else { return }
        pendingWallet = address
        if let data = KachatNamesRegistry.readFile(Self.file(address)),
           let list = try? JSONDecoder().decode([KachatNames.PendingRegistration].self, from: data) {
            pending = list
        } else {
            pending = []
        }
    }

    private func save() {
        guard let address = pendingWallet, let data = try? JSONEncoder().encode(pending) else { return }
        KachatNamesRegistry.writeFile(Self.file(address), data)
    }

    private func upsert(_ p: KachatNames.PendingRegistration) {
        if let i = pending.firstIndex(where: { $0.id == p.id }) { pending[i] = p } else { pending.append(p) }
        save()
    }

    private func remove(_ id: String, address: String) {
        try? KeychainService.shared.deleteKachatCommitSalt(id: id, walletAddress: address)
        pending.removeAll { $0.id == id }
        save()
    }
}