import AppKit

/// Peekr's compact menu-bar mark: a rounded window and the three-dot
/// slide-over panel from the colored app icon. It remains a monochrome
/// template so the menu bar can tint it for either appearance.
enum BrandGlyph {
    /// A template `NSImage` (renders in the menu-bar / control color). Never nil,
    /// so call sites don't need a text fallback.
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Draw the compact monochrome companion to `Resources/AppIcon.icns`.
    /// Geometry is expressed as fractions of the square for crisp scaling at
    /// menu-bar sizes.
    static func draw(in rect: NSRect) {
        let s = min(rect.width, rect.height)
        let ox = rect.minX + (rect.width - s) / 2
        let oy = rect.minY + (rect.height - s) / 2
        let line = s * 0.075

        NSColor.black.set()

        let outer = NSRect(x: ox + s * 0.12, y: oy + s * 0.14,
                           width: s * 0.76, height: s * 0.72)
        let body = NSBezierPath(
            roundedRect: outer,
            xRadius: s * 0.22,
            yRadius: s * 0.22
        )
        body.lineWidth = line
        body.stroke()

        let panelRect = NSRect(x: ox + s * 0.56, y: oy + s * 0.28,
                               width: s * 0.22, height: s * 0.44)
        let panel = NSBezierPath(
            roundedRect: panelRect,
            xRadius: s * 0.09,
            yRadius: s * 0.09
        )
        panel.lineWidth = line
        panel.stroke()

        let dotR = s * 0.027
        let dotX = panelRect.midX
        for cy in [oy + s * 0.63, oy + s * 0.50, oy + s * 0.37] {
            NSBezierPath(ovalIn: NSRect(x: dotX - dotR, y: cy - dotR,
                                        width: dotR * 2, height: dotR * 2)).fill()
        }
    }
}
