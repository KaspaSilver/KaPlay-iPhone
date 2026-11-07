import Foundation
import SwiftUI

/// The bell on the Wallet tab, KaPay's. It holds two things:
/// - Kaspa arriving on your chatting address from someone else (`WalletReceiptNotifier`, below:
///   KaPay's AddressActivityNotifier also watches spending and cold-storage addresses, which KaPlay's
///   UTXO subscription doesn't);
/// - your .kachat names: offers, sales, renewal and expiry, what happened to your offers
///   (`KachatNamesNotifier`).
/// Entries are account-scoped, persisted, deduped by id, and capped; opening the list marks
/// everything seen.
@MainActor
final class GlobalNotificationCenter: ObservableObject {
    static let shared = GlobalNotificationCenter()

    struct Entry: Identifiable, Codable, Equatable {
        enum Source: String, Codable {
            case wallet
            /// a .kachat name event; `targetId` is the name
            case kachat

            var label: String {
                switch self {
                case .wallet: return "Wallet"
                case .kachat: return ".kachat"
                }
            }

            var icon: String {
                switch self {
                case .wallet: return "arrow.down.circle"
                case .kachat: return "at"
                }
            }
        }

        let id: String
        let source: Source
        let title: String
        let body: String
        let timestamp: Int64 // ms
        /// The address that got the Kaspa, or the .kachat name - what tapping the row opens.
        let targetId: String?
    }

    /// One stored entry; nil for a row this build no longer lists (KaChat's chat, group and
    /// KaPosts rows an older build saved), so one of those never fails the whole list's decode.
    private struct StoredEntry: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var lastSeenAt: Int64 = 0

    private let maxEntries = 100

    var unreadCount: Int {
        entries.filter { $0.timestamp > lastSeenAt }.count
    }

    private init() {
        reload()
    }

    // MARK: - Persistence (account-scoped)

    private var walletAddress: String { WalletManager.shared.currentWallet?.publicAddress ?? "" }
    private var entriesKey: String { "globalNotifCenter.entries.\(walletAddress)" }
    private var seenKey: String { "globalNotifCenter.seenAt.\(walletAddress)" }

    /// Delete Account: one wallet's feed, from this device.
    static func removeAllData(forWalletAddress walletAddress: String) {
        UserDefaults.standard.removeObject(forKey: "globalNotifCenter.entries.\(walletAddress)")
        UserDefaults.standard.removeObject(forKey: "globalNotifCenter.seenAt.\(walletAddress)")
    }

    /// Call on account switch (and at init) to load the active wallet's feed.
    func reload() {
        if let data = UserDefaults.standard.data(forKey: entriesKey),
           let decoded = try? JSONDecoder().decode([StoredEntry].self, from: data) {
            let kept = decoded.compactMap(\.entry)
            entries = kept
            if kept.count != decoded.count { persist() }
        } else {
            entries = []
        }
        lastSeenAt = (UserDefaults.standard.object(forKey: seenKey) as? NSNumber)?.int64Value ?? 0
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(entries.prefix(maxEntries))) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
    }

    // MARK: - Feed mutations

    func record(id: String, source: Entry.Source, title: String, body: String, timestamp: Int64, targetId: String?) {
        guard !id.isEmpty, !entries.contains(where: { $0.id == id }) else { return }
        entries.insert(Entry(id: id, source: source, title: title, body: body, timestamp: timestamp, targetId: targetId), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        persist()
    }

    func markAllSeen() {
        lastSeenAt = Int64(Date().timeIntervalSince1970 * 1000)
        UserDefaults.standard.set(NSNumber(value: lastSeenAt), forKey: seenKey)
    }

    func clearAll() {
        entries = []
        persist()
    }
}

