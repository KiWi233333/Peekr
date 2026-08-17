import AppKit

/// Peekr's in-app brand mark: a rounded window, one motion stroke, and the
/// three-dot slide-over panel from the colored app icon. It remains a
/// monochrome template so the menu bar can tint it for either appearance.
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
    /// Geometry is expressed as fractions of the square for crisp scaling.
    static func draw(in rect: NSRect) {
        let s = min(rect.width, rect.height)
        let ox = rect.minX + (rect.width - s) / 2
        let oy = rect.minY + (rect.height - s) / 2
        let line = s * 0.070

        NSColor.black.set()

        let outer = NSRect(x: ox + s * 0.08, y: oy + s * 0.14,
                           width: s * 0.84, height: s * 0.72)
        let body = NSBezierPath(
            roundedRect: outer,
            xRadius: s * 0.20,
            yRadius: s * 0.20
        )
        body.lineWidth = line
        body.stroke()

        // One tapered-looking curve is enough to preserve the new icon's
        // rightward motion at menu-bar sizes without introducing visual noise.
        let motion = NSBezierPath()
        motion.move(to: NSPoint(x: ox + s * 0.17, y: oy + s * 0.45))
        motion.curve(
            to: NSPoint(x: ox + s * 0.51, y: oy + s * 0.62),
            controlPoint1: NSPoint(x: ox + s * 0.27, y: oy + s * 0.60),
            controlPoint2: NSPoint(x: ox + s * 0.40, y: oy + s * 0.66)
        )
        motion.lineCapStyle = .round
        motion.lineWidth = line * 0.82
        motion.stroke()

        let panelRect = NSRect(x: ox + s * 0.48, y: oy + s * 0.22,
                               width: s * 0.45, height: s * 0.56)
        let panel = NSBezierPath(
            roundedRect: panelRect,
            xRadius: s * 0.14,
            yRadius: s * 0.14
        )
        panel.lineWidth = line
        panel.stroke()

        let dotR = s * 0.040
        let dotX = panelRect.minX + s * 0.12
        for cy in [oy + s * 0.63, oy + s * 0.50, oy + s * 0.37] {
            NSBezierPath(ovalIn: NSRect(x: dotX - dotR, y: cy - dotR,
                                        width: dotR * 2, height: dotR * 2)).fill()
        }
    }
}
