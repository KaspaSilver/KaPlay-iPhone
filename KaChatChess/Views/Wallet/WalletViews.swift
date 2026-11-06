import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// The Wallet tab, the same look as KaPost's Wallet screen, and the Receive / Send sheets it opens.

/// The Wallet tab, like KaPost's `KaPostWalletView`: the total up top, split into the chatting and
/// spending addresses, then Send, Receive and More (Compound UTXOs, keys, the explorer), the Backup
/// Hygiene card when due, then the chatting address's history. KaPlay only uses the chatting
/// address, the one every move and bot result is signed by: Send leaves from it and Receive is paid
/// to it. Other addresses count in the total and are managed in KaChat and KaPay.
struct ChattingAddressManageView: View {
    let address: String

    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var priceStore = KaspaPriceStore.shared
    @ObservedObject private var backupStatus = AccountBackupStatus.shared

    @State private var transactions: [KaspaFullTransactionResponse] = []
    /// The last history fetch gave up partway. Kept separate from `transactions.isEmpty` because
    /// the two mean opposite things: a rate-limited request isn't an address never used.
    @State private var historyIncomplete = false
    @State private var isLoading = false
    /// Only for Compound UTXOs, which needs two or more coins to combine.
    @State private var utxos: [UTXO] = []
    /// Every revealed spending address together. Nil until it's known, which shows as a dash.
    @State private var spendingTotalSompi: UInt64?
    @State private var showReceiveSheet = false
    @State private var showSendSheet = false
    @State private var showCompoundSheet = false
    @State private var showPrivateKeySheet = false
    /// The More half sheet, and the public-key screen it can open.
    @State private var showAddressActions = false
    @State private var showPublicKeySheet = false
    @State private var showBackupHygiene = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    /// The live balance when this is the signed-in address: WalletManager follows the node's
    /// UTXO notifications, so a payment shows the moment it lands.
    private var liveBalanceSompi: UInt64? {
        guard let wallet = walletManager.currentWallet, wallet.publicAddress == address else { return nil }
        return wallet.balanceSompi
    }

    /// Nil until it's known, which shows as a dash: a failed read isn't an empty address.
    private var balanceSompi: UInt64? {
        liveBalanceSompi ?? (utxos.isEmpty ? nil : utxos.reduce(UInt64(0)) { $0 + $1.amount })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                balanceCard
                actionsRow
                if backupStatus.isHygieneDue(address) {
                    BackupHygieneCard { showBackupHygiene = true }
                }
                history
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable { await refresh() }
        .fixedScreenTitle(Text("Wallet"), showsBackupBanner: true)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .toast(message: toastMessage)
        .sheet(isPresented: $showAddressActions) {
            addressActionsSheet
                .presentationDetents([.height(410)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPublicKeySheet) {
            ChattingAddressPublicKeyView(address: address)
        }
        .sheet(isPresented: $showBackupHygiene) {
            BackupHygieneView()
        }
        .sheet(isPresented: $showReceiveSheet) {
            NavigationStack {
                // nil while unknown: the sheet shows a dash, not a 0 the address may not hold
                ChattingAddressQRView(address: address, balanceSompi: balanceSompi)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Close") { showReceiveSheet = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showSendSheet) {
            WithdrawKaspaView(fromAddress: address, availableBalanceSompi: balanceSompi,
                              lockedSource: .chatting) {
                Task { await refresh() }
            }
            .sendKaspaSheetSizing()
        }
        .sheet(isPresented: $showCompoundSheet) {
            WithdrawKaspaView(fromAddress: address, availableBalanceSompi: balanceSompi, isCompoundMode: true) {
                Task { await refresh() }
            }
            .sendKaspaSheetSizing()
        }
        .sheet(isPresented: $showPrivateKeySheet) {
            ChattingAddressPrivateKeyView(address: address)
        }
        .task { await refresh() }
        // The coins moved (a payment in, a move or send out): the history follows. It comes from
        // the indexer, which can be a moment behind the node, so it is asked again a few seconds
        // later.
        .onChange(of: liveBalanceSompi) { _ in
            Task {
                await loadUtxos()
                await loadSpendingTotal()
                await loadTransactions()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await loadTransactions()
            }
        }
    }

    // MARK: - Balance

    private var balanceCard: some View {
        let chatting = balanceSompi
        // Both parts or a dash: a total missing one of them would read as the whole balance.
        let total: UInt64? = {
            guard let chatting, let spendingTotalSompi else { return nil }
            return chatting + spendingTotalSompi
        }()
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Total Balance")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button {
                    guard let total else { return }
                    UIPasteboard.general.string = KaspaUnit.plain(total)
                    Haptics.success()
                    showToast(AppLocalization.string("Balance copied to clipboard."))
                } label: {
                    Text(verbatim: total.map(KaspaUnit.amount) ?? "--")
                        .font(.largeTitle.weight(.bold))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .buttonStyle(.plain)
                if let fiat = fiatText(total) {
                    Text(verbatim: fiat)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 16) {
                balancePart(title: "Chatting", sompi: chatting)
                balancePart(title: "Spending", sompi: spendingTotalSompi)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 0.8)
                )
        )
    }

    private func balancePart(title: LocalizedStringKey, sompi: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(verbatim: sompi.map(KaspaUnit.amount) ?? "--")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the balance is worth in your currency. Testnet coins aren't worth anything.
    private func fiatText(_ sompi: UInt64?) -> String? {
        guard let sompi, AppSettings.load().networkType == .mainnet,
              let price = priceStore.currentPriceUsd, price > 0 else { return nil }
        return formatFiatAmount(Double(sompi) / 100_000_000.0 * price, currency: priceStore.currentCurrency)
    }

    // MARK: - Actions

    private var actionsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            actionButton(title: "Send", icon: "arrow.up", enabled: (balanceSompi ?? 0) > 0) { showSendSheet = true }
            actionButton(title: "Receive", icon: "arrow.down") { showReceiveSheet = true }
            actionButton(title: "More", icon: "ellipsis") { showAddressActions = true }
        }
    }

