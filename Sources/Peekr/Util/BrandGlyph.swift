import AppKit

/// Peekr's in-app brand mark: a rounded "window" with a slide-over panel on the
/// right and a little icon rail — the same motif as the Dock icon, drawn as a
/// monochrome template so it adapts to the menu bar and tints in the About
/// panel. Single source of truth for the in-app glyph; the *colored* Dock icon
/// lives separately in `Resources/AppIcon.icns`.
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

    /// Stroke the glyph in black (alpha = shape) inside `rect`. Geometry is
    /// expressed as fractions of the square so it stays crisp at any size.
    static func draw(in rect: NSRect) {
        let s = min(rect.width, rect.height)
        let ox = rect.minX + (rect.width - s) / 2
        let oy = rect.minY + (rect.height - s) / 2
        let line = s * 0.075

        NSColor.black.set()

        // Outer window — slightly wider than tall.
        let outer = NSRect(x: ox + s * 0.10, y: oy + s * 0.24,
                           width: s * 0.80, height: s * 0.52)
        let body = NSBezierPath(roundedRect: outer, xRadius: s * 0.12, yRadius: s * 0.12)
        body.lineWidth = line
        body.stroke()

        // Slide-over divider near the right edge.
        let dividerX = ox + s * 0.60
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: dividerX, y: outer.minY))
        divider.line(to: NSPoint(x: dividerX, y: outer.maxY))
        divider.lineWidth = line
        divider.stroke()

        // Icon rail: two dots in the right panel.
        let dotR = s * 0.058
        let dotX = dividerX + (outer.maxX - dividerX) / 2
        for cy in [outer.midY + s * 0.11, outer.midY - s * 0.11] {
            NSBezierPath(ovalIn: NSRect(x: dotX - dotR, y: cy - dotR,
                                        width: dotR * 2, height: dotR * 2)).fill()
        }
    }
}
