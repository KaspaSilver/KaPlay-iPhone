import SwiftUI

/// Teal card matching the app's KNS domain branding - used both as the row style in
/// KNSDomainsListView and as the header of KNSDomainDetailView.
struct KNSDomainCard: View {
    let domain: KNSDomain
    var isPrimary: Bool = false

    var body: some View {
        DomainNameCardView(title: domain.fullName, badge: isPrimary ? String(localized: "Primary") : nil)
    }
}

/// The teal name card, for any name service: the name, and an optional corner badge
/// ("Primary" on KNS, "Settling" on a `.kaspa` name still inside its settling window).
struct DomainNameCardView: View {
    let title: String
    var badge: String? = nil
    /// A small line in the bottom-right corner (Your Domains > .kachat: when it expires).
    var footnote: String? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.accentColor)
                .frame(height: 100)
                .overlay(
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 20)
                )

            if let badge {
                Text(badge)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.35)))
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let footnote {
                Text(verbatim: footnote)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.black.opacity(0.65))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }
}
