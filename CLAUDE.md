# CLAUDE.md

Guidance for Claude Code in this repository.

## What KaPlay is

KaPlay (the folder, project, target and bundle `com.kachat.chess` still say KaChat Chess; only
what people read says KaPlay) is chess on Kaspa as its own iPhone app: every move is a Kaspa
transaction. What the app does and where it came from: [README.md](README.md). The protocol:
[ONLINE_CHESS.md](ONLINE_CHESS.md).

Tabs (`ChessMainTabView.Tab`): Play, Leaderboard, Wallet (`Views/Wallet/ChessWalletView.swift`),
Settings. Play opens on `GamesView`, a card per game; Chess is the only one so far and opens
`ChessHomeView`. A new game is one more card there.

The Wallet tab (`ChessWalletView`, `Views/Wallet/ChessWalletView.swift`) is the chatting address
only (owner's call, 2026-11-19, replacing KaPay's full wallet from 2026-11-07): the fixed title with
the backup banner, `BalanceToolbarLabel` in the bar, `ConnectionStatusIndicator` left and the bell
right, then `ChattingAddressManageView` (generic over its header) with `ChessWalletHeader`: the
chatting address's balance card (tap to copy, fiat on mainnet), a quiet line when spending addresses
still hold Kaspa ("… on your other addresses. Manage them in KaPay.", `HotWalletBalance` read once on
appear), Backup Hygiene when due, the testnet faucet, its History (each transaction opens the
explorer; reloaded 1.5 s after the chatting address's own UTXO activity while on screen, marked dirty
while hidden, at most every 30 s on appear, an older or cancelled read never replacing rows shown),
and Receive (`ChattingAddressQRView` on KaPay's
receive screen, `AddressReceiveView`: the Kaspa logo and "Chatting Address", the balance, the QR on a
white card, the whole address, the orange note that it shows your .kachat name, tap anywhere to copy,
then a notes card: Kaspa and kUSDT can be sent here, and what moves cost) and Send
(`WithdrawKaspaView` with `lockedSource: .chatting`, so no From step) at the bottom
(`ChattingAddressActionBar`; until the coins load, Send and Receive use the wallet's live balance,
and a failed coin read shows Try Again). The bell's Received row opens the same chatting-only screen
(`chattingOnly: true`). No spending
addresses, Request, Manage Addresses, Your Domains, UTXOs tab or keys there: those are KaPay's. The
old full wallet is `FullWalletView` in WalletViews.swift, kept but never shown, with the screens
only it opens (`ManageAddressesView`, `CreatePaymentRequestView` with Show Request As QR,
`KNSDomainsListView`); bring it back by pointing `ChessMainTabView` at it.

