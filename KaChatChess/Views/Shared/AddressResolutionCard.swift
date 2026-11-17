import SwiftUI

/// Who is behind the address a screen has resolved - the card the create-chat screen shows,
/// for every other place an address or a domain goes in (withdrawals, sends from an address,
/// the portfolio, a group invite). The SCREEN does the resolving (.kachat first, see
/// `NameServicesClient.resolveEverywhere`); this card takes the outcome and shows the face and
/// the name: the domain that was typed, else the address's own .kachat name. Nil address, no card - a half-typed
/// address gets nothing rather than a card flickering through wrong faces.
///
/// Every screen with this card moves money, so the address's own .kachat name is never the
/// cache's (any age, the indexer's word): it shows only once a lookup made for this card finds
/// the name's owner on chain is this address (`KachatNamesRegistry.verifiedLabel`). Until then,
/// or when that can't be checked, no .kachat name.
struct AddressResolutionCard: View {
    /// The address the input stands for: a valid typed address, or a domain's resolved owner.
    let address: String?
    /// The domain that resolved to it, when the user typed one (shown at once, before the
    /// profile fetch lands).
    var domain: String? = nil

    @State private var profile: KNSAddressProfileInfo?
    @State private var isLoadingProfile = false
    /// The address's .kachat name once checked on chain for this address, keyed by the address
    /// it was checked for so a newer address never shows the previous one's name.
    @State private var verifiedKachat: (address: String, label: String)?
    @State private var isVerifyingName = false

    /// The name to show: the domain typed, else the address's .kachat name checked on chain.
    private func displayName(for address: String) -> String? {
        if let domain { return domain }
        if let verifiedKachat, verifiedKachat.address == address { return KachatNameLabel.display(verifiedKachat.label) }
        return profile?.domainName
    }

    private var isLooking: Bool { isLoadingProfile || isVerifyingName }

    var body: some View {
        if let address, !address.isEmpty {
            HStack(spacing: 12) {
                KNSAvatarView(
                    avatarURLString: profile?.avatarURL,
                    fallbackText: displayName(for: address) ?? address,
                    size: 44,
                    contactAddress: address
                )
                VStack(alignment: .leading, spacing: 2) {
                    let name = displayName(for: address)
                    Text(name ?? (isLooking ? AppLocalization.string("Looking up...") : AppLocalization.string("No domain")))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(name == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Text(address)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // one of this wallet's own addresses: you are sending to yourself
                    if let own = WalletManager.shared.ownAddressLabel(for: address) {
                        Label(String(format: AppLocalization.string("Your own address: %@"), own),
                              systemImage: "person.crop.circle.badge.checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isLooking { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .task(id: address) { await loadProfile(for: address) }
            .task(id: address) { await verifyKachatName(for: address) }
        }
    }

    /// Asks the registry for the address's .kachat name and checks it on chain; nothing is shown
    /// from the cache meanwhile.
    private func verifyKachatName(for address: String) async {
        verifiedKachat = nil
        isVerifyingName = false
        guard domain == nil, KaspaAddress.isValid(address) else { return }
        isVerifyingName = true
        defer { if address == self.address { isVerifyingName = false } }
        let label = await KachatNamesRegistry.shared.verifiedLabel(for: address)
        guard !Task.isCancelled, address == self.address, let label else { return }
        verifiedKachat = (address, label)
    }

    /// Cached by KNSService, so an address already looked at costs nothing.
    /// A new address starts clean - never the previous one's avatar or name while it loads - and
    /// the spinner always stops, a cancelled lookup included (IOS-074).
    private func loadProfile(for address: String) async {
        profile = nil
        isLoadingProfile = false
        guard KaspaAddress.isValid(address) else { return }
        if let cached = KNSService.shared.profileCache[address] {
            profile = cached
            return
        }
        isLoadingProfile = true
        // a lookup for an address the card no longer shows leaves the newer one's spinner alone
        defer { if address == self.address { isLoadingProfile = false } }
        let fetched = await KNSService.shared.fetchProfile(for: address)
        guard !Task.isCancelled, address == self.address else { return }
        profile = fetched
    }
}
