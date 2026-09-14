import SwiftUI

/// Removes the system focus effect without drawing anything in its place.
/// Used for controls that sit on their own colored or filled surface
/// (group headers, rows, bordered fields), where focus chrome would
/// compete with the background.
struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        content.focusEffectDisabled()
    }
}

/// A quiet, shadcn-style focus treatment for plain inputs that have no
/// background of their own: a soft, low-opacity ring outside the bounds
/// that reads as a shadow rather than a hard stroke.
struct ShadcnFocusRing: ViewModifier {
    let isFocused: Bool
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .focusEffectDisabled()
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                    .stroke(.primary.opacity(isFocused ? 0.2 : 0), lineWidth: 2.5)
                    .padding(-2.5)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func noFocusRing() -> some View {
        modifier(NoFocusRing())
    }

    func shadcnFocusRing(_ isFocused: Bool, cornerRadius: CGFloat = 8) -> some View {
        modifier(ShadcnFocusRing(isFocused: isFocused, cornerRadius: cornerRadius))
    }
}
