import SwiftUI

/// Peekr's visual language: aqua→blue "liquid" accent, rounded geometry, and a
/// single `liquidGlass` entry point that uses the real macOS 26 Liquid Glass
/// material where available and falls back to a tasteful material below it.
enum Theme {
    static let accent = Color(red: 0.16, green: 0.80, blue: 0.88)   // aqua
    static let accentDeep = Color(red: 0.18, green: 0.50, blue: 0.98) // blue

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let railWidth: CGFloat = 70
    static let tile: CGFloat = 46
    static let panelCorner: CGFloat = 20
    static let tileCorner: CGFloat = 13
}

@available(macOS 26.0, *)
private func peekrGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

extension View {
    /// Liquid Glass material clipped to `shape`. Real glass on Tahoe (26+),
    /// `.ultraThinMaterial` with a hairline below.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(peekrGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
    }
}

/// Groups glass elements so they share one sampling region and can morph.
/// No-op container below macOS 26.
@ViewBuilder
func GlassGroup<Content: View>(
    spacing: CGFloat = 22,
    @ViewBuilder content: () -> Content
) -> some View {
    if #available(macOS 26.0, *) {
        GlassEffectContainer(spacing: spacing) { content() }
    } else {
        content()
    }
}
