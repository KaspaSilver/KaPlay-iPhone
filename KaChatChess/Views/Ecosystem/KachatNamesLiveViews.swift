import SwiftUI
import UIKit

// The live `.kachat` screens, display only (owner's call, 2026-11-18: claiming, renewing, selling,
// transferring and offers are KaPay's): the bell's name route and the unshown full wallet's
// Your Domains > .kachat.

// MARK: - Shared pieces

enum KachatLive {
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    /// A unix-ms day as a row value ("Oct 12, 2027"), in the in-app language, with the time when
    /// it is within two days (testnet's 24-hour periods).
    static func day(_ ms: Int64) -> String {
        let near = abs(ms - KachatNames.nowMs()) < 2 * 86_400_000
        return date(ms).formatted(Date.FormatStyle(date: .abbreviated, time: near ? .shortened : .omitted).locale(AppLocalization.locale))
    }
}

/// The app's glass card (`.regularMaterial`, hairline, soft shadow).
struct KachatGlass: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 4)
        )
    }
}

extension View {
    func kachatGlass(cornerRadius: CGFloat = 16) -> some View { modifier(KachatGlass(cornerRadius: cornerRadius)) }
}

// MARK: - Your Domains > .kachat

/// What .kachat names are, what they cost and how to claim one: the page on home.kachat.app that
/// "Get a .kachat name" (Edit Profile) and "Get a .kachat domain" (Your Domains) open, the same as
/// KaChat. Names are claimed in KaPay only, never in KaPlay (owner's call, 2026-11-18).
enum KachatNamesInfo {
    static let pageURL = URL(string: "https://home.kachat.app/kachat/")!
}

