# KaPlay

Chess on Kaspa: online, every move is a Kaspa transaction, so every game is on chain for
good. Public 1v1 rooms, private games by code, and eight-player knockout tournaments, five
minutes a side, with monthly and all-time leaderboards.

KaPlay is KaChat's Chess Online made into its own iPhone app (the project and bundle still say
KaChat Chess). It plays the same
games as KaChat, against the same players: the protocol is [ONLINE_CHESS.md](ONLINE_CHESS.md)
(the `#chess-arena` broadcast channel, `kchat:1:bcast:chess-arena:` payloads, the
leaderboard from the KaChat indexer's `/chess/leaderboard`).

## The app

- **Play**: 1v1 (the public room taking players, or a friend by code) and Tournaments,
  each with Active and Finished games to watch; and Bots, a ladder of five bots (level 1
  to 5) whose games are stamped on chain once, when they end (ONLINE_CHESS.md §7). A win can
  be shared to KaPost as a challenge.
- **Leaderboard**: 1v1 games, tournaments and each bot (fewest moves to win), this month and
  all time.
- **Wallet**: the total balance, split into the chatting address, which signs every move, and
  the spending addresses; Send, Receive and Request; Manage Addresses; Your Domains (.kachat,
  .kas, .k, .kaspa); notifications and Help.
- **Settings**: About, Account Name, Back Up Account (the 12 or 24 words, and an NFC card),
  Connection (the Kaspa node and indexers), Customization (appearance, language and currency),
  Security, Delete Account and Log Out.

Sign-in is KaChat's: create a new account, or import one with its 12 or 24 words or from an NFC
card.

## Building

Open `KaChatChess.xcodeproj` in Xcode 26 and run the `KaChatChess` scheme. One target,
iOS 16+, bundle `com.kachat.chess`. Swift packages: grpc-swift, swift-protobuf,
swift-secp256k1 (pinned in `Package.resolved`).

The version and build number live in `KaChatChess/Version.xcconfig`.

## Where it came from

The first commit is KaChat-iPhone's app as it was at `b603eb9f`; the commits after it cut
it down to chess. Most of KaChat's service layer is still there underneath (the wallet,
the node pool, and `ChatService`, whose transaction queue and coin bookkeeping every move
goes through, with its chat syncing switched off).
