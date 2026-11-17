import SwiftUI

/// The chess screens' words that are built in code. `Text("literal")` is looked up by SwiftUI; a
/// String made in code is not, so it comes through here: looked up in the in-app language
/// (`AppLocalization`, so a language switch in Settings takes effect at once), its numbers and
/// names filled in after. One whole sentence per case, never English pieces glued together, which
/// no translation can follow; a count picks its singular or plural key here, in code.
enum ChessText {
    static func string(_ key: String) -> String { AppLocalization.string(key) }

    /// `key` is a format ("%@ won on time."): looked up first, then filled in. Ints go in as
    /// `%lld`, the key a `Text("\(int)")` would look up too.
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: AppLocalization.string(key), locale: AppLocalization.locale, arguments: args)
    }

    /// m:ss
    static func clock(_ ms: Int64) -> String {
        let seconds = Int(max(0, ms) / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Rooms, rounds and seats

    /// A game's place in its room, as a title: "1v1", "Round 1", "Semifinal", "Final".
    static func roundTitle(_ round: Int, isDuel: Bool) -> String {
        if isDuel { return string("1v1") }
        switch round {
        case 3: return string("Final")
        case 2: return string("Semifinal")
        default: return string("Round 1")
        }
    }

    /// "Move 12 · white to move".
    static func moveLine(_ game: ChessTournamentGame) -> String {
        let number = game.moves.count / 2 + 1
        return game.sideToMove == .white
            ? format("Move %lld · white to move", number)
            : format("Move %lld · black to move", number)
    }

    static func seatsLeft(_ count: Int) -> String {
        count == 1 ? string("1 seat left") : format("%lld seats left", count)
    }

    static func playersWaiting(_ count: Int, of capacity: Int) -> String {
        count == 1 ? format("1 of %lld players waiting", capacity) : format("%lld of %lld players waiting", count, capacity)
    }

    /// A room's row: "3 of 8 players", with its code when it's private.
    static func playerCount(_ tournament: ChessTournament) -> String {
        let count = tournament.players.count
        if tournament.isPublic {
            return count == 1
                ? format("1 of %lld players", tournament.capacity)
                : format("%lld of %lld players", count, tournament.capacity)
        }
        return count == 1
            ? format("1 of %lld players · code %@", tournament.capacity, tournament.id)
            : format("%lld of %lld players · code %@", count, tournament.capacity, tournament.id)
    }

    /// "You're waiting in Public 1v1 #4" / "You're playing in …".
    static func whereYouAre(_ tournament: ChessTournament) -> String {
        tournament.status == .open
            ? format("You're waiting in %@", tournament.displayName)
            : format("You're playing in %@", tournament.displayName)
    }

    /// The text a private room's share button sends: where the code goes, one sentence per kind.
    static func invite(for tournament: ChessTournament) -> String {
        tournament.isDuel
            ? format("Play me at chess in KaPlay: open Play > Chess > 1v1 > Join with a code, and enter %@.", tournament.id)
            : format("Join my chess tournament in KaPlay: open Play > Chess > Tournaments > Join with a code, and enter %@.", tournament.id)
    }

    // MARK: - Results

    /// A finished game in a list: "alice won by checkmate".
    static func resultSummary(_ game: ChessTournamentGame, now: Int64, name: (String) -> String) -> String {
        guard let winner = game.winner, let outcome = game.outcome else {
            // Out of clock, claim not posted: the same result, said the same way.
            if let winner = game.decidedWinner(at: now) { return format("%@ won on time", name(winner)) }
            return string("finished")
        }
        let who = name(winner)
        switch outcome {
        case .checkmate: return format("%@ won by checkmate", who)
        case .resignation: return format("%@ won by resignation", who)
        case .timeout: return format("%@ won on time", who)
        case .drawTiebreak(let reason):
            switch reason {
            case "stalemate": return format("%@ won on clock after a draw by stalemate", who)
            case "insufficient material": return format("%@ won on clock after a draw by insufficient material", who)
            case "fifty-move rule": return format("%@ won on clock after a draw by the fifty-move rule", who)
            case "threefold repetition": return format("%@ won on clock after a draw by threefold repetition", who)
            default: return format("%@ won on clock after a draw", who)
            }
        }
    }

    /// The board's and the result screen's sentence: "Checkmate. alice won."
    static func resultSentence(winner who: String, outcome: ChessTournamentGame.Outcome) -> String {
        switch outcome {
        case .checkmate: return format("Checkmate. %@ won.", who)
        case .resignation: return format("%@ won by resignation.", who)
        case .timeout: return format("%@ won on time.", who)
        case .drawTiebreak(let reason):
            switch reason {
            case "stalemate": return format("Draw by stalemate. %@ won on clock.", who)
            case "insufficient material": return format("Draw by insufficient material. %@ won on clock.", who)
            case "fifty-move rule": return format("Draw by the fifty-move rule. %@ won on clock.", who)
            case "threefold repetition": return format("Draw by threefold repetition. %@ won on clock.", who)
            default: return format("Draw. %@ won on clock.", who)
            }
        }
    }

    /// Under the end overlay's headline.
    static func outcomeDetail(_ outcome: ChessTournamentGame.Outcome) -> String {
        switch outcome {
        case .checkmate: return string("Checkmate")
        case .resignation: return string("By resignation")
        case .timeout: return string("On time")
        case .drawTiebreak(let reason):
            switch reason {
            case "stalemate": return string("Draw by stalemate - won on clock")
            case "insufficient material": return string("Draw by insufficient material - won on clock")
            case "fifty-move rule": return string("Draw by the fifty-move rule - won on clock")
            case "threefold repetition": return string("Draw by threefold repetition - won on clock")
            default: return string("Draw - won on clock")
            }
        }
    }
}

extension ChessTournament {
    /// The room's name as people read it, in the app's language. `name` is the reducer's
    /// (English, the same on every phone); this is only what's shown.
    var displayName: String {
        if let number = ChessTournamentCodec.publicNumber(of: id) {
            return ChessText.format("Public tournament #%lld", number)
        }
        if let number = ChessTournamentCodec.duelNumber(of: id) {
            return ChessText.format("Public 1v1 #%lld", number)
        }
        return ChessText.string(isDuel ? ChessTournamentCodec.privateDuelName : ChessTournamentCodec.privateTournamentName)
    }
}
