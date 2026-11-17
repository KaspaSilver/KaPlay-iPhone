import Foundation
import UIKit

/// A .kas profile change is two transactions: the commit locks 2 KAS at a script, and the reveal
/// spends it (back to the owner). If the reveal never goes out (the commit's answer was lost, the
/// app was closed, a node refused it) those coins stay at a script nothing else knows about. Each
/// commit is filed here before it is sent, and the reveal is tried again when the app becomes
/// active, as KaPay does (`KNSRevealRecovery` there).
///
/// A record is the only copy of the redeem script that frees those coins, so it stays until the
/// commit is spent: its reveal is tried whenever its account is signed in and the app becomes
/// active, however late (a profile value the person asked for, landing late, beats 2 KAS lost).
/// A commit seen on chain and then gone was spent by its reveal (here or on another device); one
/// never seen goes after 30 days and two empty checks. Nothing secret is filed; the key is read
/// from the Keychain at the time.
///
/// A retry of the same change finishes the filed commit instead of locking another 2 KAS
/// (`unfinished(retryKey:)`, `finishReveal(commitTxId:)`).
///
/// Domain transfers keep their own record (`KNSDomainTransferService.PendingTransfer`), finished
/// by sending the domain again.
@MainActor
enum KNSRevealRecovery {
    struct Pending: Codable {
        var commitTxId: String
        var wallet: String
        var redeemScript: Data
        var commitAddress: String
        var commitScriptPubKey: Data
        var commitAmountSompi: UInt64
        var revealAmountSompi: UInt64
        var commitOutputIndex: UInt32
        var ownerAddress: String
        /// nil: the chatting address
        var ownerSpendingIndex: Int?
        var changeAddress: String
        var revealTargetAddress: String
        var priorityFeeSompi: UInt64?
        var createdAt: Date
        /// What the commit does (`profileRetryKey`), so a retry of it can find it.
        var retryKey: String?
        /// The value the commit writes (public on chain anyway).
        var value: String?
        /// A node has shown the commit: once it is gone again, it was spent.
        var seenOnChain: Bool? = nil
        /// Checks past `abandonAfter` that found no commit.
        var misses: Int? = nil
    }

    enum FinishOutcome {
        /// The reveal went out now.
        case revealed(String)
        /// Nothing left to finish: the commit isn't on chain (not landed, or already revealed).
        case nothingToFinish
    }

    private static let storeKey = "kaplay_kns_pending_reveals_v1"
    /// A commit never seen on chain by then never got there.
    private static let abandonAfter: TimeInterval = 30 * 86_400
    /// Commits whose own send (or a retry of it) is running: it does the reveal itself.
    private static var inFlow: Set<String> = []
    private static var resuming = false
    /// This run's signed commits, so one whose outcome was unknown can go out again: the same
    /// transaction, which can't spend twice.
    private static var signedCommits: [String: KaspaRpcTransaction] = [:]
    /// Reveals sent by `resume`, so a retry that waited for it still has the id.
    private static var revealedBy: [String: String] = [:]
    private static var observer: NSObjectProtocol?

    static func profileRetryKey(assetId: String, key: String) -> String {
        "profile|\(assetId.lowercased())|\(key)"
    }

    private static func load() -> [Pending] {
        UserDefaults.standard.data(forKey: storeKey).flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? []
    }

