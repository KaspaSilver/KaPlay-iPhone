# CLAUDE.md

Guidance for Claude Code in this repository.

## What KaPlay is

KaPlay (the folder, project, target and bundle `com.kachat.chess` still say KaChat Chess; only
what people read says KaPlay) is chess on Kaspa as its own iPhone app: every move is a Kaspa
transaction. What the app does and where it came from: [README.md](README.md). The protocol:
[ONLINE_CHESS.md](ONLINE_CHESS.md).

Tabs (`ChessMainTabView.Tab`): Play, Leaderboard, Wallet (`Views/Wallet/WalletViews.swift`),
Settings.

Every menu has its title fixed in the navigation bar. Where the bar also shows the balance, use
`ScreenTitleToolbarLabel`: a principal toolbar item replaces `navigationTitle`, so the balance
alone would leave the screen with no title.

## Bots and the Leaderboard tab

Bot games are free while played and stamped on chain once, when they end (`ChessBotGame`,
ONLINE_CHESS.md §7); online games stay on chain move by move. The Leaderboard tab has three squares
(`ChessLeaderboardSquare`): 1v1 and Tournaments switch the board under them, Bots opens
`ChessBotLeaderboardsView`, a board per played bot ranked by fewest moves to win
(`ChessBotLeaderboardService`). A stamped win can be shared to KaPost, and the post's Challenge
button opens KaPlay (`ChessBotLinks`, ONLINE_CHESS.md §7.2).

## Accounts

The same as KaPay's; keep them in step. Create New Account makes an account in one tap: 24 words,
no passphrase, the next free default name (`WalletManager.nextDefaultAccountName`). "Advanced:
Create with a Passphrase" (`CreateWalletView`) is the only other way: also 24 words, through
`PassphraseOptionView`, whose entry screen shows the address and its balance as you type. Import
still takes 12 or 24 words.

Creating never shows the seed phrase: an account made here is owed a backup
(`AccountBackupStatus`), and until the backup steps (`AccountBackupView`) are finished the Wallet
tab shows `AccountBackupCard` above Address Actions (red once the account holds funds), Receive
shows a reminder and the Delete Account warning leads with Back Up Account; deleting is never
blocked. Imported and older accounts are never owed one. Finishing the steps starts a six-month
timer; when it runs out the Wallet tab shows `BackupHygieneCard` in the same place, and
`BackupHygieneView` asks for five random words, then the passphrase if there is one.

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
