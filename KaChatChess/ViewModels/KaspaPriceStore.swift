import Foundation
import UIKit

/// The KAS price in the currency picked in Settings > Customization, for the Send screen's
/// KAS / your-currency switch. KaChat read this off its Portfolio (`PortfolioViewModel`); the
/// price part is all KaChat Chess needs, so it is all that came along: fetched from CoinGecko,
/// kept across launches, refetched when it is older than five minutes or the currency changes.
///
/// An amount typed in your currency is turned into KAS with this price, so an old one would send
/// the wrong KAS: `currentPriceUsd` is only a price fetched under 30 minutes ago
/// (`maxUsableAge`), nil otherwise (the KAS / currency switch then hides). The kept copy of any
/// age is `lastKnownPriceUsd`, for showing a value only, never for working out an amount. Send
/// screens call `refreshIfStale()` when they appear.
@MainActor
final class KaspaPriceStore: ObservableObject {
    static let shared = KaspaPriceStore()

    /// How old a price may be and still turn a typed currency amount into KAS.
    static let maxUsableAge: TimeInterval = 30 * 60
    /// A price this young isn't fetched again.
    private static let refetchAge: TimeInterval = 5 * 60

    /// KAS price in `currentCurrency` (the name is KaChat's, kept so the copied call sites read
    /// the same), fetched under `maxUsableAge` ago. Nil until the first price arrives, and again
    /// once the price on hand is older than that.
    var currentPriceUsd: Double? {
        guard let freshPrice, Self.isUsable(fetchedAt: priceFetchedAt) else { return nil }
        return freshPrice
    }

    /// The last price seen in `currentCurrency`, however old. Display only: never use it to work
    /// out an amount to send.
    @Published private(set) var lastKnownPriceUsd: Double?
    /// When `lastKnownPriceUsd` was fetched.
    private(set) var priceFetchedAt: Date?
    private(set) var currentCurrency: AppCurrency = SettingsViewModel.loadSettings().currency

    /// The price while it is usable; set to nil when it ages out, so screens showing the switch
    /// redraw without it.
    @Published private var freshPrice: Double?

    private let coinGecko = CoinGeckoService.shared
    private var fetchTask: Task<Void, Never>?
    /// Which fetch `fetchTask` is: an older, cancelled one finishing late must not clear a newer
    /// one's handle.
    private var fetchGeneration = 0
    private var expiryTask: Task<Void, Never>?
    private var settingsObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    private struct PersistedPrice: Codable {
        let price: Double
        let fetchedAt: Date
    }

    private init() {
        restorePersistedPrice()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSettingsChanged() }
        }
        // A sleep timer doesn't run while the app is suspended: coming back checks the age again.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshIfStale() }
        }
        refreshIfStale()
    }

    private static func isUsable(fetchedAt: Date?) -> Bool {
        guard let fetchedAt else { return false }
        let age = Date().timeIntervalSince(fetchedAt)
        // a date ahead of the clock (the clock was moved) isn't trusted either
        return age > -60 && age < maxUsableAge
    }

    /// Fetches the price unless one younger than five minutes is already here, and drops a price
    /// too old to use. Send screens call this when they appear.
    func refreshIfStale() {
        expireIfTooOld()
        if let priceFetchedAt, currentPriceUsd != nil,
           Date().timeIntervalSince(priceFetchedAt) < Self.refetchAge { return }
        guard fetchTask == nil else { return }
        let currency = currentCurrency
        fetchGeneration += 1
        let generation = fetchGeneration
        fetchTask = Task { [weak self] in
            // CoinGecko's keyless tier throttles bursts, so a miss is asked again on a growing pause.
            for delay in [0.0, 3.0, 8.0, 20.0, 45.0] {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard let self, !Task.isCancelled, self.currentCurrency == currency else { break }
                if let result = await self.coinGecko.getCurrentPrice(currency: currency) {
                    guard !Task.isCancelled, self.currentCurrency == currency else { break }
                    self.apply(result.price, currency: currency)
                    break
                }
            }
            guard let self, self.fetchGeneration == generation else { return }
            self.fetchTask = nil
        }
    }

    private func apply(_ price: Double, currency: AppCurrency) {
        let now = Date()
        setPrice(price, fetchedAt: now)
        if let data = try? JSONEncoder().encode(PersistedPrice(price: price, fetchedAt: now)) {
            UserDefaults.standard.set(data, forKey: priceKey(currency))
        }
    }

    /// Takes a price and when it was fetched: usable (and timed to drop out) while young enough,
    /// otherwise only the last known one.
    private func setPrice(_ price: Double, fetchedAt: Date) {
        lastKnownPriceUsd = price
        priceFetchedAt = fetchedAt
        expiryTask?.cancel()
        expiryTask = nil
        guard Self.isUsable(fetchedAt: fetchedAt) else {
            freshPrice = nil
            return
        }
        freshPrice = price
        let remaining = max(1, Self.maxUsableAge - Date().timeIntervalSince(fetchedAt))
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expireIfTooOld()
        }
    }

    /// Hides a price that has aged past `maxUsableAge`.
    private func expireIfTooOld() {
        guard freshPrice != nil, !Self.isUsable(fetchedAt: priceFetchedAt) else { return }
        freshPrice = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    private func priceKey(_ currency: AppCurrency) -> String { "kachat_kas_price_\(currency.rawValue)" }

    private func restorePersistedPrice() {
        guard let data = UserDefaults.standard.data(forKey: priceKey(currentCurrency)),
              let saved = try? JSONDecoder().decode(PersistedPrice.self, from: data) else { return }
        setPrice(saved.price, fetchedAt: saved.fetchedAt)
    }

    private func handleSettingsChanged() {
        let newCurrency = SettingsViewModel.loadSettings().currency
        guard newCurrency != currentCurrency else { return }
        currentCurrency = newCurrency
        fetchTask?.cancel()
        fetchTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        freshPrice = nil
        lastKnownPriceUsd = nil
        priceFetchedAt = nil
        restorePersistedPrice()
        refreshIfStale()
    }
}
