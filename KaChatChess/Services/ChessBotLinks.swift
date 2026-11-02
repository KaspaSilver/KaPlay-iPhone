import SwiftUI
import UIKit

/// Someone's win against a bot, from the Challenge button on their KaPost: beat `bot` in fewer
/// than `moves`.
struct ChessBotChallenge: Identifiable, Equatable {
    let bot: ChessBot
    let moves: Int?
    /// The address that won.
    let by: String?

    var id: String { "\(bot.level)-\(moves ?? 0)-\(by ?? "")" }
}

/// A challenge link waiting for the Play tab, which may not be up yet (a cold start, or a link
/// opened before signing in).
@MainActor
final class ChessBotLinkRouter: ObservableObject {
    static let shared = ChessBotLinkRouter()
    @Published var challenge: ChessBotChallenge?
}

/// The two links between KaPlay and KaPost (ONLINE_CHESS.md §7): the post KaPlay asks KaPost to
/// compose, and the challenge link in that post, which opens KaPlay.
enum ChessBotLinks {
    static let scheme = "kachatchess"
    /// Where sharing goes when KaPost isn't installed.
    private static let kaPostAppStoreURL = URL(string: "https://apps.apple.com/search?term=KaPost")!

    /// `kachatchess://bot/<level>?name=<bot>&moves=<n>&by=<address>&game=<game id>`
    static func challengeURL(bot: ChessBot, moves: Int, by: String, gameId: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "bot"
        components.path = "/\(bot.level)"
        components.queryItems = [
            URLQueryItem(name: "name", value: bot.name),
            URLQueryItem(name: "moves", value: String(moves)),
            URLQueryItem(name: "by", value: by),
            URLQueryItem(name: "game", value: gameId)
        ]
        return components.url
    }

    /// Links come from other people's posts, so only the level has to be right; a bad `moves` or
    /// `by` just leaves that part out of the challenge.
    static func challenge(from url: URL) -> ChessBotChallenge? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "bot",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let level = Int(url.lastPathComponent),
              let bot = ChessBot.all.first(where: { $0.level == level }) else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }
        let moves = value("moves").flatMap { Int($0) }.flatMap { (1...999).contains($0) ? $0 : nil }
        let by = value("by").flatMap { KaspaAddress.isValid($0) ? $0 : nil }
        return ChessBotChallenge(bot: bot, moves: moves, by: by)
    }

    /// Opens KaPost's composer with the post written (`kaposts://compose?text=...`); the player
    /// still taps Post there. Without KaPost installed, the App Store opens.
    @MainActor
    static func shareToKaPost(bot: ChessBot, moves: Int, gameId: String) {
        guard let address = WalletManager.shared.currentWallet?.publicAddress,
              let challenge = challengeURL(bot: bot, moves: moves, by: address, gameId: gameId) else { return }
        let text = "I beat \(bot.name) (Level \(bot.level)) in \(moves) moves on KaPlay. Think you can do it in fewer?\n\n\(challenge.absoluteString)"
        // Letters, digits and -._~ only: the whole post is one value, so the challenge link's own
        // & and = must not end it, and its own escapes get escaped again to come back intact.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "kaposts://compose?text=\(encoded)") else { return }
        UIApplication.shared.open(url) { opened in
            if !opened { UIApplication.shared.open(kaPostAppStoreURL) }
        }
    }
}

/// What a challenge asks, at the top of the screen it opened.
struct ChessBotChallengeBanner: View {
    let challenge: ChessBotChallenge
    @ObservedObject private var progress = ChessBotProgress.shared

    private var message: String {
        let who = challenge.by.map { ContactsManager.shared.displayName(for: $0) } ?? "Someone"
        let bot = challenge.bot
        let claim = challenge.moves.map { "\(who) beat \(bot.name) in \($0) moves. Can you do it in fewer?" }
            ?? "\(who) challenges you to beat \(bot.name)."
        return progress.isUnlocked(bot) ? claim : "\(claim) \(bot.name) is still locked: climb the ladder to reach it."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "flag.2.crossed.fill")
                .font(.title3)
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.orange.opacity(0.14)))
    }
}
