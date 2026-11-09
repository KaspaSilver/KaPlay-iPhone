# Online Chess (5.1): 1v1 and tournaments

Public 1v1 games and eight-player single-elimination tournaments where **every move is a Kaspa
transaction**. In KaPlay it lives in Play > **Chess**: choose 1v1 or Tournaments, each with its own Active and Finished games; the boards are on the Leaderboard tab. This document is the protocol (Android and desktop replicate it
byte for byte) and the indexer handoff for the leaderboard.

## 1. How it works

- A tournament is a room in the public **`#chess-arena`** broadcast channel. Every tournament
  message - create, join, move, resign, timeout claim, chat - is an ordinary plaintext
  broadcast payload (`kchat:1:bcast:chess-arena:<json>`), so the sender of every message is
  the transaction's signer: nothing can be forged, and no extra signature is needed.
- The channel is machinery, not a chat: the app hides it from Public Chats, never notifies for
  it, and only scans it while a chess screen is open.
- **There is no referee.** Every phone reads the same messages in the same order (block time,
  then txid) and applies the same rules below, so they all arrive at the same bracket, the same
  boards and the same clocks. A message that breaks a rule (a move out of turn, an illegal
  move, a ninth join) is simply ignored by everyone.
- Cost: one transaction per move, about 0.0017 KAS each. A 40-move game is ~0.07 KAS per
  player; a full tournament (3 rounds) ~0.2 KAS per finalist.

## 2. Messages

All are JSON in the broadcast content. `type` is always `"chess_t"`, `v` is `1`, `t` is the
tournament id (a lowercase UUID chosen by the creator).

| `a` | Fields | Meaning |
|---|---|---|
| `create` | `t`, `name` (≤ 40 chars), `p` (2 or 8), `k` (8 only) | Opens a private 1v1 or tournament (§2.1). The creator is player 1. KaPlay sends a fixed `name` and shows its own, never the one in the message. |
| `join` | `t` | Takes a seat (and opens a public room, §2.1). The first eight distinct addresses are the players; later joins are ignored. |
| `leave` | `t` | Gives a seat back while the room is still waiting (open). Ignored once it has started. |
| `cancel` | `t` | Private only, creator only, before the eighth join: the tournament is withdrawn. |
| `move` | `t`, `g`, `n`, `from`, `to`, `promo`? | A move in game `g` (`"<round>-<index>"`, e.g. `"1-3"`), `n` = the ply number (1 = white's first move), squares in algebraic (`e2`), `promo` in `q r b n`. |
| `resign` | `t`, `g` | The sender resigns game `g`. |
| `claim` | `t`, `g` | The sender claims game `g` on time: the opponent's clock had run out (§4). |
| `chat` | `t`, `g`, `text` (≤ 280) | A line under the board of game `g`. KaPlay neither sends nor shows these. |

Example: `{"type":"chess_t","v":1,"t":"7c1e…","a":"move","g":"1-0","n":1,"from":"e2","to":"e4"}`

### 2.1 Public rooms and private tournaments

- **Public 1v1 rooms** are numbered `duel-1`, `duel-2`, ... with two seats, and work exactly
  like the public tournament rooms below: the first join opens a room, one takes players at a
  time, and it starts (a single game, seed 1 white) the moment the second player joins.
- **Public tournament rooms** are numbered `public-1`, `public-2`, ... and nobody creates them: the first
  `join` to a room opens it, whichever number it names, and the app shows "Public tournament #N"
  with its seats at all times. Which room is taking players is the client's choice, the same
  rule on every platform: **the lowest-numbered room still open (not full); when none is, one
  past the highest room the phone knows**. Anyone can post a join naming any room, so the iPhone
  ignores some when choosing (it still plays them): only a canonical id counts (`duel-01` is not
  room 1), nothing past room 1,000,000,000, and of the runs of numbers at most 1,000 apart only
  the longest, so a stray `duel-900000` can't move the queue. Two things keep every phone's view the same: the
  arena keeps the indexer's full 30-day window locally (never the short default retention -
  a phone that forgot yesterday's rooms overnight offered a room number the others had moved
  past), and a phone pulls the arena's newest rows from the indexer right before it picks a
  room, after waiting for the initial history on open. The leaderboard is computed from the
  same rows, so phones with the same window agree; beyond the window the indexer's
  `/chess/leaderboard` (§6) is the answer. (There
  used to be a rule that a join to room N counts only once room N-1 is full; it made every
  phone depend on the complete history back to room 1, and a phone missing the early rooms
  rejected every later one and queued alone. Dropped.) A `join` that arrives after the last
  seat went is ignored, and the app re-joins the next room by itself. Public rooms cannot be
  cancelled.
