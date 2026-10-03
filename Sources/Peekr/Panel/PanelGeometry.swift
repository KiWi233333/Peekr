import AppKit

struct PanelLayout {
    let onscreen: NSRect
    let offscreen: NSRect
}

/// Which panel edge a resize handle drags.
enum PanelResizeEdge: Hashable {
    case leading, trailing, top, bottom
}

/// A draggable region on the panel's free (non-docked) perimeter. An edge resizes
/// one axis; a corner (a width edge + a height edge) resizes both at once.
enum PanelResizeZone: Hashable {
    case edge(PanelResizeEdge)
    case corner(PanelResizeEdge, PanelResizeEdge)   // (horizontal, vertical)
}

/// Pure geometry. The panel keeps a user-chosen `size`; snapping only changes
/// where it docks (flush to an edge/corner) and the slide-in direction — never
/// the size. Aligns with SlidePad's resizable slide-over.
enum PanelGeometry {
    /// Floor the user can shrink the panel to — shared by the resize handles and
    /// the preferences sliders so both agree on the minimum. (The maximum is the
    /// screen's visible size when resizing; a fixed cap in the sliders.)
    static let minSize = NSSize(width: 600, height: 240)

    /// Native window-resize semantics: the dragged edge follows the pointer and
    /// its opposite edge remains fixed. For example, dragging the bottom-right
    /// corner keeps the top and left edges stationary. The moving edges are
    /// clamped to the screen's visible frame and the panel's minimum size.
    static func resizedFrame(
        from start: NSRect,
        dragging edges: [PanelResizeEdge],
        delta: NSSize,
        within bounds: NSRect,
        minimumSize: NSSize = minSize
    ) -> NSRect {
        let minWidth = Swift.min(minimumSize.width, bounds.width)
        let minHeight = Swift.min(minimumSize.height, bounds.height)
        var frame = start

        if edges.contains(.leading) {
            let x = Swift.min(
                Swift.max(start.minX + delta.width, bounds.minX),
                start.maxX - minWidth)
            frame.origin.x = x
            frame.size.width = start.maxX - x
        } else if edges.contains(.trailing) {
            let maxX = Swift.max(
                Swift.min(start.maxX + delta.width, bounds.maxX),
                start.minX + minWidth)
            frame.origin.x = start.minX
            frame.size.width = maxX - start.minX
        }

        if edges.contains(.bottom) {
            let y = Swift.min(
                Swift.max(start.minY + delta.height, bounds.minY),
                start.maxY - minHeight)
            frame.origin.y = y
            frame.size.height = start.maxY - y
        } else if edges.contains(.top) {
            let maxY = Swift.max(
                Swift.min(start.maxY + delta.height, bounds.maxY),
                start.minY + minHeight)
            frame.origin.y = start.minY
            frame.size.height = maxY - start.minY
        }

        return frame
    }

    /// On-screen (docked) and off-screen (hidden) frames for an anchor + size.
    static func layout(anchor: PanelAnchor, screen: NSScreen, size: NSSize) -> PanelLayout {
        layout(
            anchor: anchor,
            visibleFrame: screen.visibleFrame,
            screenFrame: screen.frame,
            size: size
        )
    }

