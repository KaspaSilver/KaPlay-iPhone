import SwiftUI
import UIKit

// KaPay's .kachat pieces that Your Domains and an address's Domains tab open (from KaPay's
// KachatMarketView.swift, without the marketplace tab itself, which KaPlay doesn't have).

/// The ".kachat" wordmark as a template image, drawn the way `ChessTabIcon` draws the chess
/// pieces, tinted like any SF Symbol.
enum KachatTabIcon {
    private static var cache: [String: UIImage] = [:]

    /// A template image `side` points tall; the word is wider than it is tall. `fontScale` is the
    /// word's size as a share of `side` - the dock passes a smaller one, so the item is no wider
    /// than the tabs beside it.
    static func image(side: CGFloat, fontScale: CGFloat = 0.62) -> UIImage {
        let key = "\(Int(side.rounded()))-\(Int((fontScale * 100).rounded()))"
        if let cached = cache[key] { return cached }
        let font = UIFont.systemFont(ofSize: side * fontScale, weight: .heavy)
        let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
        let text = NSAttributedString(string: ".kachat", attributes: [.font: rounded, .foregroundColor: UIColor.black])
        let measured = text.size()
        let width = max(measured.width, side)
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: width, height: side)).image { _ in
            text.draw(at: CGPoint(x: (width - measured.width) / 2, y: (side - measured.height) / 2))
        }
        let template = rendered.withRenderingMode(.alwaysTemplate)
        cache[key] = template
        return template
    }

    static func view(side: CGFloat) -> some View {
        Image(uiImage: image(side: side))
            .renderingMode(.template)
            .foregroundStyle(Color.accentColor)
    }
}

// MARK: - An address's .kachat names

/// The ".kachat" tab of every screen that shows an address's history - Manage Addresses,
/// Cold Storage and the chatting address: the .kachat names that address holds. It replaced the
/// KNS Domains tab (5.2), and is empty until .kachat names launch.
/// The Domains tab of an address screen (the chatting address, a spending address, a KasSigner
/// address): one card per name service - .kachat, .k, .kaspa, .kas - each with how many names
/// this address holds there; tap one to see them. Every service is asked at once, for this
/// address only (Your Domains' own lists are left alone).
struct AddressDomainsTab: View {
    let address: String

    /// nil while that service's answer is on the way; a failed lookup is `failed`.
    @State private var counts: [NameServiceTLD: Int] = [:]
    @State private var names: [NameServiceTLD: [String]] = [:]
    @State private var failed: Set<NameServiceTLD> = []