- **Private 1v1s** are for playing a friend: `create` with `p: 2` needs no code; the id is the
  code to share. They count on the leaderboard exactly like public games.
- **Private tournaments** are for friends. `create` (`p: 8`, or absent) needs `k` = first 24 hex chars of
  SHA-256(`CODE:id`), where CODE is the creator code (upper-cased, trimmed; `KACHAT-CHESS`
  as shipped - change `ChessTournamentCodec.privateCreateCode` on every platform to rotate
  it) and `id` is the tournament's eight-character id (`a-z 2-9`, no confusable letters).
  A `create` with a wrong or missing `k` is ignored by everyone. The id is the code the
  creator shares; `join` with it takes a seat. Private tournaments are listed only to their
  players.

## 3. Bracket

- **Seeds** are join order: the creator is seed 1, the eighth joiner seed 8. The tournament
  starts at the block time of the eighth join.
- **Round 1:** games `1-0` … `1-3` are seeds 1v8, 2v7, 3v6, 4v5. **Round 2:** `2-0` = winner
  of `1-0` v winner of `1-1`, `2-1` = winners of `1-2` and `1-3`. **Round 3** (`3-0`) is the
  final. A round-2 or final game starts at the block time of the message that decided the
  later of its two feeding games.
- **Colours:** in round 1 the lower seed is white. Afterwards, the player who has had white
  fewer times in this tournament is white; if equal, the lower seed.
