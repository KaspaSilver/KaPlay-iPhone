import SwiftUI

/// The line a chess screen shows while the chess server isn't answering: what's on screen may be
/// behind, and says so.
struct ChessServerDownNote: View {
    var text: LocalizedStringKey = "Chess server unreachable, showing what we have. Your games keep going from the network. Public rooms can be joined again when it's back."

    var body: some View {
        Label(text, systemImage: "exclamationmark.icloud")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Board pieces shared with KaChat's 1:1 chat chess, which KaChat Chess does not have: the
// glyphs and the small board (from MessageBubbleView.swift) and the waiting overlay (from
// ChessGameView.swift).

struct ChessBoardThumbnail: View {
    let board: ChessBoard
    var size: CGFloat = 160

    /// Classic wood-tone board colors (matches chess.com/lichess's default theme) - shared with
    /// the full-screen board in ChessGameView.
    static let lightSquareColor = Color(red: 0.937, green: 0.851, blue: 0.706) // #EFD9B4
    static let darkSquareColor = Color(red: 0.710, green: 0.533, blue: 0.388)  // #B58863

    var body: some View {
        let squareSize = size / 8
        VStack(spacing: 0) {
            ForEach((0..<8).reversed(), id: \.self) { rank in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { file in
                        let isLight = !(file + rank).isMultiple(of: 2)
                        ZStack {
                            Rectangle().fill(isLight ? Self.lightSquareColor : Self.darkSquareColor)
                            if let piece = board.piece(at: ChessSquare(file: file, rank: rank)) {
                                ChessPieceGlyphView(piece: piece, fontSize: squareSize * 0.72)
                            }
                        }
                        .frame(width: squareSize, height: squareSize)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Renders a single chess piece glyph with an explicit white/black fill plus a crisp
/// contrasting outline (four offset copies of the glyph drawn behind the fill, a standard
/// lightweight text-stroke trick), rather than relying on the bare Unicode glyph's
/// outline-vs-filled shape alone to distinguish sides - at typical board sizes that distinction
/// was too subtle to read at a glance, especially on a same-toned square.
struct ChessPieceGlyphView: View {
    let piece: ChessPiece
    var fontSize: CGFloat

    private var fillColor: Color { piece.color == .white ? Color(white: 0.99) : Color(white: 0.07) }
    private var outlineColor: Color { piece.color == .white ? Color(white: 0.07) : Color(white: 0.99) }

    private static let outlineOffsets: [CGSize] = {
        let d: CGFloat = 0.9
        return [CGSize(width: d, height: 0), CGSize(width: -d, height: 0), CGSize(width: 0, height: d), CGSize(width: 0, height: -d)]
    }()

    private var glyphText: some View {
        Text(piece.glyph)
            .font(.scaled(size: fontSize))
            .minimumScaleFactor(0.5)
    }

    var body: some View {
        ZStack {
            ForEach(0..<Self.outlineOffsets.count, id: \.self) { index in
                glyphText
                    .foregroundColor(outlineColor)
                    .offset(Self.outlineOffsets[index])
            }
            glyphText
                .foregroundColor(fillColor)
        }
    }
}

/// Overlay shown on the board while waiting for the opponent's move - the "..." cycles 1/2/3 dots
/// like a typing indicator rather than sitting static, so it reads as "still waiting" rather than
/// looking frozen/stuck. Self-contained `.task` loop starts/stops automatically as SwiftUI mounts/
/// unmounts this view (see `boardView`'s conditional inclusion), so nothing leaks a timer while
/// it isn't actually the opponent's turn.
/// Shared with the tournament board (`ChessTournamentGameView`), which waits the same way.
struct WaitingOnOpponentOverlay: View {
    @State private var dotCount = 1

    var body: some View {
        Text("Waiting on opponent" + String(repeating: ".", count: dotCount))
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    dotCount = dotCount % 3 + 1
                }
            }
    }
}
