import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// MARK: - Funding card

/// "Fund your chatting address": a QR of the chatting address and the address itself with a copy
/// affordance.
struct ZeroBalanceFundingCardView: View {
    let address: String?
    /// The headline; nil = "Fund your chatting address".
    var title: String? = nil
    /// Called after the address hits the pasteboard so the host can show its own toast; when
    /// nil (sheet contexts without a toast helper) the copy icon flips to a checkmark instead.
    var onCopied: ((String) -> Void)? = nil

    @State private var qrImage: UIImage?
    @State private var showCopiedCheckmark = false

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let title { Text(verbatim: title) } else { Text("Fund your chatting address") }
            }
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .padding(8)
                    // Solid white behind the QR keeps it scannable in dark mode, where the
                    // glass material alone would leave the light modules too dim.
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
            }

            if let address {
                HStack(spacing: 8) {
                    Text(address)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        UIPasteboard.general.string = address
                        Haptics.success()
                        if let onCopied {
                            onCopied(address)
                        } else {
                            showCopiedCheckmark = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                showCopiedCheckmark = false
                            }
                        }
                    } label: {
                        Image(systemName: showCopiedCheckmark ? "checkmark" : "doc.on.doc")
                            .font(.scaled(size: 14, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(6)
                            .background(cardGlassBackground(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Copy address"))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(cardGlassBackground(cornerRadius: 20))
        .task(id: address) {
            guard let address else {
                qrImage = nil
                return
            }
            qrImage = await Self.addressQRCode(from: address)
        }
    }

    /// The app's glass card treatment.
    private func cardGlassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }

    /// Plain string payload, so any wallet/scanner reads the address directly. Cached per string,
    /// drawn with one shared CIContext (making one per QR is the slow part).
    nonisolated static func makeAddressQRCode(from string: String) -> UIImage? {
        if let cached = qrCache.object(forKey: string as NSString) { return cached }
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = qrContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = UIImage(cgImage: cgImage)
        qrCache.setObject(image, forKey: string as NSString)
        return image
    }

    /// `makeAddressQRCode` off the main thread: a cached QR comes back at once, a new one is drawn
    /// in the background so opening Receive never stalls a frame.
    static func addressQRCode(from string: String) async -> UIImage? {
        if let cached = qrCache.object(forKey: string as NSString) { return cached }
        return await Task.detached(priority: .userInitiated) {
            makeAddressQRCode(from: string)
        }.value
    }

    /// CIContext and NSCache are both safe to use from any thread.
    nonisolated(unsafe) private static let qrContext = CIContext(options: [.useSoftwareRenderer: false])
    nonisolated(unsafe) private static let qrCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 32
        return cache
    }()
}

/// Sheet host for the funding card: the "not enough funds" popup of a .kachat profile save.
/// Auto-dismisses the moment the main balance reaches `dismissAtSompi` (any KAS by default).
struct ZeroBalanceFundingSheetView: View {
    var title: String? = nil
    var dismissAtSompi: UInt64 = 1
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var walletManager = WalletManager.shared

    var body: some View {
        ScrollView {
            ZeroBalanceFundingCardView(address: walletManager.currentWallet?.publicAddress, title: title)
            .padding(.horizontal)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: walletManager.currentWallet?.balanceSompi) { balance in
            if let balance, balance >= dismissAtSompi { dismiss() }
        }
    }
}
