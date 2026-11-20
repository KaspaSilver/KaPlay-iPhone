import SwiftUI

/// The waiting room: shown full-screen from the moment a player joins a public 1v1 or
/// tournament room until it fills (then the game opens), their seat runs out, or they leave.
/// Nothing else in the app is reachable meanwhile - searching for players is the one thing
/// happening. Your avatar, a question mark for every empty seat (filled in as players arrive),
/// the time your seat is held for, and Leave behind a warning.
struct ChessWaitingRoomView: View {
    /// Why the room closed without a game, for the note the host shows.
    enum Exit {
        /// Left, lost the race for the last seat (the service joins the next room), or
        /// cancelled: nothing to say.
        case quiet
        /// The seat ran out with no one joining.
        case seatExpired
        /// The player's own join (or create) never reached the network and was dropped.
        case joinNotLanded
    }

    let tournamentId: String
    /// The room filled and the game exists: the host opens it and closes this screen.
    let onStarted: (String) -> Void
    /// Left, the seat ran out, or the join never landed: the host closes this screen (with a
    /// note for the last two).
    let onFinished: (Exit) -> Void

    @ObservedObject private var service = ChessTournamentService.shared
    /// This screen is a countdown (the seat's time, the match found): it redraws every second.
    @ObservedObject private var clock = ChessClock.shared
    @EnvironmentObject private var walletManager: WalletManager
    /// The code was copied: "Copied" shows for a moment (`copiedToken` keeps an older clear
    /// from wiping a newer copy's toast).
    @State private var showCopied = false
    @State private var copiedToken = 0
    @State private var showLeaveWarning = false
    @State private var isLeaving = false
    @State private var handedOff = false
    /// The reducer has shown this player in a seat here: only after that does "not seated"
    /// mean the seat ran out (or was given back), not "the join has not landed yet".
    @State private var wasSeated = false
    /// Leave went out: the room closes when the chain shows the seat given back - or opens the
    /// board, if the room filled first.
    @State private var leftByChoice = false
    @State private var appearedAt: Int64?
    /// When the seat seen here runs out (chain time): not seated before then means the seat was
    /// never really ours - the join was dropped - not that it ran out.
    @State private var seenSeatExpiry: Int64?
    /// A join that never shows up (ignored, or never mined) does not hold this screen forever.
    private static let seatWaitMs: Int64 = 30_000

