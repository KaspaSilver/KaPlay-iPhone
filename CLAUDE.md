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
(`PassphraseAddressPreview`). Import still takes 12 or 24 words; with a passphrase it checks the
first 50 identity addresses, picks the first with funds, lists any others to choose from, and
imports onto the chosen one (`WalletManager.findChattingAddresses`).

Creating never shows the seed phrase: an account made here is owed a backup
(`AccountBackupStatus`), and until the backup steps (`AccountBackupView`) are finished the Wallet
tab shows `AccountBackupCard` above Address Actions (red once the account holds funds), its dock
icon has a yellow dot (`ChessMainTabView.owesBackup`, Backup Hygiene too), Receive shows a reminder and the Delete Account warning leads with Back Up Account; deleting is never
blocked. Imported and older accounts are never owed one. Finishing the steps or importing, by
typing the words or from a card, starts a six-month timer, and a changed chatting address keeps the
status (`AccountBackupStatus.moveStatus`). When it runs out the Wallet tab shows `BackupHygieneCard`
in the same place, and `BackupHygieneView` asks for five random words, then the passphrase if there
is one.

**NFC card backup** (`Services/NFCCard.swift`, beta only: `NFCCard.isAvailable`, hidden once
`KACHAT_IS_RELEASE` is YES and where NFC can't read): an extra copy of the words of a seed phrase
the user already has, on a Java Card loaded with
[KaChat-NFC](https://github.com/KaspaSilver/KaChat-NFC) through Kaspa Quick Start's NFC Card page.
Not cold storage: the card never generates or uses a key. The same as KaPay's and KaChat's; the card
commands and backup format are that repo's `docs/PROTOCOL.md`, so change them there first. Settings
> Back Up to NFC Card (`NFCCardBackupView`, behind the seed phrase's biometric gate) only exists for
an account with a passphrase, which is what protects it: it's never written to the card. The Import
chooser's Restore from NFC Card (`NFCCardRestoreView`) reads with the 6-digit PIN, asks for the
passphrase and checks it against the saved chatting address. Saving to a card never clears the
backup card. Before an App Store submission without this feature, remove the NFC entitlement in
`KaChatChess.entitlements` and `KaChatChessRelease.entitlements` and the NFC keys in `Info.plist`.
The App ID needs Near Field Communication Tag Reading on.

Settings' Account section ends with Delete Account (`DeleteAccountSheet`, the warning the sign-in
screen's Delete also shows) and Log Out. Every sign-in gets new tabs (`ContentView`'s
`signInSession`), opening on Play.

## Send Kaspa

Every screen that moves Kaspa is the same steps as KaPay's (and the other KaChat apps'), built
from the shared pieces in `KaChatChess/Views/Shared/SendKaspaComponents.swift`, copied from
KaPay's file of the same name. Change those pieces, not one screen, and keep them in step with
KaPay's.

1. **To**: `SendStepScreen` + `SendStepQuestion` ("Who are you sending to?") + `SendRecipientCard`
   (address or name; Paste and Scan QR pills under the field - no Addresses pill, KaPlay has no
   Address Book). Cancel sits at the bottom beside Continue (`SendContinueButton`) on a first
   step; later steps have Back and Cancel in the header (`SendStepHeader`).
2. **From**: "Where are you sending from?" with the Chatting Address and Choose an Address pills.
   Chatting Address shows its card with the balance; Choose an Address lists every address right on
   the step (`OwnAddressList`: cards with Used / Unused and the balance, the picked one checked
   and outlined), and Continue waits for a pick. Skipped when the send's From is fixed
   (`lockedSource`).
3. **Amount**: `KaspaKeypadAmountEntry`, the app's own number pad (`KaspaKeypad`,
   `KeypadAmountText`), so no system keyboard covers the screen; a "To" chip and a "From" chip,
   the KAS / currency switch and Max. The From address's balance (loaded by the screen's
   `.task(id: source)`) is the amount's Available. Continue says "Review".
4. **Review**: `SwipeUpToSendScrollView` with Back: "You're sending X KAS", To, From, Total.
   Nothing can change but the fee and coin control (`SendFeeControls`); a Max amount is worked
   out again when they change. The fee's Edit (`onEditFee`) opens `SendFeeEditorScreen` (the fee
   typed on the keypad, never under the network's minimum); Confirm goes back to the review.

The only send screen is `WithdrawKaspaView` (`Views/Wallet/WalletViews.swift`): the Wallet tab's
Send, and Compound UTXOs, which opens on the review. A pre-filled recipient opens on From. The
Wallet tab's Send is locked to the Chatting Address (`lockedSource: .chatting`: the Wallet is the one
address every move is signed by), so it goes To → Amount → Review.
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
