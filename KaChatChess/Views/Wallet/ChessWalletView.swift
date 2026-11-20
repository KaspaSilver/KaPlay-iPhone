import SwiftUI

/// The Wallet tab: the chatting address only (owner's call, 2026-11-19). Its balance, Receive and
/// Send at the bottom, and its history - `ChattingAddressManageView` in its Wallet-tab mode, with
/// this tab's fixed title, connection dot, balance and bell. No spending addresses, Request,
/// Manage Addresses or Your Domains: those are KaPay's. The earlier full wallet is
/// `FullWalletView`, kept in WalletViews.swift but not shown.
struct ChessWalletView: View {
    @EnvironmentObject var walletManager: WalletManager

    /// The header's toast and Backup Hygiene sheet, shown over the whole tab.
    @StateObject private var tabActions = WalletTabActions()
    @State private var showNotifCenter = false
    @ObservedObject private var notifCenter = GlobalNotificationCenter.shared
    /// A bell row's address (`OwnAddressRoute`), its history over the tab.
    @State private var ownAddressSheet: OwnAddressSheetTarget?
    /// A bell row's .kachat name (`KachatDeepLink`), pushed here, display only.
    @State private var nameRoute: KachatNameRoute?
    /// When `onAppear` last refreshed the balance (at most every 30 s).
    @State private var appearRefreshedAt: Date?

    var body: some View {
        NavigationStack {
            Group {
                if let wallet = walletManager.currentWallet {
                    // a plain value (the address and a stable object), so a redraw of this tab
                    // doesn't rebuild the history list; the header observes what it shows itself
                    ChattingAddressManageView(address: wallet.publicAddress,
                                              walletHeader: ChessWalletHeader(address: wallet.publicAddress,
                                                                              actions: tabActions))
                        // a new account is a new address: its own history and coins
                        .id(wallet.publicAddress)
                } else {
                    Text("No active account")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // KaPlay's title, as on every tab: big and fixed above what scrolls, the backup
            // banner over it while one is owed.
            .fixedScreenTitle(Text("Wallet"), showsBackupBanner: true)
            .background(Color(.systemGroupedBackground))
            .modifier(KachatNameRouteDestination(route: $nameRoute))
            .navigationTitle("Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // One item per side (dot left, bell right), as on the other tabs.
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    BalanceToolbarLabel()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Kaspa received and .kachat name news; a plain red dot while unread.
                    Button {
                        showNotifCenter = true
                    } label: {
                        Image(systemName: "bell")
                            .padding(4)
                            .overlay(alignment: .topTrailing) {
                                if notifCenter.unreadCount > 0 {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                }
                            }
                    }
                    .accessibilityLabel(Text("Notifications"))
                }
            }
            .sheet(isPresented: $showNotifCenter) {
                GlobalNotificationListView()
            }
            // A tapped bell row: the address that got the Kaspa, or the .kachat name.
            .onReceive(NotificationCenter.default.publisher(for: .openOwnAddress)) { _ in
                guard let address = OwnAddressRoute.pending else { return }
                OwnAddressRoute.pending = nil
                ownAddressSheet = OwnAddressSheetTarget(address: address)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openKachatName)) { _ in
                guard let name = KachatDeepLink.pendingName else { return }
                KachatDeepLink.pendingName = nil
                nameRoute = KachatNameRoute(name: name)
            }
            .sheet(item: $ownAddressSheet) { target in
                OwnAddressHistorySheet(address: target.address)
            }
            .sheet(isPresented: $tabActions.showBackupHygiene) {
                BackupHygieneView()
            }
            .toast(message: tabActions.toastMessage)
            .onAppear {
                if let at = appearRefreshedAt, Date().timeIntervalSince(at) < 30 { return }
                appearRefreshedAt = Date()
                Task { _ = try? await walletManager.refreshBalance() }
            }
        }
    }
}

/// What the Wallet tab's header asks of the tab: a toast over the whole screen, and Backup Hygiene.
/// A stable object handed to the header, so the header stays an equal value across redraws.
@MainActor
final class WalletTabActions: ObservableObject {
    @Published var toastMessage: String?
    @Published var showBackupHygiene = false
    private var toastToken = UUID()

    func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.toastMessage = nil
        }
    }
}

/// Above the history: the chatting address's balance (tap to copy), a quiet line when the account's
/// other (spending) addresses hold coins, Backup Hygiene when due, and on testnet the faucet. Its
/// own view observing what it shows, so balance and price changes redraw only this.
struct ChessWalletHeader: View {
    let address: String
    let actions: WalletTabActions
    @ObservedObject private var walletManager = WalletManager.shared
    @ObservedObject private var backupStatus = AccountBackupStatus.shared
    @ObservedObject private var hotWallet = HotWalletBalance.shared

    private var wallet: Wallet? {
        guard let wallet = walletManager.currentWallet, wallet.publicAddress == address else { return nil }
        return wallet
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChattingBalanceCard(sompi: wallet?.balanceSompi) {
                actions.showToast(AppLocalization.string("Balance copied to clipboard."))
            }
            // KaPlay's Wallet tab is the chatting address only; coins elsewhere on the account
            // (from KaPay) are still the player's: said once, quietly, with where to manage them.
            if let spending = hotWallet.spendingSompi(for: wallet), spending > 0 {
                Text(verbatim: String(format: AppLocalization.string("%@ on your other addresses. Manage them in KaPay."),
                                      locale: AppLocalization.locale, KaspaUnit.groupedAmount(spending)))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            if backupStatus.isHygieneDue(address) {
                BackupHygieneCard { actions.showBackupHygiene = true }
            }
            // Testnet only: free TN10 coins for the chatting address, from the official faucet.
            if AppSettings.load().networkType == .testnet {
                TestnetFaucetClaimButton(address: address)
            }
        }
        // once per appearance (a read at most every 30 s), not per move
        .task { await HotWalletBalance.shared.refreshUntilKnown() }
    }
}

/// The chatting address's balance at the top of the Wallet tab, with its worth in your currency
/// on mainnet. Its own view so that price updates redraw only this card.
private struct ChattingBalanceCard: View {
    let sompi: UInt64?
    let onCopied: () -> Void
    @ObservedObject private var priceStore = KaspaPriceStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Chatting Address")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button {
                guard let sompi else { return }
                UIPasteboard.general.string = KaspaUnit.plain(sompi)
                Haptics.success()
                onCopied()
            } label: {
                Text(verbatim: sompi.map(KaspaUnit.amount) ?? "--")
                    .font(.largeTitle.weight(.bold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .buttonStyle(.plain)
            if let fiat = fiatText {
                Text(verbatim: fiat)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
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
        .onAppear { priceStore.refreshIfStale() }
    }

    /// Testnet coins aren't worth anything.
    private var fiatText: String? {
        guard let sompi, AppSettings.load().networkType == .mainnet,
              let price = priceStore.networkPriceUsd, price > 0 else { return nil }
        return formatFiatAmount(Double(sompi) / 100_000_000.0 * price, currency: priceStore.currentCurrency)
    }
}
