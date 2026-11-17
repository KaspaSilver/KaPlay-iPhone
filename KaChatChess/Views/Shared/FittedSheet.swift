import SwiftUI

/// The height a fitted sheet's content measured itself at.
private struct FittedSheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A half sheet as tall as its content, rather than a fixed `.height(...)` that clips the bottom
/// button on an iPhone SE, with larger text or in a longer language. The content sits in a
/// scroll view, so if it is taller than the screen allows the sheet stops at full height and
/// the rest scrolls instead of being cut off.
private struct FittedSheetDetent: ViewModifier {
    /// Used until the content has been measured (the first layout pass).
    let estimate: CGFloat
    @State private var measured: CGFloat = 0

    func body(content: Content) -> some View {
        ScrollView {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: FittedSheetHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .modifier(BounceOnlyWhenScrollable())
        .onPreferenceChange(FittedSheetHeightKey.self) { height in
            if height > 0, abs(height - measured) > 0.5 { measured = height }
        }
        .presentationDetents([.height(measured > 0 ? measured : estimate)])
    }
}

/// Short content shouldn't rubber-band; iOS 16.0-16.3 have no switch for it and just bounce.
private struct BounceOnlyWhenScrollable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
    }
}

extension View {
    /// Presents this sheet's content at its own measured height (see `FittedSheetDetent`).
    /// Apply it in place of `.presentationDetents([.height(...)])`; `estimate` is only the first
    /// frame's height.
    func fittedSheetDetent(estimate: CGFloat = 280) -> some View {
        modifier(FittedSheetDetent(estimate: estimate))
    }
}