    private static func save(_ list: [Pending]) {
        if list.isEmpty {
            UserDefaults.standard.removeObject(forKey: storeKey)
        } else if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    /// Calls `resume` every time the app becomes active (KaPay calls it from its scene phase).
    /// Installed once, when `NodePoolService` is created at launch.
    static func observeAppActivation() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await KNSRevealRecovery.resume() }
        }
    }

    /// Files a commit about to be sent; returns its id, computed here.
    static func begin(
        commitTx: KaspaRpcTransaction,
        context: KasiaTransactionBuilder.KNSCommitContext,
        ownerAddress: String,
        ownerSpendingIndex: Int?,
        changeAddress: String,
        revealTargetAddress: String,
        priorityFeeSompi: UInt64?,
        retryKey: String? = nil,
        value: String? = nil
    ) -> String {
        let id = KasiaTransactionBuilder.computeTransactionId(commitTx)
        inFlow.insert(id)
        signedCommits[id] = commitTx
        var list = load().filter { $0.commitTxId != id }
        list.append(Pending(
            commitTxId: id, wallet: WalletManager.shared.currentWallet?.publicAddress ?? ownerAddress,
            redeemScript: context.redeemScript, commitAddress: context.commitAddress,
            commitScriptPubKey: context.commitScriptPubKey, commitAmountSompi: context.commitAmountSompi,
            revealAmountSompi: context.revealAmountSompi, commitOutputIndex: context.commitOutputIndex,
            ownerAddress: ownerAddress, ownerSpendingIndex: ownerSpendingIndex, changeAddress: changeAddress,
            revealTargetAddress: revealTargetAddress, priorityFeeSompi: priorityFeeSompi, createdAt: Date(),
            retryKey: retryKey, value: value
        ))
        save(list)
        return id
    }

    /// The commit's own send is over, however it went: anything left is now `resume`'s.
    static func endFlow(_ id: String) {
        inFlow.remove(id)
    }

    /// The reveal went out, or the commit is spent (or never got there): the record goes.
    static func finished(_ id: String) {
        save(load().filter { $0.commitTxId != id })
        signedCommits[id] = nil
    }

    private static func update(_ id: String, _ change: (inout Pending) -> Void) {
        var list = load()
        guard let i = list.firstIndex(where: { $0.commitTxId == id }) else { return }
        change(&list[i])
        save(list)
    }

    /// Commits of the signed-in account filed for `retryKey`, oldest first.
    static func unfinished(retryKey: String) -> [Pending] {
        guard let wallet = WalletManager.shared.currentWallet?.publicAddress else { return [] }
        return load()
            .filter { $0.wallet == wallet && $0.retryKey == retryKey }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Sends the reveal of the filed commit `commitTxId`, for a retry of the same change: no new
    /// commit. A commit this run signed and the network can't see is sent again first (the same
    /// transaction). A failed read of the chain throws: never a new commit on a guess.
    static func finishReveal(commitTxId id: String) async throws -> FinishOutcome {
        // `resume` may be on this very commit: let it finish first
        var waits = 0
        while resuming, waits < 120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waits += 1
        }
        guard let p = load().first(where: { $0.commitTxId == id }) else {
            if let revealTxId = revealedBy[id] { return .revealed(revealTxId) }
            return .nothingToFinish
        }
        inFlow.insert(id)
        defer { inFlow.remove(id) }

        let listed = try await NodePoolService.shared.getUtxosByAddresses([p.commitAddress])
        var commitIsLive = listed.contains { isCommitOutput($0, of: p) }
        if commitIsLive, p.seenOnChain != true { update(id) { $0.seenOnChain = true } }
        if !commitIsLive, let commit = signedCommits[id] {
            do {
                _ = try await NodePoolService.shared.submitTransaction(commit, allowOrphan: false, escalateOrphan: false)
                commitIsLive = true
            } catch let unknown as SendOutcomeUnknownError {
                throw unknown
            } catch {
                commitIsLive = false
            }
        }
        // not landed (resume still watches it), or already revealed
        guard commitIsLive else { return .nothingToFinish }
        let revealTxId = try await sendReveal(for: p)
        finished(id)
        AppLog.log("[KNS] finished the reveal of commit %@: %@", String(id.prefix(12)), String(revealTxId.prefix(12)))
        return .revealed(revealTxId)
    }

    /// Sends the reveal of any commit left on chain with none, for the signed-in account, and
    /// drops the records whose commit is spent (or never got there), whichever account filed them.
    static func resume() async {
        guard !resuming else { return }
        resuming = true
        defer { resuming = false }
        guard !load().isEmpty else { return }
        // at launch the app becomes active before any node is connected
        var waits = 0
        while !NodePoolService.shared.isReady, waits < 30 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waits += 1
        }
        let wallet = WalletManager.shared.currentWallet?.publicAddress
        for p in load() where !inFlow.contains(p.commitTxId) {
            // only a node's answer counts: none says nothing
            guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses([p.commitAddress]) else { continue }
            guard utxos.contains(where: { isCommitOutput($0, of: p) }) else {
                if p.seenOnChain == true {
                    // seen before and gone now: its reveal spent it (from here or another device)
                    finished(p.commitTxId)
                } else if Date().timeIntervalSince(p.createdAt) > abandonAfter {
                    let misses = (p.misses ?? 0) + 1
                    if misses >= 2 {
                        AppLog.log("[KNS] commit %@ never reached the chain: dropped", String(p.commitTxId.prefix(12)))
                        finished(p.commitTxId)
                    } else {
                        update(p.commitTxId) { $0.misses = misses }
                    }
                }
                continue
            }
            if p.seenOnChain != true { update(p.commitTxId) { $0.seenOnChain = true } }
            // the reveal needs the filing account's key: another account's waits for it
            guard let wallet, p.wallet == wallet, WalletManager.shared.currentWallet?.publicAddress == wallet,
                  !inFlow.contains(p.commitTxId) else { continue }
            do {
                let txId = try await sendReveal(for: p)
                AppLog.log("[KNS] sent the reveal of a commit left without one: %@", String(txId.prefix(12)))
                revealedBy[p.commitTxId] = txId
                finished(p.commitTxId)
            } catch {
                AppLog.log("[KNS] reveal of commit %@ failed again: %@", String(p.commitTxId.prefix(12)), error.localizedDescription)
            }
        }
    }

    private static func isCommitOutput(_ utxo: UTXO, of p: Pending) -> Bool {
        utxo.outpoint.transactionId.lowercased() == p.commitTxId.lowercased() && utxo.outpoint.index == p.commitOutputIndex
    }

    private static func sendReveal(for p: Pending) async throws -> String {
        let storedKey = p.ownerSpendingIndex.map { WalletManager.shared.spendingPrivateKey(at: $0) } ?? WalletManager.shared.getPrivateKey()
        guard let key = storedKey else {
            throw KasiaError.keychainError("Could not get private key")
        }
        let context = KasiaTransactionBuilder.KNSCommitContext(
            redeemScript: p.redeemScript, commitAddress: p.commitAddress, commitScriptPubKey: p.commitScriptPubKey,
            commitAmountSompi: p.commitAmountSompi, revealAmountSompi: p.revealAmountSompi, commitOutputIndex: p.commitOutputIndex
        )
        let reveal: KaspaRpcTransaction
        if let priorityFeeSompi = p.priorityFeeSompi {
            reveal = try KasiaTransactionBuilder.buildKNSAddProfileRevealTx(
                ownerAddress: p.ownerAddress, ownerPrivateKey: key, changeAddress: p.changeAddress, commitTxId: p.commitTxId,
                commitContext: context, revealTargetAddress: p.revealTargetAddress, revealPriorityFeeSompi: priorityFeeSompi
            )
        } else {
            reveal = try KasiaTransactionBuilder.buildKNSAddProfileRevealTx(
                ownerAddress: p.ownerAddress, ownerPrivateKey: key, changeAddress: p.changeAddress, commitTxId: p.commitTxId,
                commitContext: context, revealTargetAddress: p.revealTargetAddress
            )
        }
        let txId: String
        do {
            txId = try await NodePoolService.shared.submitTransaction(reveal, allowOrphan: false).txId
        } catch let unknown as SendOutcomeUnknownError {
            throw unknown
        } catch let error where error.localizedDescription.lowercased().contains("orphan") {
            // its parent is this commit, which is on its way
            txId = try await NodePoolService.shared.submitTransaction(reveal, allowOrphan: true).txId
        }
        ChatService.shared.registerSuppressedPaymentTxIds([p.commitTxId, txId], reason: "kns-profile-reveal")
        return txId
    }
}