    private var tournament: ChessTournament? { service.tournaments[tournamentId] }
    private var me: String? { walletManager.currentWallet?.publicAddress }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            // Scrolls when it doesn't fit (an iPhone SE, large text); centred when it does.
            GeometryReader { proxy in
                ScrollView {
                    roomContent
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
            }
            // One toast at a time: the copy's confirmation first, then the service's error.
            .toast(message: showCopied ? "Copied" : service.lastError, style: showCopied ? .success : .error)
            .safeAreaInset(edge: .bottom) { leaveButton }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showLeaveWarning) {
            leaveSheet
                .fittedSheetDetent(estimate: 300)
                .presentationDragIndicator(.visible)
        }
        .onAppear { service.acquire(); appearedAt = clock.now; check() }
        .onDisappear { service.release() }
        .onChange(of: tournament?.status) { _ in check() }
        .onChange(of: clock.now) { _ in check() }
    }

    @ViewBuilder
    private var roomContent: some View {
        VStack(spacing: 28) {
            if matchFound, let tournament {
                // The room filled. Everyone sees this for the same ten seconds of chain
                // time, then every phone opens the board together.
                Text(tournament.isDuel ? "Match found!" : "Tournament full!")
                    .font(.title.weight(.heavy))
                    .multilineTextAlignment(.center)
                seats
                VStack(spacing: 6) {
                    Text(verbatim: "\(matchFoundSecondsLeft)")
                        .font(.scaled(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.2), value: matchFoundSecondsLeft)
                    Text(tournament.isDuel ? "Taking both of you to the board" : "Taking everyone to their boards")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
            } else {
                Text(tournament?.isDuel == true ? "Looking for an opponent" : "Waiting for players")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                seats
                countdown
                if service.arenaServerDown {
                    ChessServerDownNote(text: "Chess server unreachable. Watching the network for players, so someone who joined while the app was away may not show.")
                        .padding(.horizontal, 32)
                }
                if let tournament, !tournament.isPublic {
                    privateCode(tournament)
                }
                Text(tournament?.isDuel == true
                     ? "You're paired with the next person who joins. The game starts by itself."
                     : "The tournament starts by itself when all eight seats are taken.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    /// Pinned under the content, which scrolls above it.
    private var leaveButton: some View {
        Button(role: .destructive) {
            showLeaveWarning = true
        } label: {
            Text(isLeaving || leftByChoice ? "Leaving…" : "Leave")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.red.opacity(0.12))
                .foregroundColor(.red)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(Color(.systemBackground))
        // No leaving once the room has filled - the game exists on chain.
        .opacity(matchFound ? 0 : 1)
        .disabled(matchFound || isLeaving || leftByChoice)
    }

    /// The half sheet behind Leave: what leaving means, then Leave or Keep waiting - the same
    /// shape as the Resign sheet on the board.
    private var leaveSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.walk.departure")
                .font(.scaled(size: 34))
                .foregroundColor(.red)
                .padding(.top, 28)
            Text("Leave the queue?")
                .font(.title3.weight(.bold))
            Text("Leaving means you will no longer be searching for another player. Leaving is one transaction; you can join again any time.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button {
                    guard !isLeaving, !handedOff else { return }
                    // No room on this phone (the join or create that made it was dropped):
                    // there's no seat to give back - just close.
                    guard let tournament else {
                        showLeaveWarning = false
                        handedOff = true
                        onFinished(.quiet)
                        return
                    }
                    isLeaving = true
                    showLeaveWarning = false
                    Task {
                        // Not closed here: a leave that failed (the error shows) keeps the
                        // player waiting, and one beaten by the last join is a game - `check`
                        // closes the room, or opens the board, by what the chain says.
                        if await service.leave(tournament) { leftByChoice = true }
                        isLeaving = false
                    }
                } label: {
                    Text(isLeaving ? "Leaving…" : "Leave")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                Button {
                    showLeaveWarning = false
                } label: {
                    Text("Keep waiting")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    /// Filled, or the seat ran out: hand the screen over. Runs on every tick.
    /// The room has filled and the match-found countdown is still running.
    private var matchFound: Bool {
        guard let tournament, let me, tournament.status == .live, tournament.players.contains(me) else { return false }
        return clock.now < (tournament.startedAt ?? 0) + ChessTournamentCodec.matchFoundDelayMs
    }

    private var matchFoundSecondsLeft: Int {
        guard let tournament else { return 0 }
        let left = (tournament.startedAt ?? 0) + ChessTournamentCodec.matchFoundDelayMs - clock.now
        return max(0, Int((left + 999) / 1000))
    }

    private func check() {
        guard !handedOff, let me else { return }
        let waited = clock.now - (appearedAt ?? clock.now) > Self.seatWaitMs
        guard let tournament else {
            // The room is on this phone only through this player's own create or first join,
            // and that row was dropped (it never reached the network): it is gone, and so is
            // the reason to hold this screen.
            if wasSeated || waited {
                handedOff = true
                onFinished(wasSeated ? .joinNotLanded : .quiet)
            }
            return
        }
        if tournament.status == .live || tournament.status == .finished {
            // Filled without us: our join lost the race for the last seat. Not a match - the
            // room closes, and the service joins the next room by itself.
            guard tournament.players.contains(me) else {
                handedOff = true
                onFinished(.quiet)
                return
            }
            // Filled: hold for the match-found countdown (chain time, the same on every phone),
            // then hand over to the board.
            guard !matchFound else { return }
            handedOff = true
            Haptics.success()
            onStarted(tournament.id)
        } else if tournament.status == .cancelled {
            handedOff = true
            onFinished(.quiet)
        } else if tournament.isSeated(me, at: clock.now) {
            wasSeated = true
            seenSeatExpiry = tournament.seatExpiry(of: me)
        } else if wasSeated || waited {
            handedOff = true
            if leftByChoice || !wasSeated {
                onFinished(.quiet)
            } else if let expiry = seenSeatExpiry, clock.now < expiry {
                // Out of the room while the seat still had time: the seat rested on a join the
                // network never took, and it was dropped.
                onFinished(.joinNotLanded)
            } else {
                onFinished(.seatExpired)
            }
        }
    }

    private var seats: some View {
        let capacity = tournament?.capacity ?? 2
        // You first, then the others who are here, then a question mark for each empty seat.
        var shown = tournament?.seatedPlayers(at: clock.now) ?? []
        if let me { shown = [me] + shown.filter { $0 != me } }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: capacity == 2 ? 2 : 4)
        return LazyVGrid(columns: columns, spacing: 18) {
            ForEach(shown, id: \.self) { address in
                seat(address: address, label: ContactsManager.shared.displayName(for: address))
            }
            ForEach(0..<max(0, capacity - shown.count), id: \.self) { _ in
                emptySeat
            }
        }
        .padding(.horizontal, 32)
    }

    private func seat(address: String, label: String) -> some View {
        VStack(spacing: 8) {
            KNSAvatarView(
                avatarURLString: KNSService.shared.profileCache[address]?.avatarURL,
                fallbackText: label,
                size: 64,
                contactAddress: address
            )
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
    }

    private var emptySeat: some View {
        VStack(spacing: 8) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .frame(width: 64, height: 64)
                .overlay(
                    Text("?")
                        .font(.scaled(size: 28, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                )
            Text("Waiting")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func privateCode(_ tournament: ChessTournament) -> some View {
        VStack(spacing: 6) {
            Text("Share this code")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Text(tournament.id)
                    .font(.title3.monospaced().weight(.semibold))
                Button {
                    UIPasteboard.general.string = tournament.id
                    Haptics.success()
                    copiedToken += 1
                    let token = copiedToken
                    withAnimation { showCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedToken == token { withAnimation { showCopied = false } }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel(Text("Copy"))
                ShareLink(item: ChessText.invite(for: tournament)) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    private var countdown: some View {
        let expiry = me.flatMap { tournament?.seatExpiry(of: $0) } ?? clock.now
        let left = max(0, Int((expiry - clock.now) / 1000))
        return VStack(spacing: 4) {
            Text(verbatim: String(format: "%d:%02d", left / 60, left % 60))
                .font(.scaled(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(left < 30 ? .red : .primary)
            Text("Your seat is held this long. If no one joins in time, you leave the queue.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