- **Seats expire.** A seat in a waiting room lasts five minutes from the join. A room that
  has not filled by then has lost that seat: at the next `join` to the room, every phone first
  drops seats older than five minutes (judged at that join's block time), then seats the
  joiner. So a player who closed the app, or walked away, is out of the queue by themselves
  - no message needed - and a room can never fill with players who left long ago. The app
  shows the time a seat is held for, and the lobby counts only live seats.
- A game with no message from one player is still a game: its clock runs from the start
  (§4). There is no "waiting for both players": if you are not there, you lose on time.

## 4. Clocks and results

- **5 minutes per side, no increment.** Time is measured in *chain time*: a player's clock
  is charged the block time of their move minus the block time of the previous event
  (the opponent's move, or the game start), **less the move's allowance of 10 s on every
  move, the first included** (`ChessTournamentCodec.moveDelayMs`, `allowanceMs(ply:startedAt:)`;
  the charge is `max(0, elapsed - allowance)`). White's first move is measured from the game's
  start block time, and the match-found countdown (§5) is exactly those 10 s - so the clock
  runs from the instant the board opens, not a second before, and no separate grace holds it.
  **Rule windows by the game's start block time** - before `allowanceFromMs` = 1790208000000
  (2026-09-24 00:00 UTC): no allowances; from there to `allowanceV2FromMs` = 1790280000000
  (2026-09-24 20:00 UTC): 25 s on a side's first move (`firstMoveGraceMs`), 10 s after; from
  `allowanceV2FromMs`: 10 s on every move.** A rule change never reaches back: the
  games before it were decided under the rules of their day, and re-judging them re-opened
  finished games (a claim valid at 5:00 became "early" under the grace) and let a player resign a finished
  game for a second loss. Any future clock rule change gets its own activation instant the
  same way, shipped identically on every platform. The
  ten seconds cover what a move spends reaching the other phone - a block, the indexer's
  poll - so propagation is nobody's thinking time. A side that never shows up is not stuck
  either: their five minutes run out and the opponent claims. The phone shows the side to move's clock from the last
  event's block time by its own wall clock, frozen while the allowance lasts. Whatever a
  phone claims about its own thinking time is irrelevant; the chain decides.
- **Flagging:** when the side to move's remaining time reaches zero, the *opponent* posts
  `claim`. Everyone accepts it if, at the claim's block time, the mover's clock had indeed
  run out (the same allowance applies: elapsed − allowance ≥ remaining). A claim that
  arrives early is ignored. (The app posts the claim itself the moment it sees the opponent
  flagged, and tries again at most four times per flag if it doesn't take; after that the board's
  Claim win is still there.) A player may also resign.
- **Game over:** checkmate (mover wins), resignation, time claim, or a draw (stalemate,
  insufficient material, fifty moves, threefold repetition). Knockout needs a winner, so a
  **draw goes to the player with more clock left**; if equal, to black.
- **Reconnecting:** leaving the app does not stop your clock. Come back within your remaining
  time and play on; otherwise the opponent claims the win. (The clock IS the grace period - a
  separate one-minute rule would be shorter than a long think in a five-minute game.)
- Ply `n` must be exactly the next ply; the sender must own the side to move; the move must
  be legal from the current position. Anything else is ignored and the game is unchanged.

## 5. Spectating and the lobby

- **Match found.** When a room fills, every phone shows "Match found" (or "Tournament
  full") with a countdown and opens the board at `startedAt + 10 000 ms` of chain time
  (`ChessTournamentCodec.matchFoundDelayMs`) - the same instant everywhere, so the players
  arrive together; a phone that learns of the start later than that opens the board at once.
  It is display only (nothing on chain), and it is exactly the first move's 10 s allowance
  (§4), so it costs nobody clock. Leaving is off once the room has filled.

- The lobby shows the public room taking players, the player's own private tournaments,
  public tournaments in play and recently finished. Anyone can open a public tournament and
  watch any game live, since all games are the same public stream.
- A winner is taken to the **bracket** (quarterfinals → semifinals → final → champion, the
  pairs joined by lines; live games carry a LIVE pill and the running clock, finished ones
  mark the winner, undecided ones say who they wait on). Every game there is a tap away to
  watch. The moment the winner's next game exists (§3) - even while they are watching
  another game - it opens by itself. No result screen for a game won inside a tournament;
  the result screen comes with a loss (knocked out) or with the final.

## 6. Leaderboard (indexer handoff)

The leaderboard is two boards, by address, over the games played here - never the casual
games inside 1:1 chats:

- **1v1**: wins and losses in **every game played here** - `duel-N` rooms, private 1v1s and
  the games inside tournaments alike (`wins` / `losses`). Most wins first, fewest losses
  breaking ties.
- **Tournaments**: whole tournaments only - **won** (champion of the eight-player bracket)
  and **lost** (knocked out: a lost game inside a tournament is one tournament loss, counted
  the moment it happens; winning a game inside one scores nothing until the final is won).
  Most won first, fewest lost breaking ties. A 1v1 never counts here.

`wins`/`losses` in the row below are the totals over both.

**Two periods, both fresh from one cutoff.** Each board is shown for **This month** and
**All time**. Nothing that started before the fresh-start cutoff **`1792647960000` ms
(2026-10-22 05:46 UTC)** counts on either: `ChessTournamentEngine.leaderboardFreshFromMs`
in the app, `chess::LEADERBOARD_FRESH_FROM_MS` in the indexer, and the two must be equal.
A tournament or 1v1 counts in the period it **started** in (`startedAt >= since`), with all
of its games, even ones that end after the month rolls over:

- all time: `since = cutoff`
- this month: `since = max(cutoff, 00:00 UTC on the 1st of the current month)`, so the
  month board resets on the 1st of every month, UTC.

The app merges the indexer's board with its own (per player, the larger of each figure)
and uses an indexer board only if its `period` and `since` match what the app computes;
otherwise it shows its own.

For the full history the KaChat broadcast indexer must:

1. **Track `chess-arena`** like the curated rooms (30-day history served by `/get-broadcasts`),
   so a phone that opens Chess sees every tournament of the last month, not only what it
   scanned itself. **This one is a config change, and it is what makes two phones find each
   other:** add the channel to the broadcast indexer's allowlist -
   `CHANNELS: "kaspa,kachat-bugs,chess-arena"` in its `docker-compose.yml` - and restart it.
   The app already polls `/get-broadcasts?channel=chess-arena` every 8 s while Chess is open
   and merges what comes back. Without it a phone only learns of a join or a move it
   happened to scan live from a block, so the other player's join is missed whenever the
   phone was locked, reconnecting, or not yet on the Chess screen when it landed.
2. **Serve `GET /chess/leaderboard?limit=100&period=month|all`** (missing `period` = `all`) →
   `{"players":[{"address":"kaspa:…","wins":12,"losses":4,"duelWins":9,"duelLosses":3,"tournamentGameWins":3,"tournamentGameLosses":1,"tournamentsPlayed":5,"tournamentsWon":2,"tournamentsLost":3,"lastPlayedAt":<ms>}], "period":"month", "since":<ms>, "generatedAt":<ms>}`,
   sorted by `wins` desc, then `losses` asc (the phone sorts each board itself, see
   `ChessTournamentEngine.duelLeaderboard` / `tournamentLeaderboard`). Computed by replaying the arena with the
   rules above (the reference reducer is `ChessTournamentEngine.swift` in this repo; port it,
   do not reinterpret it). Also `GET /chess/player?address=&period=month|all` → the same row for one player.
3. Optional: `GET /chess/tournaments?status=open|live|done&limit=` → the lobby list
   precomputed, for phones that want it without scanning.

Without (1) and (2) the lobby shows what the phone has scanned in-session plus whatever
the store retains, and the leaderboard is local (both periods, same rules).

## 7. Bot games (KaChat Chess)

Play > Bots: five bots, level 1 to 5 (Kaspa Silver, Izio Dev, Coderofstuff, Michael Sutton,
Yonatan Sompolinsky). Level 1 is open; each level opens when the one before it is beaten
(kept on the phone, per address). The bot runs on the player's phone and the game costs nothing
while it is played. **When it ends, its result and moves go on chain in one transaction**, the
stamp, signed by the player's address, about 0.0017 KAS. Online games (§1-6) stay on chain move
by move: their transactions are how the phones talk, and there is no referee to replace them.

- Channel **`#chess-bots`**, not the arena. Payloads are `kchat:1:bcast:chess-bots:<json>`.
- Every finished game is stamped: a win, a loss, a draw or a resignation. A game abandoned by
  closing the app is not, and costs nothing.
- A failed send holds until Retry. One a node may have taken without answering says the stamp may
  have gone through, with no Retry, so a game is never stamped twice. A level unlocks on the phone the moment it is won, stamped or
  not; only a stamped win counts on the leaderboard.

| Field | Meaning |
|---|---|
| `type`, `v` | `"chess_bot"`, `2` |
| `g` | Game id: a lowercase UUID |
| `a` | `"result"` |
| `bot` | The bot's level, 1...5 |
| `c` | The player's colour: `"w"` or `"b"` |
| `r` | How it ended for the player: `"won"`, `"lost"` or `"drawn"` |
| `why` | `checkmate`, `resignation`, `stalemate`, `insufficient material`, `the fifty-move rule`, `threefold repetition` |
| `m` | Every move of the game, both sides, space separated: `e2e4 e7e5`, a promotion `e7e8q` |

Example: `{"a":"result","bot":3,"c":"w","g":"3b0f…","m":"e2e4 e7e5 d1h5 b8c6 f1c4 g8f6 h5f7","r":"won","type":"chess_bot","v":2,"why":"checkmate"}`

Earlier builds sent `v: 1` messages per move (`start`, `move`, `resign`). They are still on chain
and count for nothing.

### 7.1 Bot leaderboards

One board per bot: each player's **fewest moves to win**, this month and all time (the periods of
§6). "Moves" are the player's own: a win as white in `m` of 7 plies is 4 moves. A tie goes to the
earlier win. Bot games still do not count on the 1v1 or Tournaments boards.

The phone reads `GET /chess/bots/leaderboard?period=month|all&limit=100` (the hand-off is
`docs/CHESS_BOT_LEADERBOARD.md` in the indexer repo) and merges the player's own stamped wins, kept
on the phone, so a win shows at once.

The board is **not cheat proof**. The bot has no key and plays with randomness on the player's
phone, so nobody else can tell whether it really chose the moves in `m`: the indexer can check that
they are legal and end in checkmate, not that the game happened. It is a board for fun.

### 7.2 Links with KaPost

- **Share:** after a win is stamped, Share to KaPost opens `kaposts://compose?text=<percent-encoded
  post>`: KaPost's composer with the post written, and the player taps Post. Without KaPost the
  App Store opens.
- **The post** ends in the challenge link:
  `kachatchess://bot/<level>?name=<bot name>&moves=<n>&by=<address>&game=<game id>`. KaPost draws it
  as a card with a Challenge button, which opens the link, or the App Store without KaPlay.
- **KaPlay** opens the link on the Play tab: that bot's screen with the challenge at the top, or the
  ladder if the bot is still locked. Only the level is required; a bad `moves` or `by` is left out.