/// The bell's sheet: newest-first feed of all sources, source-tagged rows, Clear all.
/// Opening it marks everything seen (clears the bell badge).
struct GlobalNotificationListView: View {
    @ObservedObject private var center = GlobalNotificationCenter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if center.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bell")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No notifications yet")
                            .font(.headline)
                        Text("Kaspa arriving on your chatting address and news about your .kachat names show up here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(center.entries) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: entry.source.icon)
                                .font(.subheadline)
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title)
                                    .font(.subheadline.weight(.semibold))
                                if !entry.body.isEmpty {
                                    Text(entry.body)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                HStack(spacing: 6) {
                                    Text(entry.source.label)
                                    Text(Date(timeIntervalSince1970: TimeInterval(entry.timestamp) / 1000)
                                        .formatted(.relative(presentation: .named)))
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        // Every row opens its subject the way the OS notification tap does.
                        .contentShape(Rectangle())
                        .onTapGesture { open(entry) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear All") { center.clearAll() }
                        .disabled(center.entries.isEmpty)
                }
            }
            .onAppear { center.markAllSeen() }
        }
    }

    /// Routes a tapped row to its subject. The sheet has to close first (only one sheet presents
    /// at a time), so the pending target is staged now and the Wallet tab told after the
    /// dismissal animation - the Wallet tab opens it (`ChessWalletView`).
    private func open(_ entry: GlobalNotificationCenter.Entry) {
        let target = entry.targetId ?? ""
        guard !target.isEmpty else { return }
        switch entry.source {
        case .wallet:
            // A receipt opens the history of the address that got the Kaspa.
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                OwnAddressRoute.pending = target
                NotificationCenter.default.post(name: .openOwnAddress, object: nil)
            }
        case .kachat:
            // The name, its detail screen over the Wallet tab.
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                KachatDeepLink.pendingName = KachatNames.Codec.normalize(target)
                NotificationCenter.default.post(name: .openKachatName, object: nil)
            }
        }
    }
}

// MARK: - Received

/// "Received" rows for the bell: Kaspa that reached the chatting address from someone else. Fed
/// every live UTXO batch (`ChatService.handleUtxoChangeNotification`). A transaction counts as ours,
/// and never shows, when the same batch spent one of our coins, when this app sent it, or when any
/// of its inputs (the Kaspa REST API's resolved previous outpoints) is one of our addresses - so a
/// move's change, a send's change, a compound, a .kachat name transaction and anything another app
/// on the same seed sends stay out. A transaction that can't be read isn't shown: a missed row is
/// better than a wrong one. One row per transaction, the outputs to us summed.
@MainActor
final class WalletReceiptNotifier {
    static let shared = WalletReceiptNotifier()
    private init() {}

    /// Transactions already looked at, so a batch delivered twice is looked at once.
    private var handled: Set<String> = []

    func handle(_ parsed: ParsedUtxosChangedNotification) {
        guard let wallet = WalletManager.shared.currentWallet?.publicAddress else { return }
        let own = WalletManager.shared.ownAddressSetLowercased()
        // Any UTXO change on one of our addresses: open balances and lists refresh (KaPay's event).
        let involved = Set((parsed.added + parsed.removed).compactMap { $0.address?.lowercased() }).intersection(own)
        if !involved.isEmpty {
            NotificationCenter.default.post(name: .ownAddressUtxoActivity, object: nil,
                                            userInfo: [Self.utxoActivityAddressesKey: Array(involved)])
        }
        // The same batch spent one of our coins: whatever it added is our own change.
        guard !parsed.removed.contains(where: { $0.address.map { own.contains($0.lowercased()) } ?? false }) else { return }
        var amounts: [String: UInt64] = [:]
        for entry in parsed.added where !entry.isCoinbase && entry.address?.lowercased() == wallet.lowercased() {
            amounts[entry.transactionId, default: 0] += entry.amount
        }
        for (txId, amount) in amounts where !handled.contains(txId) {
            handled.insert(txId)
            guard !ChatService.shared.isKnownOutgoingAttemptTxId(txId) else { continue }
            Task { await self.confirmAndRecord(txId: txId, amount: amount, wallet: wallet) }
        }
    }

