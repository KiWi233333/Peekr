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

// `Glass`/`glassEffect`/`NSGlassEffectView`/`GlassEffectContainer` only exist in
// the macOS 26 SDK (Xcode 26 = Swift 6.2). `@available` is a *runtime* guard and
// can't hide a missing type from an older SDK, so the macOS-26 code paths are
// also fenced behind `#if compiler(>=6.2)` — that's what lets Peekr still
// compile on Xcode 16 / macOS 15, falling back to the material everywhere.
#if compiler(>=6.2)
@available(macOS 26.0, *)
private func peekrGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
#endif

extension View {
    /// Liquid Glass material clipped to `shape`. Real glass on Tahoe (26+),
    /// `.ultraThinMaterial` with a hairline below (and when built pre-Xcode 26).
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(peekrGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            fallbackGlass(in: shape, tint: tint)
        }
        #else
        fallbackGlass(in: shape, tint: tint)
        #endif
    }

    /// Frosted-material substitute used below macOS 26 or when built with an
    /// older SDK that has no Liquid Glass.
    @ViewBuilder
    private func fallbackGlass<S: Shape>(in shape: S, tint: Color?) -> some View {
        self
            .background { FallbackGlassSurface(shape: shape, tint: tint) }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

/// Pre-Tahoe material that follows the same accessibility contract as system
/// Liquid Glass: Reduce Transparency becomes opaque, and Increased Contrast
/// strengthens the adaptive (light/dark) edge instead of forcing white.
private struct FallbackGlassSurface<S: Shape>: View {
    let shape: S
    let tint: Color?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else {
                shape.fill(.ultraThinMaterial)
            }
            if let tint { shape.fill(tint) }
            shape.stroke(
                .primary.opacity(contrast == .increased ? 0.32 : 0.14),
                lineWidth: contrast == .increased ? 1 : 0.8
            )
        }
    }
}

/// The panel window's whole-background material and content container. Apple
/// requires content to be assigned to `NSGlassEffectView.contentView` so the
/// system can adapt both glass and foreground legibility together; placing a
/// glass view behind its content as a sibling defeats those treatments.
@MainActor
func makePanelBackdrop(contentView: NSView, cornerRadius: CGFloat) -> NSView {
    #if compiler(>=6.2)
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = contentView
        return glass
    }
    #endif
    let effect = NSVisualEffectView()
    effect.frame = contentView.frame
    effect.material = .sidebar
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = cornerRadius
    effect.layer?.masksToBounds = true
    contentView.frame = effect.bounds
    contentView.autoresizingMask = [.width, .height]
    effect.addSubview(contentView)
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
    #if compiler(>=6.2)
    if #available(macOS 26.0, *) {
        GlassEffectContainer(spacing: spacing) { content() }
    } else {
        content()
    }
    #else
    content()
    #endif
}
