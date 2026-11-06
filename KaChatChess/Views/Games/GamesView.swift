import SwiftUI

/// The Play tab: a card per game. Chess is the only one so far; a new game is one more card here.
struct GamesView: View {
    @ObservedObject private var links = ChessBotLinkRouter.shared
    @State private var openChess = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    gameCard(
                        title: "Chess",
                        detail: "1v1, tournaments and five bots. Online moves and bot results go on Kaspa."
                    ) {
                        Image(uiImage: ChessTabIcon.image(side: 30))
                            .renderingMode(.template)
                            .foregroundColor(.white)
                    } open: {
                        openChess = true
                    }
                }
                .padding(.vertical, 16)
            }
            .fixedScreenTitle(Text("Play"), showsBackupBanner: true)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Play")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { ConnectionStatusIndicator() }
                ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
            }
            .navigationDestination(isPresented: $openChess) {
                ChessHomeView()
            }
            // A challenge from a KaPost is for chess: ChessHomeView takes it from the router.
            .onAppear {
                if links.challenge != nil { openChess = true }
            }
            .onChange(of: links.challenge) { challenge in
                if challenge != nil { openChess = true }
            }
        }
    }

    private func gameCard<Icon: View>(
        title: String,
        detail: String,
        @ViewBuilder icon: () -> Icon,
        open: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            open()
        } label: {
            HStack(spacing: 16) {
                icon()
                    .frame(width: 60, height: 60)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.bold))
                    Text(detail)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}
