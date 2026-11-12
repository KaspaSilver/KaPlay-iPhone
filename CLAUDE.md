# CLAUDE.md

Guidance for Claude Code in this repository.

## What KaPlay is

KaPlay (the folder, project, target and bundle `com.kachat.chess` still say KaChat Chess; only
what people read says KaPlay) is chess on Kaspa as its own iPhone app: every move is a Kaspa
transaction. What the app does and where it came from: [README.md](README.md). The protocol:
[ONLINE_CHESS.md](ONLINE_CHESS.md).

Tabs (`ChessMainTabView.Tab`): Play, Leaderboard, Wallet (`Views/Wallet/WalletViews.swift`),
Settings. Play opens on `GamesView`, a card per game; Chess is the only one so far and opens
`ChessHomeView`. A new game is one more card there.

The Wallet tab (`ChessWalletView`, `Views/Wallet/WalletViews.swift`) is KaPay's Wallet tab
(`ProfileView` there; every app has KaPay's full wallet, owner's call 2026-11-07), in KaPlay's look:
the fixed title with the backup banner, `BalanceToolbarLabel` (the chatting address) in the bar,
`ConnectionStatusIndicator` left and the bell right. The total balance split into Chatting and
Spending (`WalletBalanceCard`, the spending part from `HotWalletBalance`), Send, Receive (a fresh
address, `ReceiveKaspaQRView`) and Request (`CreatePaymentRequestView`, `Views/Shared/PaymentRequestViews.swift`:
Fresh Address or Choose an Address), Backup Hygiene when due, the Manage Addresses square
(`Views/Wallet/ManageAddressesView.swift`: spending addresses numbered from #1 with
`WalletManager.addressNumber`, Discover Addresses, Address Visibility, each address's history,
UTXOs, Domains, Send, compound and private key; its Chatting Address row opens
`ChattingAddressManageView`, with `AddressOptionsButton` top right opening `AddressActionsSheet` for the keys and explorer, as every single-address page has, and Compound under UTXOs)
and the Chatting Address square (its QR), then Your Domains (`KNSDomainsListView`: .kachat, .kas,
.k, .kaspa; a .kas domain's detail has Set as Primary, Customize Profile (`KNSProfileEditorSheet`)
and Send (`KNSDomainSendView`); .kachat names open `KachatLiveNameDetail`, `Views/Ecosystem/`),
and Help (`ProfileHelpView`, the .kachat names guide). Left out from KaPay: Portfolio, Cold Storage,
the .kachat marketplace (so Your Domains > .kachat has no Inscribe, a name's detail has no Buy,
Offer or List for Sale, and transactions open the explorer with no Add to Portfolio) and Contacts (owner's call, 2026-11-07: someone who wants saved
contacts uses KaChat or KaPay, so KaPlay has no Address Book, Contacts pill or contact photos).

Account removal clears what the app keeps per account, on both networks' addresses: the bell and
what it compares against, .kachat reminders and saved names, the balance cache, added date, address
choice and bot games (`WalletManager.removeWalletTabData`), and the spending data. The bell (`GlobalNotificationCenter`) lists .kachat news
(`KachatNamesNotifier`) and Kaspa received on the chatting address from someone else
(`WalletReceiptNotifier`, fed each live UTXO batch; KaPlay's subscription is the chatting address
only, so spending addresses get no Received rows). A row opens the address
(`OwnAddressHistorySheet`) or the name.

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
ONLINE_CHESS.md §7); online games stay on chain move by move. The Leaderboard tab has three squares
(`ChessLeaderboardSquare`), each opening its own page: 1v1 and Tournaments their board
(`ChessLeaderboardPage`), Bots `ChessBotLeaderboardsView`, a board per played bot ranked by fewest
moves to win (`ChessBotLeaderboardService`). A stamped win can be shared to KaPost, and the post's Challenge
button opens KaPlay (`ChessBotLinks`, ONLINE_CHESS.md §7.2).

Online moves, joins, claims and bot stamps never wait in a silent background retry
(`PublicChatService.sendPublicChat(deferNoInputRetry: false)`): no coins on the chatting address says
"Not enough KAS on your Chatting Address", and only "change not mined yet" is retried, a few times.
A move, join or claim the chain never shows is looked up after 60 s and dropped if it didn't land,
so it can be played again. A timeout claim that doesn't take is retried automatically at most 4
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
needs a read of the chain newer than the flag (`flagIsConfirmed`). When it's back the arena is paged
in again and the indexer's block times replace the stream's.

The .kachat registry has its own outage rule: it moves to the chain after 3 failed indexer requests
within 2 minutes, failures under 5 s apart counting as one (`KachatNamesRegistry.indexerOutageConfirmed`).
A .kachat name resolved to an address always has its record checked live on chain
(`confirmOnChain`), and the chain copy only answers while its last full check is under 3 minutes old
(`chainCopyIsCurrent`).

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
Delete Account stops polling and the UTXO subscription first and removes the keys next; only once
they're gone does the per-account data go, so a failed delete leaves the account signed in and whole.

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
Below them Delete Account (`DeleteAccountSheet`, the warning the sign-in screen's Delete also shows)
and Log Out, which KaChat keeps on Profile and KaPlay has no Profile for. Every sign-in gets new tabs
(`ContentView`'s `signInSession`), opening on Play. Biometrics for Account Login is off by default,
and existing installs were switched off once (`AppSettings.accountLoginBiometricsOffMigration`).

Face ID, as in KaChat: `SwipeUpToSendScrollView` asks `DeviceAuth` before every send (declined, the
screen settles back filled in), and both Delete Account sheets ask too. Chess moves don't ask. A
send a node may have taken without answering ends on "Not confirmed" with only Done
(`SendOutcomeUnknownError`), never Try Again, which could pay twice.

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
tab's Send (To → From → Amount → Review), the chatting address's own Send (From fixed), a pasted payment request (its address and amount fixed) and Compound UTXOs, which opens on the
review. A pre-filled recipient opens on From. A spending address's Send and compound are
`SpendingAddressWithdrawView` (Manage Addresses). Coin Control greys out what a send can't spend
(`CoinControlView.hotWalletReason`: the chatting address's rule, or a spending address's, which can
spend a mature mining reward). The .kachat transactions are `KachatTxSheet` (swipe up with its own
Face ID reason, `authReason`).
Prices come from `KaspaPriceStore` (KaPay's pieces read `PortfolioViewModel`). Your main address
is the "Chatting Address", as in KaPay.

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