struct KachatLiveDomainsTab: View {
    let walletAddress: String
    @ObservedObject private var registry = KachatNamesRegistry.shared
    @ObservedObject private var service = KachatNamesService.shared
    @State private var names: [KachatNames.NameInfo] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if !loaded {
                    ProgressView().padding(.vertical, 24)
                } else if service.registryUpgrading {
                    // the bundled manifest is for the previous registry: calm, no error
                    VStack(spacing: 10) {
                        Image(systemName: "hammer")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundColor(.accentColor)
                        Text("Setting up")
                            .font(.headline)
                        Text("The .kachat registry is being upgraded. Names open here again once the new registry is live.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    if names.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "at.circle")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundColor(.accentColor)
                            Text("No .kachat names yet")
                                .font(.headline)
                            Text("Claim a name in KaPay with this account, and it shows up here.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        // Display only, like KaChat: renewing, selling, transferring and offers
                        // are KaPay's (owner's call, 2026-11-18).
                        ForEach(names) { n in
                            DomainNameCardView(title: n.display, badge: Self.badge(for: n, graceMs: registry.graceMs),
                                               footnote: Self.expiryLine(for: n, graceMs: registry.graceMs))
                        }
                    }
                }
            }
            .padding()
        }
        .refreshable { await registry.refresh() }
        .safeAreaInset(edge: .bottom) {
            if loaded && !service.registryUpgrading {
                getDomainButton
            }
        }
        .task(id: registry.revision) {
            showCachedIfNeeded()
            await load()
            // a name that lapses while this is open leaves right then
            await registry.dropLapsed(from: names) { names = $0 }
        }
    }

    /// The same as KaChat's: opens the .kachat names page (`KachatNamesInfo.pageURL`). Names are
    /// claimed in KaPay, not here.
    private var getDomainButton: some View {
        Button {
            Haptics.impact(.light)
            UIApplication.shared.open(KachatNamesInfo.pageURL)
        } label: {
            Text("Get a .kachat domain")
                .font(.headline)
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// The card badge for a name: Listed, or Expired (in grace). Shared with the per-address
    /// lists (`KachatAddressLiveNamesList`); neither lists lapsed names (`heldNames`).
    /// The card's bottom-right corner: when the name expires - or, once it has, when its grace
    /// period ends (renew before then to keep it).
    static func expiryLine(for n: KachatNames.NameInfo, graceMs: Int64) -> String? {
        switch n.status(graceMs: graceMs) {
        case .active: return String(format: AppLocalization.string("Expires %@"), KachatLive.day(n.expiresAt))
        case .grace: return String(format: AppLocalization.string("Grace ends %@"), KachatLive.day(n.expiresAt + graceMs))
        case .lapsed: return nil
        }
    }

    static func badge(for n: KachatNames.NameInfo, graceMs: Int64) -> String? {
        switch n.status(graceMs: graceMs) {
        case .active: return n.isListed ? AppLocalization.string("Listed") : nil
        case .grace: return AppLocalization.string("Expired")
        case .lapsed: return AppLocalization.string("Available")
        }
    }

    /// The names this wallet had last time, straight away - they rarely change. `load()` then
    /// checks the registry and replaces them when it answers (`KachatOwnedNamesCache`).
    private func showCachedIfNeeded() {
        guard !loaded, let cached = KachatOwnedNamesCache.load(walletAddress) else { return }
        let grace = registry.graceMs
        names = cached.names.filter { $0.status(graceMs: grace) != .lapsed }
        loaded = true
    }

    private func load() async {
        guard let key = KachatNamesRegistry.keyOf(walletAddress) else { loaded = true; return }
        if registry.refreshedAt == nil { await registry.refresh() }
        // A lapsed name is no longer yours (the bell says so, `KachatNamesNotifier`). Expired
        // names in grace stay, to be renewed in KaPay.
        // Your own list (the chatting address's) holds the names on every address of this
        // wallet, on any device restored from the seed. Offers are KaPay's, so none are read.
        // Only an answer replaces what is shown (and the saved copy); a failed read keeps it.
        if walletAddress.lowercased() == KachatNamesActions.shared.myAddress {
            if let own = try? await KachatNamesActions.shared.ownNames() {
                names = own
                KachatOwnedNamesCache.save(names: names, offers: [], for: walletAddress)
            }
        } else if let held = try? await registry.heldNames(owner: key) {
            names = held
            KachatOwnedNamesCache.save(names: names, offers: [], for: walletAddress)
        }
        loaded = true
    }
}

// MARK: - Opening a name from a notification

/// Where a tapped `.kachat` name notification lands. Kept until the `.kachat` screen is on
/// screen to take it, so a cold start from the notification still opens the name.
@MainActor
enum KachatDeepLink {
    static var pendingName: String?
}

/// This wallet's .kachat names that have expired and sit in their grace period, for Profile's
/// banner (`KachatExpiredNamesBanner`): renew before grace ends, or anyone can claim them. A
/// dismissal (the X) is per name and expiry, so a name that expires again brings it back.
@MainActor
final class KachatExpiredNamesModel: ObservableObject {
    @Published private(set) var expired: [KachatNames.NameInfo] = []
    @Published private var dismissed: Set<String> = []

    var visible: [KachatNames.NameInfo] { expired.filter { !dismissed.contains(Self.key($0)) } }

    private static func key(_ n: KachatNames.NameInfo) -> String { "\(n.name)@\(n.expiresAt)" }
    private var storeKey: String? { KachatNamesActions.shared.myAddress.map { "kachatExpiredBannerDismissed.\($0)" } }

    func load() async {
        guard KachatNamesService.isLaunched, let me = KachatNamesActions.shared.myKey, let storeKey else {
            expired = []
            return
        }
        let stored = Set(UserDefaults.standard.stringArray(forKey: storeKey) ?? [])
        if stored != dismissed { dismissed = stored }
        let registry = KachatNamesRegistry.shared
        // Profile's own loads use five minutes too: a shorter window here refreshed in between
        // and restarted every task on the Profile screen keyed on the registry's revision.
        await registry.refreshIfStale(maxAge: 300)
        let grace = registry.graceMs
        let now = KachatNames.nowMs()
        // a failed read keeps the banner as it is
        guard let owned = try? await registry.names(owner: me, includeInactive: true) else { return }
        let inGrace = owned.filter { $0.status(graceMs: grace, nowMs: now) == .grace }.sorted { $0.expiresAt < $1.expiresAt }
        // assigned only on a change: each assignment redraws the whole Profile scroll
        if inGrace != expired { expired = inGrace }
    }

    func dismissAll() {
        guard let storeKey else { return }
        dismissed.formUnion(visible.map(Self.key))
        // only names still in grace are worth remembering
        UserDefaults.standard.set(Array(dismissed.intersection(Set(expired.map(Self.key)))), forKey: storeKey)
    }
}

/// Profile's banner while one of this wallet's .kachat names is in its grace period. Tapping it
/// opens the name, display only (renewing is in KaPay); the X hides it.
struct KachatExpiredNamesBanner: View {
    @ObservedObject var model: KachatExpiredNamesModel
    @ObservedObject private var registry = KachatNamesRegistry.shared

    var body: some View {
        let visible = model.visible
        if let n = visible.first {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(visible.count == 1
                         ? AppLocalization.string("One of your .kachat domains expired")
                         : String(format: AppLocalization.string("%lld of your .kachat domains expired"), visible.count))
                        .font(.subheadline.weight(.semibold))
                    Text(visible.count == 1
                         ? String(format: AppLocalization.string("Renew %@ before its grace period ends on %@ to keep it."),
                                  KachatNameLabel.display(n.name), KachatNamesActions.dayString(n.expiresAt + registry.graceMs))
                         : AppLocalization.string("Renew them before their grace periods end to keep them."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { open(n) }
                Button {
                    withAnimation { model.dismissAll() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.35), lineWidth: 1))
        }
    }

    private func open(_ n: KachatNames.NameInfo) {
        KachatDeepLink.pendingName = n.name
        NotificationCenter.default.post(name: .openKachatName, object: nil)
    }
}

/// A name to open, by name: the destination looks it up itself.
struct KachatNameRoute: Hashable, Identifiable {
    let name: String
    var id: String { name }
}

/// The name a bell row or the expired-names banner pointed at, display only (owner's call,
/// 2026-11-18): its card and when it expires, with renewing, selling and transferring left to
/// KaPay - or, when it was released or reclaimed since, the name as free, with "Get a .kachat
/// domain".
struct KachatNameRouteView: View {
    let name: String

    private enum Found {
        case registered(KachatNames.NameInfo)
        case free(KachatNames.GapInfo?)
        case failed
    }

    @State private var found: Found?
    @ObservedObject private var registry = KachatNamesRegistry.shared

    var body: some View {
        Group {
            switch found {
            case .registered(let info):
                registeredName(info)
            case .free:
                freeName
            case .failed:
                VStack(spacing: 12) {
                    Text(verbatim: KachatNameLabel.display(name)).font(.headline)
                    Text("Couldn't look that name up.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func registeredName(_ info: KachatNames.NameInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DomainNameCardView(title: info.display, badge: KachatLiveDomainsTab.badge(for: info, graceMs: registry.graceMs),
                                   footnote: KachatLiveDomainsTab.expiryLine(for: info, graceMs: registry.graceMs))
                Text("Renew, sell or transfer it in KaPay.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding()
        }
    }

    private var freeName: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(height: 110)
                        .overlay(
                            Text(verbatim: KachatNameLabel.display(name))
                                .font(.title2.weight(.heavy))
                                .foregroundColor(.black)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .padding(.horizontal, 16)
                        )
                    HStack {
                        Text("Free to claim").font(.subheadline).foregroundColor(.secondary)
                        Spacer()
                        Text("Available")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.green)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                    }
                }
                .padding(14)
                .kachatGlass()
                // claimed in KaPay only (owner's call, 2026-11-18)
                Button {
                    UIApplication.shared.open(KachatNamesInfo.pageURL)
                } label: {
                    Label("Get a .kachat domain", systemImage: "at").font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private func load() async {
        found = nil
        do {
            switch try await KachatNamesRegistry.shared.claimLookup(name) {
            case .registered(let info): found = .registered(info)
            case .free(_, let gap): found = .free(gap)
            }
        } catch {
            found = .failed
        }
    }
}

/// `navigationDestination(item:)` on iOS 17, the `isPresented:` form on iOS 16 (as KaChat's chat list
/// does - see ChatDetailNavigationDestination).
struct KachatNameRouteDestination: ViewModifier {
    @Binding var route: KachatNameRoute?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(item: $route) { KachatNameRouteView(name: $0.name) }
        } else {
            content.navigationDestination(isPresented: Binding(
                get: { route != nil },
                set: { if !$0 { route = nil } }
            )) {
                if let route { KachatNameRouteView(name: route.name) }
            }
        }
    }
}