.kachat names are display only, as in KaChat (owner's call, 2026-11-18: claiming, renewing,
selling, transferring, buying and offers are KaPay's only). A bell row opens `KachatNameRouteView`:
the name's card and "Renew, sell or transfer it in KaPay.", or for a free name "Get a .kachat domain"
(`KachatNamesInfo.pageURL`, home.kachat.app/kachat/). In the unshown full wallet, Your Domains >
.kachat and each address's .kachat tab are plain cards too. The .kachat write screens are deleted
(2026-11-20); `KachatNamesActions` keeps only the read side and `resume()`, which
`KaChatChessApp.handleScenePhaseChange` runs on every activation so a claim begun before 2026-11-18
still finishes. KaPlay schedules no renewal reminders (`KachatNameReminders.removeLegacyOnce()`
clears old ones) and the bell has no offer rows. KaPlay has no
Contacts (owner's call, 2026-11-07: someone who wants saved contacts uses KaChat or KaPay).

Account removal clears what the app keeps per account, on both networks' addresses: the bell and
what it compares against, saved .kachat names, the balance cache, added date, address
choice, bot games, the arena's pending stamps (`publicChatLocalStampSentAt`), pending .kachat commit
salts and the passphrase flag (`WalletManager.removeWalletTabData`), and the spending data. The bell (`GlobalNotificationCenter`) lists .kachat news
(`KachatNamesNotifier`) and Kaspa received on the chatting address from someone else
(`WalletReceiptNotifier`, fed each live UTXO batch; KaPlay's subscription is the chatting address
only, so spending addresses get no Received rows). A row opens the address
(`OwnAddressHistorySheet`) or the name. Each transaction in a batch is judged alone
(`confirmAndRecord`), so a payment arriving in the same batch as one of your own moves still shows.

.kachat names are shown through `KachatNameLabel.display`: "alice.kachat" by default, "alice"
when Settings > Customization > Show .kachat Endings is off (as in KaChat). That covers player names
in games and leaderboards (`ContactsManager.identityName`). Copying a name, typing one and anything
sent keep working with either form.

Every menu's title is the same as KaPosts': big and fixed above the content that scrolls
(`fixedScreenTitle`), with the balance alone in the center of the bar (`BalanceToolbarLabel`). The
game boards have no room for it, so `ScreenTitleToolbarLabel` puts their title over the balance in
the bar.

## Bots and the Leaderboard tab

Bot games are free while played and stamped on chain once, when they end (`ChessBotGame`,
ONLINE_CHESS.md §7); online games stay on chain move by move. The Leaderboard tab has three rows
(`ChessLeaderboardLink`: the icon in a circle, the name and a chevron), each opening its own page: 1v1 and Tournaments their board
(`ChessLeaderboardPage`), Bots `ChessBotLeaderboardsView`, a board per played bot ranked by fewest
moves to win (`ChessBotLeaderboardService`). A stamped win can be shared to KaPost, and the post's Challenge
button opens KaPlay (`ChessBotLinks`, ONLINE_CHESS.md §7.2).

Online moves, joins, claims and bot stamps never wait in a silent background retry
(`PublicChatService.sendPublicChat(deferNoInputRetry: false)`): no coins on the chatting address says
"Not enough KAS on your Chatting Address", and only "change not mined yet" is retried, a few times.
A move, join or claim the chain never shows is looked up after 60 s and dropped at about 75 s when
the network says it doesn't hold it (or after 5 minutes when nothing can be asked), so it can be
played again; a join that didn't land closes the waiting room with "Your join didn't reach the
network". A queued public join is kept until the room has started with the player in it and the
join has chain time. Your own move is refused once your clock is at zero. Every chess send is tied
to the account that made it (`sendPublicChat(expectedSender:)`): an account switch mid-retry sends
nothing, and bot results and stamped wins are filed under the account that played. A move uses at
most `maxInputsPerTransaction` coins and 100,000 grams; past that the player is asked to compound.
Chess error toasts clear after 3 s. A timeout claim that doesn't take is retried automatically at most 4
times per flag, 30 s apart, paging the arena again first (`maxAutoClaims`); after that the board's
Claim win is still there. A decided game can be left without resigning. Per-account arena state (queued join, pending moves, claims) clears when the
account changes. The 30-day replay runs off the main thread (`reduceArena`).

## When the chess server is down

The arena's indexer is watched by `PublicChatIndexerClient.arenaHealth` (`arenaServerDown` on the
screens, `ChessServerDownNote`; one request a minute checks whether it's back). Live moves come from
the block stream, on cellular too while it's down. The player's own live games are also read every
10 s from that game's two players' addresses on the Kaspa REST API (`readArenaFromChain`), which fills gaps
but can't find rooms or joiners, since a channel has no address: the arena's history can't be
rebuilt without the indexer. So public rooms aren't joinable without its answer, and a timeout claim
needs a read of the chain newer than the flag (`flagIsConfirmed`), or a fresh newest page when the
game started inside the stretch already paged (`arenaAnsweredAt(covering:)`). `IndexerHealth`
counts failures under 5 s apart as one; it's back after 2 answers in a row, or one after 5 minutes
down, and then only the outage is paged in again, its block times replacing the stream's. A deep
history page that fails doesn't count toward an outage, and one failing 3 times in a row is skipped
(a gap at the old end).

The .kachat registry has its own outage rule: it moves to the chain after 3 failed indexer requests
within 2 minutes, failures under 5 s apart counting as one (`KachatNamesRegistry.indexerOutageConfirmed`).
A .kachat name resolved to an address always has its record checked live on chain
(`confirmOnChain`), and the chain copy only answers while its last full check is under 3 minutes old
(`chainCopyIsCurrent`). A record that can't be read throws, never reads as free. A failed lookup
says "Couldn't check" / "Couldn't load", never "not registered" or "0": that covers KNS outages
(`KNSService.lookupDomain`) and resolver addresses not on the active network. The address card on
send screens (`AddressResolutionCard`) shows an address's own .kachat name only after
`KachatNamesRegistry.verifiedLabel` confirms its owner on chain.

## Nothing players type reaches other players

So App Review has no typed content to moderate, KaPlay has no game chat and no typed room names:
it ignores `chat` messages from other apps, and every private room is "Private 1v1" or "Private
tournament" whatever its `create` message says (ONLINE_CHESS.md §2). Adding either back means
adding Terms of Use, Report and Block too, as KaPost has them.

## Accounts

The same as KaPay's; keep them in step. Create New Account makes an account in one tap: 24 words,
no passphrase, the next free default name (`WalletManager.nextDefaultAccountName`). "Advanced:
Create with a Passphrase" (`CreateWalletView`) is the only other way: also 24 words, through
`PassphraseOptionView`, whose entry screen shows the address and its balance as you type
(`PassphraseAddressPreview`). Import takes 12 or 24 words and works out the wallet type itself, as
KaChat does: name, 12 or 24, the words, then "Did you use a passphrase?". No opens "Your Account",
Yes runs the same search as the passphrase is typed (`WalletManager.findImportAccounts`): every
`WalletSourceFamily` (Standard 50 addresses, KDX and OneKey 20, Chainge 1) in one UTXO call, plus
each type's address #0's transaction count, keeping addresses with funds or history, the type with
the most funds first. More than one found are listed to pick from; See Every Wallet Type adds each
type's #0; nothing found or a failed search (12 s) opens Standard #0 with Search Again. There is no
"where are your words from" list any more (`ImportSourceWalletView` is gone).

Creating never shows the seed phrase: an account made here is owed a backup
(`AccountBackupStatus`), and until the backup steps (`AccountBackupView`) are finished every tab's
first screen shows `AccountBackupBanner` above its title (`fixedScreenTitle(_:showsBackupBanner:)`,
red once the chatting address holds funds; the dock has no badge) and the Delete Account warning
leads with Back Up Account; deleting is never blocked. The words are called "12 or 24 words" everywhere people read,
as in KaChat. Imported and older accounts are never owed one. Finishing the steps or importing, by
typing the words or from a card, starts a six-month timer. When it runs out the Wallet tab shows `BackupHygieneCard`
in the same place, and `BackupHygieneView` asks for five random words, then the passphrase if there
is one.

The signed-in account's seed, private key and record are three Keychain writes, so
`WalletManager.writeActiveSlot` files a `SlotWriteIntent` around them and the next load finishes a
write the app was killed in, from the account's snapshot. Importing the words of an account already
saved here keeps its data. The recovery screen's Remove refuses while a snapshot can't be read.
Delete Account stops polling and the UTXO subscription first, then removes the active slot's keys and
record (put back if a step fails), then the account's snapshot on both networks' addresses (and, for
the last account, the Secure Enclave key); only then does the per-account data go, so a failed delete
leaves the account signed in and whole. The words and passphrase, and every saved account's snapshot,
are Keychain items readable only while the phone is unlocked (`tightenAllSeedItems` moves older items
at each `loadWallet`); on a phone with a Secure Enclave a key that fails to wrap is never saved
(`wrappedForStorage`). Settings learns whether there's a passphrase from a per-address flag
(`WalletManager.currentAccountHasPassphrase`), not by decrypting the words. After Log Out
`getPrivateKey()` returns nil.

**NFC card backup** (`Services/NFCCard.swift`, in App Store builds too since 2026-11-06, as in
KaChat; `NFCCard.isAvailable` hides it where NFC can't read these cards, such as iPad): an extra copy of the words of a seed phrase
the user already has, on a Java Card loaded with
[KaChat-NFC](https://github.com/KaspaSilver/KaChat-NFC) through Kaspa Quick Start's NFC Card page.
Not cold storage: the card never generates or uses a key. The same as KaPay's and KaChat's; the card
commands and backup format are that repo's `docs/PROTOCOL.md`, so change them there first. Settings
> Back Up Account > Back Up to NFC Card (`NFCCardBackupView`, behind the seed phrase's biometric gate) only exists for
an account with a passphrase, which is what protects it: it's never written to the card. The Import
name screen's Restore from NFC Card, at its bottom (`NFCCardRestoreView`), reads with the 6-digit PIN, asks for the
passphrase and checks it against the saved chatting address. Saving to a card never clears the
backup strip. The App ID needs Near Field Communication Tag Reading on.

Settings is KaChat's alphabetical cards: About (created date, version, website, support email, the
privacy policy at home.kachat.app/privacy/, licenses), Account Name, Back Up Account (Complete Your
Backup while owed, View 12 or 24 Words, Back Up to NFC Card), Connection, Customization, Security.
Connection > Connection Settings (`ConnectionSettingsView`) is KaPay's cards, each opening its own
screen (`page`) with its host or node under the name: Chess (the arena's indexer,
`publicChatIndexerURL`), Node (saves as you pick, no Save), Domains (the .kachat Indexer URL,
`indexerURL`, and "Reading names from" the indexer or the chain; then the other name services) and
Explorer (the REST API). KaPay's Push and Trestly cards are KaPay's only.
Below them Delete Account (`DeleteAccountSheet`, the warning the sign-in screen's Delete also shows)
and Log Out, which KaChat keeps on Profile and KaPlay has no Profile for. Every sign-in gets new tabs
(`ContentView`'s `signInSession`), opening on Play. Biometrics for Account Login is off by default,
and existing installs were switched off once (`AppSettings.accountLoginBiometricsOffMigration`).

Face ID, as in KaChat (the owner's call, 2026-11-13): Kaspa sends never ask; the swipe sends at
once, and `startSending` switching to `.sending` is the double-send guard. `DeviceAuth` still asks on
both Delete Account sheets, the keys-missing screen's Remove, Send Domain, the KNS profile and
primary-domain saves (in the unshown full wallet), and revealing the seed phrase. Settings has no
"Biometrics for Address Private Keys" switch any more: no private key is shown in KaPlay.
`SwipeUpToSendScrollView`'s `authReason` has no caller since the .kachat sheets went.
Chess moves and messages don't ask. A
send a node may have taken without answering ends on "Not confirmed" with only Done
(`SendOutcomeUnknownError`), never Try Again, which could pay twice. The next send to that address
is refused while it's unresolved (`refuseWhileSendUnresolved`); it says "went through" only when the
network or the REST API holds that transaction, never because a coin was spent (a later move can
spend it after the 600 s hold), and the record is dropped once the coins are unspent, REST says it
doesn't have it, or 30 minutes pass.

## Send Kaspa

Every screen that moves Kaspa is the same steps as KaPay's (and the other KaChat apps'), built
from the shared pieces in `KaChatChess/Views/Shared/SendKaspaComponents.swift`, copied from
KaPay's file of the same name. Change those pieces, not one screen, and keep them in step with
KaPay's.

1. **To**: `SendStepScreen` + `SendStepQuestion` ("Who are you sending to?") + `SendRecipientCard`
   (address or name; Paste and Scan QR pills under the field).
   Cancel sits at the bottom beside Continue (`SendContinueButton`) on a first
   step; later steps have Back and Cancel in the header (`SendStepHeader`).
2. **From**: "Where are you sending from?" with the Chatting Address and Choose an Address pills.
   Chatting Address shows its card with the balance; Choose an Address lists every address right on
   the step (`OwnAddressList`: cards with Used / Unused and the balance, the picked one checked
   and outlined), and Continue waits for a pick. Skipped when the send's From is fixed
   (`lockedSource`: an address's own Send). Moves, joins, claims and bot stamps never come here:
   they always sign from the chatting address.
3. **Amount**: `KaspaKeypadAmountEntry`, the app's own number pad (`KaspaKeypad`,
   `KeypadAmountText`), so no system keyboard covers the screen; a "To" chip and a "From" chip,
   the KAS / currency switch and Max. The From address's balance (loaded by the screen's
   `.task(id: source)`) is the amount's Available. Continue says "Review".
4. **Review**: `SwipeUpToSendScrollView` with Back: "You're sending X KAS", To, From, Total.
   Nothing can change but the fee and coin control (`SendFeeControls`); a Max amount is worked
   out again when they change. Change too small to keep goes to the fee, so the Review's fee and
   Total count it (`SendFeeEstimate`, as in KaChat). The fee's Edit (`onEditFee`) opens `SendFeeEditorScreen` (the fee
   typed on the keypad, never under the network's minimum); Confirm goes back to the review.

Where each screen uses them: `WithdrawKaspaView` (`Views/Wallet/WalletViews.swift`) is the Wallet
tab's Send (the chatting address's own, From fixed: To → Amount → Review; the From step is only
in the unshown full wallet), a pasted payment request (its address and amount fixed) and Compound UTXOs, which opens on the
review. A pre-filled recipient opens on From. A spending address's Send and compound are
`SpendingAddressWithdrawView` (Manage Addresses). Coin Control greys out what a send can't spend
(`CoinControlView.hotWalletReason`: the chatting address's rule, or a spending address's, which can
spend a mature mining reward). Max puts the exact sompi in the field (`KaspaFiatAmountState.setMaxSompi`),
and typing after Max drops a Max answer still on its way.
Prices come from `KaspaPriceStore` (KaPay's pieces read `PortfolioViewModel`). A price over 30
minutes old is never used to turn a currency amount into KAS: the switch hides (on testnet always),
and send screens call `refreshIfStale()`. Your main address is the "Chatting Address", as in KaPay.

Sends, as in KaPay: a node's "sent" counts only if its id is the one computed here
(`NodePoolService.checkedSubmit`), and the same transaction is resent twice, 5 s apart, while the
network can't see it. Withdrawals, spending-address sends and KNS / .kachat combine commits never go
into a node's orphan pool (`escalateOrphan: false`); moves do. A submit that never left the phone
("Not connected to", "Circuit breaker open") isn't a lost answer. Withdrawals require the recipient
to be on the active network. KNS profile saves, domain transfers and coin combines go through the
send queue (`enqueueOutgoingTxOperation`) like moves. A .kas profile change files its 2 KAS commit
before sending (`KNSRevealRecovery`); its reveal is retried whenever the app becomes active until the
commit is spent (a commit never seen on chain is dropped after 30 days and two empty checks), and
saving the same change again finishes it instead of locking another 2 KAS. A domain transfer whose
commit is still in a mempool keeps its record and asks to try again. What a submitted
transaction spends is held 120 s, extended a minute at a time while it is still in a mempool, up to
10 minutes (`holdSpentWhileInMempool`); not a flat 10 minutes, since a dropped move must be playable
again and a .kachat commit is resent at 130 s. Coins carrying a covenant are never spent by plain
sends or moves.

Also ported from KaPay (2026-11-13): a mempool entry counts only if its id hashes to the one asked
for; "did it go out" ignores the orphan pool and the node that answered the submit, and after a
rejection needs two nodes or the built-in REST server. Coins are held from before a submit and given
back if it's rejected or never sent (unless the node says they're spent). Every send, estimate and
payment requires a valid address on the active network (`requireActiveNetworkRecipient`);
`KaspaAddress` refuses an unknown prefix, a wrong payload length or mixed case, and an all-upper-case
address (a compact QR's "KASPA:QR…") is lower-cased first (`lowercasedKaspaAddress`). The UTXO
subscription sends a stop on Log Out or an account switch and keeps retrying after a failover that
finds nothing. Only active, primary and standby node connections stay open and reconnect; probes
close afterwards, with least-recently-used eviction at 50. Active nodes must report the right network
and be at most 600 DAA behind the median. Keychain saves update in place and add only when missing,
so a failed write keeps the old copy. A .kachat claim follows whichever commit send landed, counts a
late register as registered, and declines open offers only once a transfer or release is in a block;
server-supplied times and counts are range-checked, never trapping. The bell's Received amount comes
from the REST transaction's outputs to the chatting address and must equal the node's own UTXO batch
for that transaction; nothing is shown when they disagree or it can't be read.

Errors reach people through `UserFacingError.message` (Models.swift): node-pool, connection, API and
builder failures map to translated sentences by their text, which stays English underneath for the
code that matches on it (`isNotSentError`, "Not confirmed").

Reinstalling keeps Keychain accounts but not UserDefaults: a launch with no `kaplay_has_launched_v1`
marker, no earlier app data and a saved wallet opens logged out, and the first saved-account sign-in
asks `DeviceAuth` even with Biometrics for Account Login off (`requiresDeviceAuthAfterReinstall`).
Importing doesn't scan spending addresses (`discoverSpendingAddresses` is kept for the full wallet).
KaChat message sync never runs (`ChatService.syncsChats` gates catch-up, fallback polling and the
unresolved-sender syncs); the fallback poll refreshes the balance instead.

The arena's 1 Hz clock is `ChessClock.shared.now`, observed only by clocks and countdowns;
`ChessTournamentService` keeps derived lists (`myActiveTournament`, `liveTournaments`,
`finishedTournaments`, `isBusyOnline` …) as cached values recomputed when tournaments, the account
or a time-based state (`timeRevision`) change, and the board is an `Equatable` view. The clock loop
pauses in the background and the 2 s fast poll runs only while active; both catch up on return.

## Build

The project uses a file-system-synchronized folder: every file under `KaChatChess/` is in the
target automatically.

```bash
xcodebuild -project KaChatChess.xcodeproj -scheme KaChatChess -configuration Debug -destination 'id=42E0A378-1265-4F60-AF20-4F7E4CAE6D4E' -derivedDataPath build/DerivedData build
```

Claude writes the code and never tests it - no Simulator driving, screenshots or verification
builds; the owner does all testing. "rebuild" (or "r") means build with the command above and
install + launch on the iPhone 17 simulator (`42E0A378-1265-4F60-AF20-4F7E4CAE6D4E`, not
the iPhone 17 Pro), then stop. "push" means commit and push to `main`
(`KaspaSilver/KaPlay-iPhone`).
