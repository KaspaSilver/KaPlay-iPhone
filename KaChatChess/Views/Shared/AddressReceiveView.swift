import SwiftUI
import UIKit

/// One line under a receive screen's address, or in its notes card: an icon in a colour, and the
/// text (already localized).
struct ReceiveNote: Identifiable {
    enum Kind { case allowed, warning, info, privateAddress, publicAddress, quantum }
    let kind: Kind
    let text: String
    var id: String { text }

    var icon: String {
        switch kind {
        case .allowed: return "checkmark.circle.fill"
        case .warning: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        case .privateAddress: return "eye.slash.fill"
        case .publicAddress: return "person.crop.circle.fill"
        case .quantum: return "shield.fill"
        }
    }

    var color: Color {
        switch kind {
        case .allowed, .privateAddress: return .green
        case .warning: return .red
        case .info: return .secondary
        case .publicAddress: return .orange
        case .quantum: return .accentColor
        }
    }
}

/// KaPay's receive screen (owner's design, 2026-11-19, from kUSDT's; KaPlay's since 2026-11-20): the coin's icon and
/// "Receive …", optional choices (Fresh / Chatting), the address's name, its QR on a white card,
/// the whole address, what it means for privacy, then what may be sent to it. A tap anywhere copies
/// the address (no Copy or Share buttons). No navigation container of its own: the screen that
/// shows it adds Done or Close.
struct AddressReceiveView<Icon: View, Choices: View>: View {
    let title: String
    let address: String
    /// "Address #4", "Chatting Address", a Cold Storage label.
    var addressLabel: String? = nil
    /// Under the name: the address's balance, where the screen shows one.
    var balanceLine: String? = nil
    var privacyNote: ReceiveNote? = nil
    var notes: [ReceiveNote] = []
    /// The address was copied: handed out (a fresh one goes on the list).
    var onHandedOut: () -> Void = {}
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let choices: () -> Choices

    @State private var qrImage: UIImage?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 10) {
                    icon()
                    Text(verbatim: title)
                        .font(.title3.weight(.bold))
                }
                .padding(.top, 8)

                choices()

                if addressLabel != nil || balanceLine != nil {
                    VStack(spacing: 2) {
                        if let addressLabel {
                            Text(verbatim: addressLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        if let balanceLine {
                            Text(verbatim: balanceLine)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                Group {
                    if let qrImage, !address.isEmpty {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 240, height: 240)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white))

                VStack(spacing: 6) {
                    Text(verbatim: address)
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        // the whole address, always: it wraps rather than truncates
                        .fixedSize(horizontal: false, vertical: true)
                    if let privacyNote {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: privacyNote.icon)
                                .foregroundColor(privacyNote.color)
                            Text(verbatim: privacyNote.text)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 8)

                Text("Tap anywhere to copy")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(notes) { note in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: note.icon)
                                    .foregroundColor(note.color)
                                Text(verbatim: note.text)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sendKaspaGlass(cornerRadius: 18))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            // the whole screen copies; the choice pills are buttons and still switch
            .contentShape(Rectangle())
            .onTapGesture { copy() }
        }
        .toast(message: toastMessage)
        .task(id: address) {
            // drawn off the main thread (and cached), then shown
            guard !address.isEmpty else { qrImage = nil; return }
            let image = await ZeroBalanceFundingCardView.addressQRCode(from: address)
            if !Task.isCancelled { qrImage = image }
        }
    }
}

extension AddressReceiveView {
    fileprivate func copy() {
        guard !address.isEmpty else { return }
        UIPasteboard.general.string = address
        Haptics.success()
        onHandedOut()
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) { toastMessage = address.addressCopiedToastText }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) { toastMessage = nil }
            }
        }
    }
}

extension AddressReceiveView where Choices == EmptyView {
    init(title: String, address: String, addressLabel: String? = nil, balanceLine: String? = nil,
         privacyNote: ReceiveNote? = nil, notes: [ReceiveNote] = [], onHandedOut: @escaping () -> Void = {},
         @ViewBuilder icon: @escaping () -> Icon) {
        self.init(title: title, address: address, addressLabel: addressLabel, balanceLine: balanceLine,
                  privacyNote: privacyNote, notes: notes, onHandedOut: onHandedOut, icon: icon, choices: { EmptyView() })
    }
}

/// The round Kaspa logo, sized for a receive screen's title.
struct KaspaLogoIcon: View {
    var size: CGFloat = 34

    var body: some View {
        Image("KaspaLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

/// The notes KaPlay's receive screen shares with KaPay's, worded once.
enum ReceiveNotes {
    static var chattingAddress: ReceiveNote {
        ReceiveNote(kind: .publicAddress, text: AppLocalization.string("Your Chatting Address shows your .kachat name and identity: whoever pays here can see it's you."))
    }
    static var kaspaAndKusdt: ReceiveNote {
        ReceiveNote(kind: .allowed, text: AppLocalization.string("Kaspa, and kUSDT on Kaspa, can be sent here."))
    }
}

extension KaspaUnit {
    /// "1,234.5 KAS": `amount`, with the thousands grouped the way this phone writes them (KaPay's).
    @MainActor static func groupedAmount(_ sompi: UInt64) -> String {
        "\(KaspaAmountEntry.grouped(plain(sompi))) \(symbol)"
    }
}