    /// Pure frame calculation used by the screen-backed overload and geometry tests.
    /// Corner anchors leave through the same corner they enter from, so their
    /// hidden frame is outside both adjoining screen edges.
    static func layout(
        anchor: PanelAnchor,
        visibleFrame vf: NSRect,
        screenFrame full: NSRect,
        size: NSSize
    ) -> PanelLayout {
        let w = min(size.width, vf.width)
        let h = min(size.height, vf.height)
        let centerX = vf.minX + (vf.width - w) / 2
        let centerY = vf.minY + (vf.height - h) / 2

        // Docked position: flush to the docked edge(s); centered on the free axis.
        let onX: CGFloat
        switch true {
        case anchor.isLeftSide: onX = vf.minX
        case anchor.isRightSide: onX = vf.maxX - w
        default: onX = centerX
        }
        let onY: CGFloat
        switch true {
        case anchor.isTopSide: onY = vf.maxY - h
        case anchor.isBottomSide: onY = vf.minY
        default: onY = centerY
        }
        let onscreen = NSRect(x: onX, y: onY, width: w, height: h)

        // Slide-in direction (off-screen origin), keeping size fixed. For a
        // corner, moving both axes makes the panel feel attached to that
        // corner, like Slidepad's directional reveal.
        let offOrigin: NSPoint
        switch anchor {
        case .left:
            offOrigin = NSPoint(x: full.minX - w, y: onscreen.minY)
        case .right:
            offOrigin = NSPoint(x: full.maxX, y: onscreen.minY)
        case .topLeft:
            offOrigin = NSPoint(x: full.minX - w, y: full.maxY)
        case .topRight:
            offOrigin = NSPoint(x: full.maxX, y: full.maxY)
        case .bottomLeft:
            offOrigin = NSPoint(x: full.minX - w, y: full.minY - h)
        case .bottomRight:
            offOrigin = NSPoint(x: full.maxX, y: full.minY - h)
        }
        let off = NSRect(origin: offOrigin, size: onscreen.size)
        return PanelLayout(onscreen: onscreen, offscreen: off)
    }

    /// Default size when the user hasn't resized yet — 2/3 of the screen width.
    static func defaultSize(for screen: NSScreen) -> NSSize {
        defaultSize(forVisible: screen.visibleFrame.size)
    }

    /// Same ratio default, expressed against a bare visible-area size so it can be
    /// unit-tested without a live `NSScreen`.
    static func defaultSize(forVisible visible: NSSize) -> NSSize {
        NSSize(width: visible.width * (2.0 / 3.0), height: visible.height * 0.92)
    }

    /// Resolve the panel size from the single global size. Each axis prefers the
    /// global value, falling back to the screen-ratio default where `0` means
    /// "not set". The result is clamped to `[minSize, visible]` so a size saved
    /// on a larger display still fits the current one.
    static func resolveSize(global: NSSize, visible: NSSize) -> NSSize {
        let def = defaultSize(forVisible: visible)
        func axis(_ value: CGFloat, fallback: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
            let chosen = value > 0 ? value : fallback
            return Swift.min(Swift.max(min, chosen), max)
        }
        return NSSize(
            width: axis(global.width, fallback: def.width, min: minSize.width, max: visible.width),
            height: axis(global.height, fallback: def.height, min: minSize.height, max: visible.height))
    }

    /// The hover zone that peeks the panel out for a given anchor.
    static func triggerRegion(anchor: PanelAnchor, screen: NSScreen, thickness: CGFloat) -> NSRect {
        let f = screen.frame
        let t = max(2, thickness)
        let cornerH = f.height * 0.42

        switch anchor {
        case .left:        return NSRect(x: f.minX, y: f.minY, width: t, height: f.height)
        case .right:       return NSRect(x: f.maxX - t, y: f.minY, width: t, height: f.height)
        case .topLeft:     return NSRect(x: f.minX, y: f.maxY - cornerH, width: t, height: cornerH)
        case .topRight:    return NSRect(x: f.maxX - t, y: f.maxY - cornerH, width: t, height: cornerH)
        case .bottomLeft:  return NSRect(x: f.minX, y: f.minY, width: t, height: cornerH)
        case .bottomRight: return NSRect(x: f.maxX - t, y: f.minY, width: t, height: cornerH)
        }
    }

    /// Nearest of the 6 anchors to a point (used when releasing a drag).
    static func nearestAnchor(to point: NSPoint, on screen: NSScreen) -> PanelAnchor {
        let f = screen.frame
        let nx = (point.x - f.minX) / max(1, f.width)
        let ny = (point.y - f.minY) / max(1, f.height) // 0 = bottom, 1 = top
        let onLeft = nx < 0.5
        let top = ny > 0.66, bottom = ny < 0.34

        if top { return onLeft ? .topLeft : .topRight }
        if bottom { return onLeft ? .bottomLeft : .bottomRight }
        return onLeft ? .left : .right
    }
}

extension NSScreen {
    /// Stable per-display number for remembering which screen to peek on.
    var screenNumber: Int? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int
    }
}