    private func actionButton(title: LocalizedStringKey, icon: String, enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            perform()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.scaled(size: 22, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Color.accentColor))
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    /// The half sheet behind More: Compound UTXOs (greyed out under two coins), the chatting
    /// address's keys and the explorer.
    private var addressActionsSheet: some View {
        VStack(spacing: 0) {
            Text("Chatting Address")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 16)

            VStack(spacing: 12) {
                // Always listed, so it's there to find; it takes two coins to combine.
                ActionSheetRow(
                    title: "Compound UTXOs",
                    subtitle: utxos.count > 1
                        ? "Combines this address's coins into one, so later sends need fewer inputs."
                        : "Combines this address's coins into one. It needs two or more coins.",
                    systemImage: "arrow.triangle.merge",
                    isDisabled: utxos.count < 2
                ) {
                    showAddressActions = false
                    DispatchQueue.main.async { showCompoundSheet = true }
                }
                ActionSheetRow(
                    title: "View Private Key",
                    subtitle: "The key that spends this address. Never share it.",
                    systemImage: "key.fill"
                ) {
                    showAddressActions = false
                    // A turn later: presenting straight from a dismissing sheet is dropped.
                    DispatchQueue.main.async {
                        // Settings' "Biometrics for Address Private Keys", which this key is one of
                        if settingsViewModel.settings.biometricSpendingKeyEnabled {
                            DeviceAuth.authenticate(reason: "Unlock to view this address's private key") {
                                showPrivateKeySheet = true
                            }
                        } else {
                            showPrivateKeySheet = true
                        }
                    }
                }
                ActionSheetRow(
                    title: "View Public Key",
                    subtitle: "The public half of this address, for anyone who asks for it.",
                    systemImage: "number"
                ) {
                    showAddressActions = false
                    DispatchQueue.main.async { showPublicKeySheet = true }
                }
                if let url = settingsViewModel.settings.kaspaExplorer.addressURL(for: address) {
                    ActionSheetRow(
                        title: "View in Explorer",
                        subtitle: "Opens this address on your chosen block explorer.",
                        systemImage: "globe"
                    ) {
                        showAddressActions = false
                        UIApplication.shared.open(url)
                    }
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.bottom, 20)
    }

    // MARK: - History

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transaction History")
                .font(.headline)
            if isLoading && transactions.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 18)
            } else if transactions.isEmpty && historyIncomplete {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Could not load transactions.")
                        .foregroundColor(.secondary)
                    Button("Try Again") {
                        Task { await loadTransactions() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            } else if transactions.isEmpty {
                Text("No transactions yet.")
                    .foregroundColor(.secondary)
            } else {
                if historyIncomplete {
                    Text("Some transactions could not be loaded. Pull to refresh to try again.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                VStack(spacing: 0) {
                    ForEach(transactions, id: \.transactionId) { tx in
                        Button {
                            Haptics.impact(.light)
                            openInExplorer(tx)
                        } label: {
                            transactionRow(tx)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if tx.transactionId != transactions.last?.transactionId {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func transactionRow(_ tx: KaspaFullTransactionResponse) -> some View {
        let info = tx.direction(for: address)
        return HStack(spacing: 12) {
            Image(systemName: info?.isOutgoing == true ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundColor(info == nil ? .secondary : (info!.isOutgoing ? .red : .green))

            VStack(alignment: .leading, spacing: 2) {
                Text(info == nil ? "Transaction" : (info!.isOutgoing ? "Sent" : "Received"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(info == nil ? .secondary : (info!.isOutgoing ? .red : .green))
                Text(tx.transactionId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let blockTime = tx.blockTime {
                    Text(Date(timeIntervalSince1970: Double(blockTime) / 1000).formatted(Self.blockTimeFormat))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let info {
                    Text(verbatim: "\(info.isOutgoing ? "-" : "+")\(formatKasExact(info.amountSompi)) \(KaspaUnit.symbol)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(info.isOutgoing ? .red : .green)
                }
                // The network fee this transaction paid (inputs minus outputs).
                if let fee = tx.feeText() {
                    Text(fee)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    /// Built once: `Date.formatted(date:time:)` resolves a fresh style per call, and this runs
    /// for every transaction row on every render of the list.
    private static let blockTimeFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)

    private func formatKasExact(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
    }

    // MARK: - Loading

    private func refresh() async {
        async let coins: Void = loadUtxos()
        async let spending: Void = loadSpendingTotal()
        async let history: Void = loadTransactions()
        _ = await (coins, spending, history)
    }

    private func loadSpendingTotal() async {
        // A read that finishes after an account switch belongs to the old account: dropped.
        let account = walletManager.currentWallet?.publicAddress
        // The whole set, in ONE call - a per-address loop would be dozens of requests on a wallet
        // that has been used, and the node takes the list.
        let all = walletManager.allSpendingAddresses()
        // None revealed yet: nothing has been sent there.
        guard !all.isEmpty else {
            spendingTotalSompi = 0
            return
        }
        // A failure leaves the previous total in place: a few seconds stale reads better than a
        // figure that vanishes because one request timed out.
        if let utxos = try? await NodePoolService.shared.getUtxosByAddresses(all),
           walletManager.currentWallet?.publicAddress == account {
            spendingTotalSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
        }
    }

    private func loadUtxos() async {
        // A failure keeps what it had: an outage is not an empty address.
        guard let fresh = try? await NodePoolService.shared.getUtxosByAddresses([address]) else { return }
        utxos = fresh
        // A fresh count is the balance: keep the app-wide one (the bar's) in step.
        walletManager.updateBalanceIfCurrentWallet(address: address, utxos: fresh)
    }

    private func loadTransactions() async {
        isLoading = true
        let result = await chatService.fetchFullTransactionsResult(for: address, pageSize: 200, maxTransactions: 200)
        // block rewards the chain never accepted paid nothing: not history
        transactions = result.transactions.filter(\.belongsInHistory)
        historyIncomplete = !result.complete
        isLoading = false
    }

    private func openInExplorer(_ tx: KaspaFullTransactionResponse) {
        guard let url = settingsViewModel.settings.kaspaExplorer.txURL(for: tx.transactionId) else { return }
        UIApplication.shared.open(url)
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}

/// Private-key reveal for the wallet's own chatting/identity address — mirrors
/// SpendingAddressPrivateKeyView, but reads the wallet's own root private key rather than a
/// derived spending key, since the identity address isn't part of the spending-chain derivation.
/// Gated by `biometricSpendingKeyEnabled`, Settings' "Biometrics for Address Private Keys": it is an
/// address's private key like the others that toggle covers (the Wallet's More sheet checks it).
private struct ChattingAddressPrivateKeyView: View {
    let address: String
    @Environment(\.dismiss) private var dismiss

    @State private var isRevealed = false
    @State private var revealToken = UUID()
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    private var privateKeyHex: String {
        WalletManager.shared.getPrivateKey()?.hexString ?? "Unavailable"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Security Warning", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundColor(.orange)
                    Text("Anyone with this address's private key can spend its funds. Never share it with anyone.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if isRevealed {
                    SecureView {
                        Text(privateKeyHex)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        copySensitiveToClipboard(privateKeyHex)
                        Haptics.success()
                        showToast("Private key copied. Clipboard will clear in 30s.")
                    } label: {
                        Label("Copy Private Key Hex", systemImage: "doc.on.doc")
                    }
                    .padding(.top)
                } else {
                    Button {
                        isRevealed = true
                        let token = UUID()
                        revealToken = token
                        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                            if revealToken == token {
                                isRevealed = false
                            }
                        }
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "eye.slash.fill")
                                .font(.largeTitle)
                            Text("Tap to reveal private key")
                                .font(.subheadline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(60)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Chatting Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .toast(message: toastMessage)
        }
    }

    /// Sensitive copy: hard 30s system expiration + localOnly (no Universal Clipboard sync);
    /// the asyncAfter wipe is an in-app belt-and-suspenders clear (see SettingsView's twin).
    private func copySensitiveToClipboard(_ value: String) {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)]
        )
        let copiedValue = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if UIPasteboard.general.string == copiedValue {
                UIPasteboard.general.string = ""
            }
        }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}

/// The chatting address's public key, from the Address Actions sheet.
///
/// Nothing is derived or unlocked to show this: a Kaspa P2PK address IS its public key in bech32,
/// so this decodes the address the screen already has. No reveal gate and no clipboard expiry
/// either - unlike the private key alongside it, this is a value you hand out on purpose.
private struct ChattingAddressPublicKeyView: View {
    let address: String
    @Environment(\.dismiss) private var dismiss

    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    /// nil only for an address shape that carries no key (script-hash), which the wallet's own
    /// chatting address never is.
    private var publicKeyHex: String? {
        KaspaAddress.publicKey(from: address)?.hexString
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Safe to share", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                    Text("This is the public half of your chatting address. It identifies you and cannot spend anything.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if let publicKeyHex {
                    Text(publicKeyHex)
                        .font(.system(.footnote, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Button {
                        UIPasteboard.general.string = publicKeyHex
                        Haptics.success()
                        showToast("Public key copied")
                    } label: {
                        Label("Copy Public Key", systemImage: "doc.on.doc")
                    }
                } else {
                    Text("This address does not carry a public key.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Public Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .toast(message: toastMessage)
        }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}

/// Dedicated white-background QR display, matching Android's "Accept Kaspa"/"Chatting Address"
/// QR screen — deliberately uses literal black/white colors rather than adaptive .primary/
/// .secondary, since forcing a white content area regardless of system dark/light mode would
/// otherwise leave semantic text colors resolved for dark mode (and invisible on the white
/// background) unless the whole screen's color scheme were overridden too.
struct ChattingAddressQRView: View {
    let address: String
    let balanceSompi: UInt64?
    var subtitle: String = "Every online move you play is a Kaspa transaction from this address, about 0.0017 KAS each: 1 KAS covers about 500 moves."

    @State private var qrImage: UIImage?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    var body: some View {
        Color.white
            .ignoresSafeArea()
            .overlay(
                VStack(spacing: 28) {
                    Spacer()
                    Group {
                        if let qrImage {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 240, height: 240)
                        } else {
                            ProgressView()
                                .frame(width: 240, height: 240)
                        }
                    }
                    .padding(20)
                    .background(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 3)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Text(address)
                        .font(.footnote.monospaced())
                        .foregroundColor(.black)
                        .multilineTextAlignment(.center)
                        // Show the whole address, always. A Kaspa address is ~60-66 chars with no
                        // spaces; capping at 2 lines truncated it on narrower screens. Let it wrap
                        // to as many lines as needed and take the vertical space it requires.
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)

                    // Looked up, not shown verbatim - it read English in every language.
                    Text(LocalizedStringKey(subtitle))
                        .font(.subheadline)
                        .foregroundColor(Color.black.opacity(0.6))
                        .multilineTextAlignment(.center)
                        // Its full height always: in a sheet that is still growing (the Chats
                        // New sheet) it otherwise truncated, then re-wrapped and jumped.
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 40)

                    Text("Tap anywhere to copy")
                        .font(.footnote)
                        .foregroundColor(Color.black.opacity(0.4))

                    Spacer()
                    Spacer()
                }
            )
            .contentShape(Rectangle())
            .onTapGesture { copyAddress() }
            .toast(message: toastMessage)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // Black in dark mode too: this screen is always white.
                    VStack(spacing: 0) {
                        Text("Receive")
                            .font(.headline)
                        Text(balanceSompi.map { "\(formatKaspaExact($0)) \(KaspaUnit.symbol)" } ?? "—")
                            .font(.caption)
                            .fontWeight(.bold)
                            .monospacedDigit()
                    }
                    .foregroundColor(.black)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                qrImage = ProfileQRCodeCache.cachedImage(for: address)
                ProfileQRCodeCache.preload(address: address) { image in
                    qrImage = image
                }
            }
    }

    private func copyAddress() {
        UIPasteboard.general.string = address
        Haptics.success()
        showToast(address.addressCopiedToastText)
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func formatKaspaExact(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        return String(format: "%.8f", kas)
    }
}

/// Fee-priority tiers for the Withdraw Kaspa flow — each tier is a multiplier applied to the
/// already-estimated base (Normal) fee, letting the user pay extra during network congestion
/// without a second network round-trip per tier.
enum WithdrawFeeTier: String, CaseIterable, Identifiable, Hashable {
    case normal = "Normal"
    case fast = "Fast"
    case priority = "Priority"

    var id: String { rawValue }

    var multiplier: UInt64 {
        switch self {
        case .normal: return 1
        case .fast: return 2
        case .priority: return 5
        }
    }
}

/// Sends a plain KAS transfer from one of your addresses to any address or name, in KaPay's
/// steps (built from `SendKaspaComponents.swift`): who to, how much on the app's own keypad, then
/// a review where only the fee and coin control can change before swiping up to send. Compound
/// UTXOs (a self-send of everything at `fromAddress`) opens straight on the review.
struct WithdrawKaspaView: View {
    let fromAddress: String
    let availableBalanceSompi: UInt64?
    /// Pre-fills the recipient with `fromAddress` itself (a self-send) and auto-fills Max, for
    /// the "Compound UTXOs" entry point - merges every UTXO at this address into one.
    var isCompoundMode: Bool = false
    /// Pre-fills the recipient; it stays editable. Opens on the amount.
    var prefillAddress: String? = nil
    /// Opened from one address's history (its Send button): the Kaspa leaves from that address
    /// and there is no From step.
    var lockedSource: SendSource? = nil
    var onComplete: (() -> Void)? = nil

    /// Where the Kaspa leaves from (the From step): the chatting address by default.
    @State private var source: SendSource = .chatting
    /// The From address's balance: the amount's Available and its check.
    @State private var sourceBalanceSompi: UInt64?

    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var priceStore = KaspaPriceStore.shared
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    @State private var addressInput = ""
    @State private var isValidAddress = false
    @State private var amountInput = ""
    @State private var showQRScanner = false
    @State private var isSending = false
    @State private var errorMessage: String?
    /// The completed send: the swipe-up's confirmation shows it.
    @State private var sentTransaction: SentTransaction?

    @State private var isResolvingKNS = false
    @State private var resolvedAddress: String?
    @State private var resolvedDomain: String?
    /// Every service's answer for a typed name and the one in use: the rest go under "Other domains".
    @State private var nameResolutions: [NameResolution] = []
    @State private var selectedTLD: NameServiceTLD?
    @State private var knsError: String?

    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var normalFeeSompi: UInt64?
    @State private var isEstimatingFee = false
    @State private var isEstimatingMax = false
    @State private var customExtraFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var customFeeText = ""

    @State private var manualUtxos: [UTXO]?
    @State private var showCoinControl = false

    /// The step on screen; nil until the first move (then `initialStep`).
    @State private var step: Step?
    /// The last move went forward: the next step comes in from the right.
    @State private var stepForward = true
    /// The amount is Max: a fee or coin change works it out again.
    @State private var usedMax = false
    /// The From step's Choose an Address is on (its list shows), before or after a pick.
    @State private var choosingFrom = false
    /// Why the fee couldn't be worked out (usually: not enough Kaspa for the amount and fee).
    @State private var feeError: String?
    /// The fee being typed on the fee screen, in KAS.
    @State private var feeDraft = ""
    /// The fee this exact send pays at the chosen speed (network fee, extra and any change too
    /// small to keep), from an estimate made with that extra; nil until it is known.
    @State private var builtFeeSompi: UInt64?
    /// The Max on screen is what one transaction can carry, not the whole balance (the address
    /// holds more coins than one transaction can spend).
    @State private var maxCapped = false
    /// The latest Max request: an older one finishing later (a fee tapped twice fast) is dropped.
    @State private var maxRequest = UUID()

    private let knsService = KNSService.shared

    /// The actual address to use (resolved from a KNS domain, or the direct input).
    private var effectiveAddress: String {
        resolvedAddress ?? addressInput
    }

    private var amountSompi: UInt64? {
        guard let sompi = KaspaUnit.sompi(fromUserText: amountInput), sompi > 0 else { return nil }
        return sompi
    }

    /// True once we have a usable recipient — either a resolved KNS domain or a directly
    /// valid Kaspa address.
    private var hasValidRecipient: Bool {
        if resolvedAddress != nil { return true }
        return isValidAddress && !isResolvingKNS
    }

    /// The swipe waits for the amount and the fee it shows to be the ones that will be sent: not
    /// while Max or the fee is being worked out again, and not when the fee couldn't be.
    private var canSend: Bool {
        hasValidRecipient && amountSompi != nil && !isSending
            && !isEstimatingMax && !isEstimatingFee && feeError == nil && totalFeeSompi != nil
    }

    /// Extra priority tip on top of the base (Normal-tier) fee, for network congestion.
    /// A custom fee (the fee editor) overrides the tier multiplier until a tier is tapped again.
    private var extraFeeSompi: UInt64 {
        guard let normalFeeSompi else { return 0 }
        if let customExtraFeeSompi { return customExtraFeeSompi }
        return normalFeeSompi * (feeTier.multiplier - 1)
    }

    private var totalFeeSompi: UInt64? {
        guard normalFeeSompi != nil else { return nil }
        return builtFeeSompi
    }

    /// Debounce/cancellation key. The speed and a custom fee are in it: a bigger extra can make the
    /// send take another coin, or no longer leave change worth keeping, so the fee shown is worked
    /// out with the extra actually paid rather than added on top of the Normal estimate.
    private var feeEstimationKey: String {
        let manualKey = manualUtxos?.map { "\($0.outpoint.transactionId):\($0.outpoint.index)" }.sorted().joined(separator: ",") ?? ""
        return "\(hasValidRecipient ? effectiveAddress : "")|\(amountSompi ?? 0)|\(manualKey)|\(source.spendingIndex ?? -1)|\(feeTier.rawValue)|\(customExtraFeeSompi.map { String($0) } ?? "")"
    }

    /// The steps of a send: who it goes to, which of your addresses it leaves from, how much
    /// (on the app's own keypad, so no keyboard stays up), and a review where only the fee and
    /// coin control can change before swiping up to send. The fee editor opens from the review.
    private enum Step: Int { case recipient, from, amount, review, fee }

    /// The step a send opens on: Compound UTXOs straight to the review (its recipient and amount
    /// are set), a pre-filled recipient to From (or the amount, when From is fixed).
    private var initialStep: Step {
        if isCompoundMode { return .review }
        if prefillAddress != nil { return afterRecipient }
        return .recipient
    }

    /// The step after To: From, unless the send's From is fixed (an address's own Send).
    private var afterRecipient: Step { lockedSource == nil ? .from : .amount }

    private var currentStep: Step { step ?? initialStep }

    private var screenTitle: String {
        isCompoundMode ? "Compound UTXOs" : "Send Kaspa"
    }

    /// Where Back goes from a step; nil for the first one.
    private func backStep(from step: Step) -> Step? {
        switch step {
        case .recipient: return nil
        case .from: return .recipient
        case .amount:
            if lockedSource == nil { return .from }
            return isCompoundMode ? nil : .recipient
        case .review: return isCompoundMode ? nil : .amount
        case .fee: return .review
        }
    }

    private func go(to next: Step) {
        dismissSystemKeyboard()
        stepForward = next.rawValue > currentStep.rawValue
        // The leaving step re-renders with the new direction before it animates out.
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { step = next }
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: stepForward ? .trailing : .leading),
                    removal: .move(edge: stepForward ? .leading : .trailing))
    }

    /// The amount is more than the From address holds.
    private var exceedsBalance: Bool {
        guard let amountSompi, let sourceBalanceSompi else { return false }
        return amountSompi > sourceBalanceSompi
    }

    private var canContinueFromAmount: Bool {
        hasValidRecipient && amountSompi != nil && !exceedsBalance && !isEstimatingMax
    }

    var body: some View {
        NavigationStack {
            ZStack {
                switch currentStep {
                case .recipient:
                    recipientStep.transition(stepTransition)
                case .from:
                    fromStep.transition(stepTransition)
                case .amount:
                    amountStep.transition(stepTransition)
                case .review:
                    reviewStep.transition(stepTransition)
                case .fee:
                    feeStep.transition(stepTransition)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // The recipient card only shows the lookup; this screen runs it.
            .onChange(of: addressInput) { handleInputChange($0) }
            // coins picked on one address can't pay from another
            .onChange(of: source) { _ in
                manualUtxos = nil
                if usedMax { setMaxAmount() }
            }
            // the From address's balance: the amount's Available and its check
            .task(id: source) {
                sourceBalanceSompi = nil
                guard let address = source.address else { return }
                // A failed read stays unknown: shown as 0 it said the address was empty and
                // blocked every amount as "more than the address holds".
                guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses([address]),
                      !Task.isCancelled else { return }
                sourceBalanceSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
            }
            .onChange(of: feeTier) { _ in
                customExtraFeeSompi = nil
                isEditingFee = false
                if usedMax { setMaxAmount() }
            }
            .onChange(of: customExtraFeeSompi) { _ in
                if usedMax { setMaxAmount() }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { code in
                    handleScannedQRCode(code)
                }
            }
            .sheet(isPresented: $showCoinControl) {
                CoinControlView(fromAddress: isCompoundMode ? fromAddress : (source.address ?? fromAddress), initialSelection: manualUtxos) { selection in
                    manualUtxos = selection
                    if usedMax { setMaxAmount() }
                }
            }
            // The confirmation is the swipe-up's own full screen (SwipeUpToSendScrollView).
            .task(id: feeEstimationKey) {
                guard hasValidRecipient, let amountSompi else {
                    normalFeeSompi = nil
                    builtFeeSompi = nil
                    feeError = nil
                    isEstimatingFee = false
                    return
                }
                isEstimatingFee = true
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                let index = source.spendingIndex
                let recipient = effectiveAddress
                let coins = manualUtxos
                func estimate(extra: UInt64) async throws -> SendFeeEstimate {
                    if let index {
                        return try await chatService.estimateSpendingAddressWithdrawalFee(index: index, toAddress: recipient, amountSompi: amountSompi, manualUtxos: coins, extraFeeSompi: extra)
                    }
                    return try await chatService.estimateWithdrawalFee(toAddress: recipient, amountSompi: amountSompi, manualUtxos: coins, extraFeeSompi: extra)
                }
                do {
                    // The Normal fee is the base the speeds multiply (and the editor's minimum).
                    let base = try await estimate(extra: 0)
                    guard !Task.isCancelled else { return }
                    let extra = customExtraFeeSompi ?? base.networkFee * (feeTier.multiplier - 1)
                    // With the extra in, the estimate builds the same shape the send will: its
                    // network fee already holds the extra, and change too small to keep goes on top.
                    var paid = base
                    if extra > 0 { paid = try await estimate(extra: extra) }
                    guard !Task.isCancelled else { return }
                    normalFeeSompi = base.networkFee
                    builtFeeSompi = paid.networkFee + paid.foldedChange
                    feeError = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    normalFeeSompi = nil
                    builtFeeSompi = nil
                    feeError = UserFacingError.message(for: error)
                }
                isEstimatingFee = false
            }
            .task {
                if let lockedSource, source != lockedSource {
                    source = lockedSource
                }
                if isCompoundMode {
                    addressInput = fromAddress
                    isValidAddress = true
                    setMaxAmount()
                } else if let prefillAddress, addressInput.isEmpty {
                    addressInput = prefillAddress
                }
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: Step 1 - To

    private var recipientStep: some View {
        SendStepScreen(title: Text(LocalizedStringKey(screenTitle)), onCancel: { dismiss() },
                       canContinue: hasValidRecipient) {
            go(to: afterRecipient)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SendStepQuestion(text: "Who are you sending to?")
                    SendRecipientCard(
                        input: $addressInput,
                        isResolving: isResolvingKNS,
                        resolvedAddress: resolvedAddress,
                        resolvedName: resolvedDomain,
                        lookupError: knsError,
                        isValidAddress: isValidAddress,
                        onScan: { showQRScanner = true },
                        nameResolutions: nameResolutions,
                        selectedTLD: selectedTLD,
                        onSelectResolution: selectResolution,
                        focusOnAppear: true
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: Step 3 - Amount

    private var amountStep: some View {
        SendStepScreen(title: Text(LocalizedStringKey(screenTitle)),
                       onBack: backStep(from: .amount).map { back in { go(to: back) } },
                       onCancel: { dismiss() }, continueTitle: "Review",
                       canContinue: canContinueFromAmount) {
            go(to: .review)
        } content: {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    recipientChip
                    fromChip
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)

                KaspaKeypadAmountEntry(
                    fiatAmountState: fiatAmountState,
                    onAmountChange: { amountInput = $0 },
                    isEstimatingMax: isEstimatingMax,
                    maxEnabled: hasValidRecipient,
                    footnote: amountFootnote,
                    footnoteIsError: exceedsBalance || errorMessage != nil,
                    onMax: setMaxAmount,
                    onKeyTyped: {
                        usedMax = false
                        maxCapped = false
                        errorMessage = nil
                    }
                )
            }
        }
    }

    /// Under the typed amount: what's wrong with it, else what's available.
    private var amountFootnote: String? {
        if let errorMessage { return errorMessage }
        if exceedsBalance { return AppLocalization.string("This is more than the address you're sending from holds.") }
        if usedMax && maxCapped { return maxCappedNote }
        guard let sourceBalanceSompi else { return nil }
        return KaspaUnit.label(String(format: AppLocalization.string("Available: %@ KAS"), locale: AppLocalization.locale, KaspaUnit.plain(sourceBalanceSompi)))
    }

    /// Why Max isn't the whole balance: one transaction spends at most
    /// `maxInputsPerTransaction` coins, and this address holds more.
    private var maxCappedNote: String {
        let limit = KasiaTransactionBuilder.maxInputsPerTransaction
        if isCompoundMode {
            return String(format: AppLocalization.string("One transaction can combine %d coins, so this combines the largest %d. Compound again for the rest."),
                          locale: AppLocalization.locale, limit, limit)
        }
        return String(format: AppLocalization.string("Max is what one transaction can carry: its largest %d coins. Compound UTXOs, under More, combines the rest."),
                      locale: AppLocalization.locale, limit)
    }

    // MARK: Step 2 - From

    /// "Where are you sending from?": the Chatting Address, or Choose an Address with your addresses
    /// listed right here (no sheet).
    private var fromStep: some View {
        SendStepScreen(title: Text(LocalizedStringKey(screenTitle)),
                       onBack: backStep(from: .from).map { back in { go(to: back) } },
                       onCancel: { dismiss() },
                       canContinue: !(choosingFrom && source == .chatting)) {
            go(to: .amount)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SendStepQuestion(text: "Where are you sending from?")
                    HStack(spacing: 10) {
                        SelectablePill(title: "Chatting Address", selected: !choosingFrom) {
                            choosingFrom = false
                            source = .chatting
                        }
                        SelectablePill(title: "Choose an Address", selected: choosingFrom) {
                            choosingFrom = true
                        }
                    }
                    if choosingFrom {
                        Text("Pick which of your addresses the Kaspa leaves from.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        OwnAddressList(selected: source == .chatting ? nil : source.address) { picked in
                            source = picked
                            // the chatting address picked from the list: back on its own pill
                            if picked == .chatting { choosingFrom = false }
                        }
                    } else if let address = source.address {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Chatting Address")
                                    .font(.subheadline.weight(.semibold))
                                Text(verbatim: "\(address.prefix(14))...\(address.suffix(6))")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if let sourceBalanceSompi {
                                Text(verbatim: "\(KaspaUnit.plain(sourceBalanceSompi)) \(KaspaUnit.symbol)")
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .padding(14)
                        .background(sendKaspaGlass(cornerRadius: 16))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
    }

    /// "From Chatting Address" (or the picked address), on the amount step.
    private var fromChip: some View {
        SendStepChip(label: "From", value: sourceTitle)
    }

    /// "To alice.kas" (or the address), so the amount step says where it is going.
    private var recipientChip: some View {
        SendStepChip(label: "To", value: resolvedDomain ?? effectiveAddress, isAddress: resolvedDomain == nil)
    }

    // MARK: Step 4 - Review

    private var reviewStep: some View {
        SwipeUpToSendScrollView(
            screenTitle: isCompoundMode ? "Compound UTXOs" : "Review",
            onCancel: { dismiss() },
            onBack: backStep(from: .review).map { back in { go(to: back) } },
            title: isCompoundMode ? "Swipe up to Consolidate" : "Swipe up to Send",
            isBusy: isSending,
            isEnabled: canSend,
            amountSompi: amountSompi,
            recipient: isCompoundMode ? nil : (resolvedDomain ?? effectiveAddress),
            sent: sentTransaction,
            failureMessage: errorMessage,
            onDone: {
                sentTransaction = nil
                dismiss()
                onComplete?()
            },
            action: send
        ) {
            VStack(spacing: 18) {
                reviewAmount
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 14) {
                    reviewRow("To") {
                        if isCompoundMode {
                            Text("This address (consolidating)")
                        } else {
                            VStack(alignment: .trailing, spacing: 2) {
                                if let name = resolvedDomain {
                                    Text(verbatim: name).fontWeight(.semibold)
                                }
                                Text(verbatim: effectiveAddress)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    Divider()
                    reviewRow("From") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(verbatim: sourceTitle).fontWeight(.semibold)
                            if let address = isCompoundMode ? fromAddress : source.address {
                                Text(verbatim: "\(address.prefix(14))...\(address.suffix(6))")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Divider()
                    reviewRow("Total") {
                        if let amountSompi, let totalFeeSompi {
                            Text(verbatim: "\(KaspaUnit.plain(amountSompi + totalFeeSompi)) \(KaspaUnit.symbol)")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        } else if isEstimatingFee || isEstimatingMax {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(verbatim: "—").foregroundColor(.secondary)
                        }
                    }
                }
                .font(.subheadline)
                .padding(14)
                .background(sendKaspaGlass(cornerRadius: 20))

                // The only things that can still change: the fee and the coins it spends.
                SendFeeControls(
                    feeTier: $feeTier,
                    isEditingFee: $isEditingFee,
                    customFeeText: $customFeeText,
                    isEstimatingFee: isEstimatingFee,
                    feeText: totalFeeSompi.map { "\(KaspaUnit.plain($0)) \(KaspaUnit.symbol)" },
                    onStartEditing: startEditingFee,
                    onCommit: commitCustomFee,
                    coinControlSummary: coinControlSummary(manualUtxos),
                    onCoinControl: { showCoinControl = true },
                    onEditFee: openFeeEditor
                )

                if let message = errorMessage ?? feeError {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                } else if usedMax && maxCapped {
                    Text(maxCappedNote)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Network fee (from the review)

    /// The fee editor: the whole fee typed on the keypad, Confirm back to the review.
    private var feeStep: some View {
        SendFeeEditorScreen(draft: $feeDraft, minimumSompi: normalFeeSompi,
                            onCancel: { go(to: .review) }) { typed in
            // never under the network's minimum
            guard let normalFeeSompi else { return }
            customExtraFeeSompi = typed > normalFeeSompi ? typed - normalFeeSompi : 0
            go(to: .review)
        }
    }

    private func openFeeEditor() {
        guard let totalFeeSompi else { return }
        feeDraft = KaspaUnit.plain(totalFeeSompi)
        go(to: .fee)
    }

    /// The amount being sent, big, with its value in your currency under it.
    private var reviewAmount: some View {
        VStack(spacing: 6) {
            Text(isCompoundMode ? "Consolidating" : "You're sending")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if let amountSompi {
                Text(verbatim: "\(KaspaUnit.plain(amountSompi)) \(KaspaUnit.symbol)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let price = priceStore.currentPriceUsd, price > 0 {
                    Text(verbatim: formatFiatAmount(Double(amountSompi) / 100_000_000.0 * price,
                                                    currency: priceStore.currentCurrency))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                ProgressView()
                    .frame(height: 48)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func reviewRow<Value: View>(_ label: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            value()
                .multilineTextAlignment(.trailing)
        }
    }

    private var sourceTitle: String {
        if isCompoundMode { return AppLocalization.string("This address") }
        switch source {
        case .chatting: return AppLocalization.string("Chatting Address")
        case .spending(_, _, let label): return label
        }
    }

    private func handleInputChange(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        resolvedAddress = nil
        resolvedDomain = nil
        knsError = nil
        isResolvingKNS = false
        nameResolutions = []
        selectedTLD = nil

        guard !trimmed.isEmpty else {
            isValidAddress = false
            return
        }

        if trimmed.hasPrefix("kaspa:") || trimmed.hasPrefix("kaspatest:") {
            // the other network's address is the same key on another chain: refused
            isValidAddress = KaspaAddress.isValidOnActiveNetwork(trimmed)
            return
        }

        if NameServicesClient.looksLikeName(trimmed) {
            isValidAddress = false
            resolveKNSDomain(trimmed)
        } else {
            isValidAddress = false
        }
    }

    /// Use one service's answer (the priority one, or a pick from "Other domains").
    private func selectResolution(_ resolution: NameResolution) {
        guard let address = resolution.address else { return }
        resolvedAddress = address
        resolvedDomain = resolution.display
        selectedTLD = resolution.tld
        knsError = nil
    }

    private func resolveKNSDomain(_ domain: String) {
        isResolvingKNS = true

        // On the main actor: the check below must read the field as it is now. Read from a
        // background task while typing fast, it could see an older value, take this lookup for a
        // stale one and stop - leaving "Looking up domain..." up for good.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)

            guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain ||
                  addressInput.trimmingCharacters(in: .whitespacesAndNewlines) + ".kas" == domain + ".kas" else {
                return
            }

            // Every name service, in priority: the ending typed, else .kachat only (the others wait under Other domains)
            // (see NameServicesClient). The resolved line names which one answered; the others
            // are offered under "Other domains".
            let results = await NameServicesClient.shared.resolveEverywhere(domain)
            await MainActor.run {
                guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain else { return }
                nameResolutions = results
                isResolvingKNS = false
                if let resolution = NameServicesClient.primary(of: results, typed: domain), resolution.address != nil {
                    selectResolution(resolution)
                } else {
                    resolvedAddress = nil
                    resolvedDomain = nil
                    selectedTLD = nil
                    knsError = NameServicesClient.notFoundMessage(typed: domain, results: results)
                }
            }
        }
    }

    private func handleScannedQRCode(_ code: String) {
        var address = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.lowercased().hasPrefix("kaspa:") || address.lowercased().hasPrefix("kaspatest:") {
            if let queryIndex = address.firstIndex(of: "?") {
                address = String(address[..<queryIndex])
            }
        }
        addressInput = address
        handleInputChange(address)
    }

    private func setMaxAmount() {
        guard hasValidRecipient else { return }
        usedMax = true
        isEstimatingMax = true
        errorMessage = nil
        let recipient = effectiveAddress
        let tipSompi = extraFeeSompi
        let spendingIndex = isCompoundMode ? nil : source.spendingIndex
        let request = UUID()
        maxRequest = request
        Task {
            do {
                let result: (amountSompi: UInt64, cappedAtInputLimit: Bool)
                if let index = spendingIndex {
                    result = try await chatService.estimateMaxSpendingAddressAmount(index: index, toAddress: recipient, manualUtxos: manualUtxos, extraFeeSompi: tipSompi)
                } else {
                    result = try await chatService.estimateMaxWithdrawalAmount(toAddress: recipient, manualUtxos: manualUtxos, extraFeeSompi: tipSompi)
                }
                await MainActor.run {
                    // a newer Max (another speed tapped meanwhile) decides the amount
                    guard maxRequest == request else { return }
                    amountInput = fiatAmountState.setMaxKas(Double(result.amountSompi) / 100_000_000.0, priceInCurrency: priceStore.currentPriceUsd)
                    maxCapped = result.cappedAtInputLimit
                    isEstimatingMax = false
                }
            } catch {
                await MainActor.run {
                    guard maxRequest == request else { return }
                    errorMessage = UserFacingError.message(for: error)
                    maxCapped = false
                    isEstimatingMax = false
                }
            }
        }
    }

    private func startEditingFee() {
        guard let totalFeeSompi else { return }
        customFeeText = KaspaUnit.plain(totalFeeSompi)
        isEditingFee = true
    }

    /// Commits the manually-typed total fee. Values below the network-computed minimum are
    /// clamped up to that minimum rather than rejected outright — a transaction can't
    /// actually be submitted under the minimum, so silently flooring it is friendlier than
    /// an error for a value the user almost certainly meant as "as low as possible."
    private func commitCustomFee() {
        defer { isEditingFee = false }
        guard let normalFeeSompi, let totalSompi = KaspaUnit.sompi(fromUserText: customFeeText) else { return }
        customExtraFeeSompi = totalSompi > normalFeeSompi ? totalSompi - normalFeeSompi : 0
    }

    private func send() {
        // one send at a time: a second swipe or activation must never build a second transaction
        guard let amountSompi, !isSending else { return }
        isSending = true
        errorMessage = nil
        let recipient = effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let tipSompi = extraFeeSompi
        let spendingIndex = source.spendingIndex
        Task {
            do {
                try await SendFailureSimulation.failIfEnabled()
                let txId: String
                if let spendingIndex {
                    txId = try await chatService.sendFromSpendingAddress(index: spendingIndex, toAddress: recipient, amountSompi: amountSompi, manualUtxos: manualUtxos, extraFeeSompi: tipSompi)
                } else {
                    txId = try await chatService.sendWithdrawal(toAddress: recipient, amountSompi: amountSompi, manualUtxos: manualUtxos, extraFeeSompi: tipSompi)
                }
                await MainActor.run {
                    isSending = false
                    sentTransaction = SentTransaction(
                        txId: txId,
                        amountSompi: amountSompi,
                        // The domain when one was resolved, otherwise the address itself.
                        recipient: resolvedDomain ?? recipient
                    )
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMessage = UserFacingError.message(for: error)
                }
            }
        }
    }
}

private enum ProfileQRCodeCache {
    static let context = CIContext()
    static let imageCache = NSCache<NSString, UIImage>()
    static let renderQueue = DispatchQueue(label: "kasia.profile.qr.render", qos: .utility)

    static func cachedImage(for address: String) -> UIImage? {
        let uri = receiveURI(for: address)
        let key = uri as NSString
        return imageCache.object(forKey: key)
    }

    static func preload(address: String, completion: ((UIImage?) -> Void)?) {
        let uri = receiveURI(for: address)
        let key = uri as NSString

        if let cached = imageCache.object(forKey: key) {
            guard let completion else { return }
            DispatchQueue.main.async {
                completion(cached)
            }
            return
        }

        renderQueue.async {
            let image = generateImage(uri: uri)
            if let image {
                imageCache.setObject(image, forKey: key)
            }
            guard let completion else { return }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private static func generateImage(uri: String) -> UIImage? {
        let data = Data(uri.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func receiveURI(for address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("kaspa:") {
            return trimmed
        }
        return "kaspa:\(trimmed)"
    }
}

/// Coin control — lets the user fix the exact UTXO set a send spends from instead of the
/// automatic largest-first selector. Reachable from a send form's "Coin Control" row - shared by
/// `ColdSendFlowView` and `SpendingAddressWithdrawView` (not Cold-Storage-specific: it fetches
/// via the generic `NodePoolService.shared.getUtxosByAddresses`, keyed only by `fromAddress`).
/// Passes the selection back as a plain `[UTXO]?` (nil = automatic) rather than owning any state
/// itself, since the actual spendable set needs re-resolving against a fresh fetch at build time
/// anyway (see `ColdStorageSendEngine.buildUnsignedTransaction`'s `manualUtxos` handling).
struct CoinControlView: View {
    let fromAddress: String
    let initialSelection: [UTXO]?
    let onDone: ([UTXO]?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var utxos: [UTXO] = []
    @State private var selectedKeys: Set<String> = []
    @State private var isLoading = false
    /// The node could not be asked. Shown in place of "no coins": an outage must never read as
    /// an empty address when the coins here are about to be spent.
    @State private var loadError: String?
    @State private var utxoLabels: [String: String] = [:]

    private func loadUtxos() async {
        isLoading = true
        do {
            utxos = try await NodePoolService.shared.getUtxosByAddresses([fromAddress])
            loadError = nil
        } catch {
            loadError = UserFacingError.message(for: error)
        }
        isLoading = false
    }

    private func key(_ utxo: UTXO) -> String {
        "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)"
    }

    private var selectedTotalSompi: UInt64 {
        utxos.filter { selectedKeys.contains(key($0)) }.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading && utxos.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if utxos.isEmpty {
                    if let loadError {
                        UtxoLoadFailureRow(detail: loadError) {
                            Task { await loadUtxos() }
                        }
                    } else {
                        Text("No UTXOs found at this address.")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section {
                        ForEach(Array(utxos.enumerated()), id: \.offset) { _, utxo in
                            let k = key(utxo)
                            let isSelected = selectedKeys.contains(k)
                            Button {
                                if isSelected {
                                    selectedKeys.remove(k)
                                } else {
                                    selectedKeys.insert(k)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(isSelected ? .accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        if let label = utxoLabels[k], !label.isEmpty {
                                            Text(label)
                                                .font(.caption)
                                                .fontWeight(.bold)
                                                .foregroundColor(.accentColor)
                                        }
                                        Text(verbatim: "\(formatKas(utxo.amount)) \(KaspaUnit.symbol)")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                        Text("\(utxo.outpoint.transactionId.prefix(10))...:\(utxo.outpoint.index)")
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        if !selectedKeys.isEmpty {
                            Text(verbatim: "Selected: \(formatKas(selectedTotalSompi)) \(KaspaUnit.symbol) (\(selectedKeys.count) UTXO\(selectedKeys.count == 1 ? "" : "s"))")
                        }
                    }
                }
            }
            .navigationTitle("Coin Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Select All") { selectedKeys = Set(utxos.map(key)) }
                        Button("Automatic (Clear Selection)") { selectedKeys.removeAll() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    let selected = utxos.filter { selectedKeys.contains(key($0)) }
                    onDone(selected.isEmpty ? nil : selected)
                    dismiss()
                } label: {
                    Text(selectedKeys.isEmpty ? "Use Automatic Selection" : "Confirm Selection")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .task {
                utxoLabels = WalletManager.shared.loadSpendingUtxoLabels(address: fromAddress)
                await loadUtxos()
                if let initialSelection {
                    selectedKeys = Set(initialSelection.map(key))
                }
            }
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
    }
}
