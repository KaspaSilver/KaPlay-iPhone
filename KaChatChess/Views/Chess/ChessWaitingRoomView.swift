import SwiftUI

/// The waiting room: shown full-screen from the moment a player joins a public 1v1 or
/// tournament room until it fills (then the game opens), their seat runs out, or they leave.
/// Nothing else in the app is reachable meanwhile - searching for players is the one thing
/// happening. Your avatar, a question mark for every empty seat (filled in as players arrive),
/// the time your seat is held for, and Leave behind a warning.
struct ChessWaitingRoomView: View {
    let tournamentId: String
    /// The room filled and the game exists: the host opens it and closes this screen.
    let onStarted: (String) -> Void
    /// Left, or the seat ran out: the host closes this screen (with a note when it ran out).
    let onFinished: (_ seatExpired: Bool) -> Void

    @ObservedObject private var service = ChessTournamentService.shared
    @EnvironmentObject private var walletManager: WalletManager
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
    /// A join that never shows up (ignored, or never mined) does not hold this screen forever.
    private static let seatWaitMs: Int64 = 30_000

    private var tournament: ChessTournament? { service.tournaments[tournamentId] }
    private var me: String? { walletManager.currentWallet?.publicAddress }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                if matchFound, let tournament {
                    // The room filled. Everyone sees this for the same ten seconds of chain
                    // time, then every phone opens the board together.
                    Text(tournament.isDuel ? "Match found!" : "Tournament full!")
                        .font(.title.weight(.heavy))
                    seats
                    VStack(spacing: 6) {
                        Text("\(matchFoundSecondsLeft)")
                            .font(.scaled(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.2), value: matchFoundSecondsLeft)
                        Text(tournament.isDuel ? "Taking both of you to the board" : "Taking everyone to their boards")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                Text(tournament?.isDuel == true ? "Looking for an opponent" : "Waiting for players")
                    .font(.title2.weight(.bold))
                seats
                countdown
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
                Spacer()
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
                .padding(.bottom, 24)
                // No leaving once the room has filled - the game exists on chain.
                .opacity(matchFound ? 0 : 1)
                .disabled(matchFound || isLeaving || leftByChoice)
            }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showLeaveWarning) {
            leaveSheet
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
        .onAppear { service.acquire(); appearedAt = service.now; check() }
        .onDisappear { service.release() }
        .onChange(of: tournament?.status) { _ in check() }
        .onChange(of: service.now) { _ in check() }
        .toast(message: service.lastError, style: .error)
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
                    guard let tournament, !isLeaving else { return }
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
        guard let tournament, tournament.status == .live else { return false }
        return service.now < (tournament.startedAt ?? 0) + ChessTournamentCodec.matchFoundDelayMs
    }

    private var matchFoundSecondsLeft: Int {
        guard let tournament else { return 0 }
        let left = (tournament.startedAt ?? 0) + ChessTournamentCodec.matchFoundDelayMs - service.now
        return max(0, Int((left + 999) / 1000))
    }

    private func check() {
        guard !handedOff, let tournament, let me else { return }
        if tournament.status == .live || tournament.status == .finished {
            // Filled: hold for the match-found countdown (chain time, the same on every phone),
            // then hand over to the board.
            guard !matchFound else { return }
            handedOff = true
            Haptics.success()
            onStarted(tournament.id)
        } else if tournament.status == .cancelled {
            handedOff = true
            onFinished(false)
        } else if tournament.isSeated(me, at: service.now) {
            wasSeated = true
        } else if wasSeated || service.now - (appearedAt ?? service.now) > Self.seatWaitMs {
            handedOff = true
            onFinished(wasSeated && !leftByChoice)
        }
    }

    private var seats: some View {
        let capacity = tournament?.capacity ?? 2
        // You first, then the others who are here, then a question mark for each empty seat.
        var shown = tournament?.seatedPlayers(at: service.now) ?? []
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
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                ShareLink(item: "Play me at chess in KaPlay: open Play > \(tournament.isDuel ? "1v1" : "Tournaments") > Join with a code, and enter \(tournament.id)") {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    private var countdown: some View {
        let expiry = me.flatMap { tournament?.seatExpiry(of: $0) } ?? service.now
        let left = max(0, Int((expiry - service.now) / 1000))
        return VStack(spacing: 4) {
            Text(String(format: "%d:%02d", left / 60, left % 60))
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