    private func confirmAndRecord(txId: String, amount: UInt64, wallet: String) async {
        // The API can be a moment behind the node: asked again a few times.
        var transaction: KaspaFullTransactionResponse?
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 4_000_000_000) }
            if let tx = await ChatService.shared.fetchFullTransaction(txId: txId),
               let inputs = tx.inputs, !inputs.isEmpty,
               inputs.allSatisfy({ !($0.previousOutpointAddress ?? "").isEmpty }) {
                transaction = tx
                break
            }
        }
        guard let transaction, WalletManager.shared.currentWallet?.publicAddress == wallet else { return }
        let own = WalletManager.shared.ownAddressSetLowercased()
        guard !(transaction.inputs ?? []).contains(where: { own.contains(($0.previousOutpointAddress ?? "").lowercased()) }) else { return }
        GlobalNotificationCenter.shared.record(
            id: "wallet-\(txId)", source: .wallet,
            title: "Received \(Self.formatKas(amount)) \(KaspaUnit.symbol)",
            body: "Chatting address \(Self.shortAddress(wallet))",
            timestamp: Int64(Date().timeIntervalSince1970 * 1000), targetId: wallet
        )
    }

    /// UserInfo key carrying the involved own addresses on a `.ownAddressUtxoActivity` post.
    static let utxoActivityAddressesKey = "addresses"

    static func formatKas(_ sompi: UInt64) -> String {
        var formatted = String(format: "%.8f", Double(sompi) / 100_000_000)
        while formatted.hasSuffix("0") { formatted.removeLast() }
        if formatted.hasSuffix(".") { formatted.removeLast() }
        return formatted
    }

    private static func shortAddress(_ address: String) -> String {
        address.count > 16 ? "\(address.prefix(12))...\(address.suffix(4))" : address
    }
}

// MARK: - Opening a row

/// Where a tapped "Received" row lands, kept until the Wallet tab takes it.
@MainActor
enum OwnAddressRoute {
    static var pending: String?
}

struct OwnAddressSheetTarget: Identifiable {
    let address: String
    var id: String { address }
}

/// One of your own addresses, opened from a tapped "Received" row on its History tab: the
/// chatting address or a spending address, each on the same screen you'd reach it through
/// (Manage Addresses). KaPay's, without Cold Storage.
struct OwnAddressHistorySheet: View {
    let address: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var walletManager: WalletManager

    private enum Resolved {
        case chatting
        case spending(SpendingAddressEntry)
        case unknown
        /// Its balance couldn't be read: a screen showing 0 would say it's empty, and its Send
        /// would be off.
        case unreadable
    }

    @State private var resolved: Resolved?

    var body: some View {
        NavigationStack {
            Group {
                switch resolved {
                case nil:
                    ProgressView()
                case .chatting?:
                    ChattingAddressManageView(address: address)
                case .spending(let entry)?:
                    SpendingAddressTransactionHistoryView(entry: entry)
                case .unreadable?:
                    VStack(spacing: 14) {
                        Text("Couldn't load the coins at this address")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            resolved = nil
                            Task { resolved = await resolve() }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .padding()
                case .unknown?:
                    Text("This address isn't in this wallet any more.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { resolved = await resolve() }
    }

    /// Which of your addresses it is, with its balance for the screen's header.
    private func resolve() async -> Resolved {
        let target = address.lowercased()
        if walletManager.currentWallet?.publicAddress.lowercased() == target { return .chatting }
        let utxos: [UTXO]
        do {
            utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
        } catch {
            return .unreadable
        }
        let balance = utxos.reduce(UInt64(0)) { $0 + $1.amount }
        var spending = walletManager.spendingAddresses(inRange: 0..<(max(0, walletManager.maxSpendingAddressIndex) + 1))
        if walletManager.maxQuantumAddressIndex >= 0 {
            let base = WalletManager.quantumIndexBase
            spending.merge(walletManager.spendingAddresses(inRange: base..<(base + walletManager.maxQuantumAddressIndex + 1))) { a, _ in a }
        }
        if let match = spending.first(where: { $0.value.lowercased() == target }) {
            return .spending(SpendingAddressEntry(
                index: match.key,
                address: match.value,
                balanceSompi: balance,
                isCurrent: match.key == walletManager.currentSpendingAddressIndex
            ))
        }
        return .unknown
    }
}

extension Notification.Name {
    /// Always-posted internal event for any UTXO activity on the wallet's own addresses, its own
    /// change included. UserInfo carries the involved addresses under
    /// `WalletReceiptNotifier.utxoActivityAddressesKey`.
    static let ownAddressUtxoActivity = Notification.Name("ownAddressUtxoActivity")
    /// KaPay posts this after its receive check on spending and cold-storage addresses; KaPlay has
    /// none, so nothing posts it. The screens ported from KaPay still listen for it.
    static let ownAddressActivity = Notification.Name("ownAddressActivity")
    /// A bell row for one of your addresses was tapped: `OwnAddressRoute.pending`.
    static let openOwnAddress = Notification.Name("openOwnAddress")
    /// A bell row or the expired-names banner named a .kachat name: `KachatDeepLink.pendingName`.
    static let openKachatName = Notification.Name("openKachatName")
}