    /// The order the cards are listed in.
    static let order: [NameServiceTLD] = [.kachat, .k, .kaspa, .kas]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Self.order, id: \.self) { tld in
                    NavigationLink {
                        destination(tld)
                    } label: {
                        card(tld)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .refreshable { await load() }
        .task(id: address) { await load() }
    }

    private func card(_ tld: NameServiceTLD) -> some View {
        HStack(spacing: 14) {
            // the same globe on every card: the suffix beside it says which service it is
            Image(systemName: "globe")
                .font(.scaled(size: 22, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 48, height: 48)
            .background(Circle().fill(Color.accentColor.opacity(0.15)))

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: tld.suffix)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(verbatim: tld.serviceName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            countLabel(tld)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func countLabel(_ tld: NameServiceTLD) -> some View {
        if let count = counts[tld] {
            Text(verbatim: "\(count)")
                .font(.subheadline.weight(.bold))
                .foregroundColor(count > 0 ? .black : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(count > 0 ? Color.accentColor : Color.secondary.opacity(0.15)))
                .accessibilityLabel(Text(count == 1 ? "1 domain" : "\(count) domains"))
        } else if failed.contains(tld) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
                .accessibilityLabel(Text("Couldn't load"))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func destination(_ tld: NameServiceTLD) -> some View {
        if tld == .kachat {
            // the .kachat cards and their detail screens, as before
            KachatAddressDomainsList(address: address)
                .navigationTitle(".kachat")
                .navigationBarTitleDisplayMode(.inline)
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    let list = names[tld] ?? []
                    if list.isEmpty {
                        Text(failed.contains(tld)
                             ? "Couldn't reach \(tld.serviceName). Pull down to try again."
                             : "No \(tld.suffix) names on this address.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(list, id: \.self) { name in
                            DomainNameCardView(title: name)
                        }
                    }
                }
                .padding()
            }
            .refreshable { await load() }
            .navigationTitle(Text(verbatim: tld.suffix))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Every service at once, for this address.
    private func load() async {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let network = AppSettings.load().networkType
        async let kachat = NameServicesClient.shared.kachatNames(of: [address])
        async let services = NameServicesClient.shared.ownedNamesByService(of: address)
        async let kns = KNSService.shared.fetchInfo(for: address, network: network)

        // nil: the names couldn't be read - "Couldn't load", never "0"
        if let kachatNames = (await kachat)[address] {
            set(.kachat, kachatNames.map(\.display))
        } else {
            markFailed(.kachat)
        }

        let byService = await services
        for tld in [NameServiceTLD.k, .kaspa] {
            if let list = byService[tld] { set(tld, list.map(\.display)) } else { markFailed(tld) }
        }

        if let info = await kns {
            set(.kas, info.allDomains.map(\.fullName))
        } else {
            markFailed(.kas)
        }
    }

    private func set(_ tld: NameServiceTLD, _ list: [String]) {
        names[tld] = list
        counts[tld] = list.count
        failed.remove(tld)
    }

    /// A lookup that failed drops what an earlier one found, so the card shows the failure
    /// rather than an old count.
    private func markFailed(_ tld: NameServiceTLD) {
        names[tld] = nil
        counts[tld] = nil
        failed.insert(tld)
    }
}

struct KachatAddressDomainsList: View {
    /// The address whose names to show. On testnet (live registry) the list is that address's
    /// own .kachat names; nil, or mainnet, shows the "coming" note.
    var address: String? = nil

    var body: some View {
        if let address, KachatNamesService.isEnabled {
            KachatAddressLiveNamesList(address: address)
        } else {
            comingNote
        }
    }

    private var comingNote: some View {
        List {
            VStack(spacing: 10) {
                KachatTabIcon.view(side: 40)
                Text("No .kachat names on this address")
                    .font(.headline)
                Text("Names this address claims or buys show here once .kachat names launch.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
    }
}

/// One address's .kachat names on testnet - Manage Addresses (spending), the chatting address and
/// KasSigner each show their own address's names in its .kachat tab. The same cards as Your
/// Domains > .kachat, display only: names are managed in KaPay.
struct KachatAddressLiveNamesList: View {
    let address: String
    @ObservedObject private var registry = KachatNamesRegistry.shared
    @ObservedObject private var service = KachatNamesService.shared
    @State private var names: [KachatNames.NameInfo] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if !loaded {
                    ProgressView().padding(.vertical, 24)
                } else if service.registryUpgrading || names.isEmpty {
                    VStack(spacing: 10) {
                        KachatTabIcon.view(side: 40)
                        Text("No .kachat names on this address")
                            .font(.headline)
                        Text("Names this address owns show here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    // display only: names are managed in KaPay (owner's call, 2026-11-18)
                    ForEach(names) { n in
                        DomainNameCardView(title: n.display, badge: KachatLiveDomainsTab.badge(for: n, graceMs: registry.graceMs))
                    }
                }
            }
            .padding()
        }
        .refreshable { await registry.refresh() }
        .task(id: "\(address)|\(registry.revision)") { await load() }
    }

    private func load() async {
        guard let key = KachatNamesRegistry.keyOf(address) else { loaded = true; return }
        if registry.refreshedAt == nil { await registry.refresh() }
        // an expired name past grace isn't theirs any more: it's available to anyone
        // a failed read keeps what's on screen: it isn't "holds no names"
        if let held = try? await registry.heldNames(owner: key) { names = held }
        loaded = true
    }
}
