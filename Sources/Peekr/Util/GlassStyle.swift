import AppKit
import SwiftUI

/// Peekr's visual language: aqua→blue "liquid" accent, rounded geometry, and a
/// single `liquidGlass` entry point that uses the real macOS 26 Liquid Glass
/// material where available and falls back to a tasteful material below it.
enum Theme {
    // Monochrome / shadcn: the accent IS the foreground (near-black in light,
    // near-white in dark). No colour — restraint and contrast carry the design.
    static let accent = Color.primary
    static let accentDeep = Color.primary

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [Color.primary, Color.primary.opacity(0.62)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Hairline border tuned for shadcn-style surfaces.
    static let hairline = Color.primary.opacity(0.12)

    static let railWidth: CGFloat = 64
    /// Left tab sidebar (icon + name list), wider than the old icon-only rail.
    static let sidebarWidth: CGFloat = 208
    static let tile: CGFloat = 44
    static let iconCorner: CGFloat = 10
    static let panelCorner: CGFloat = 18
    static let tileCorner: CGFloat = 12
    /// Corner of the inset web "card" (between the rail-tile and panel radii).
    static let webCardCorner: CGFloat = 14
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

/// The panel window's whole-background material, as an AppKit view layered
/// behind the SwiftUI content. Real Liquid Glass (`NSGlassEffectView`) on
/// macOS 26+, a frosted `NSVisualEffectView` below — the AppKit counterpart to
/// `liquidGlass`, so glass selection still lives in exactly one place.
@MainActor
func makePanelBackdrop(cornerRadius: CGFloat) -> NSView {
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        return glass
    }
    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    return effect
}

/// Icon button with native hover/press feedback: a faint circular fill that
/// deepens on press, plus a slight depress — the feedback `.plain` strips away.
/// Shared by the nav-bar buttons and the sidebar's workspace controls.
struct IconButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle().fill(.primary.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.08 : 0)))
            }
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
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
