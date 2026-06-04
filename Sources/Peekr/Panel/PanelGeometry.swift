import AppKit

struct PanelLayout {
    let onscreen: NSRect
    let offscreen: NSRect
}

/// Which panel edge a resize handle drags.
enum PanelResizeEdge {
    case leading, trailing, top, bottom
}

/// Pure geometry. The panel keeps a user-chosen `size`; snapping only changes
/// where it docks (flush to an edge/corner) and the slide-in direction — never
/// the size. Aligns with SlidePad's resizable slide-over.
enum PanelGeometry {
    /// Floor the user can shrink the panel to — shared by the resize handles and
    /// the preferences sliders so both agree on the minimum. (The maximum is the
    /// screen's visible size when resizing; a fixed cap in the sliders.)
    static let minSize = NSSize(width: 280, height: 240)

    /// On-screen (docked) and off-screen (hidden) frames for an anchor + size.
    static func layout(anchor: PanelAnchor, screen: NSScreen, size: NSSize) -> PanelLayout {
        let vf = screen.visibleFrame
        let full = screen.frame
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

        // Slide-in direction (off-screen origin), keeping size fixed.
        var off = onscreen
        if anchor.slidesHorizontally {
            off.origin.x = anchor.isRightSide ? full.maxX : full.minX - w
        } else {
            off.origin.y = anchor.isTopSide ? full.maxY : full.minY - h
        }
        return PanelLayout(onscreen: onscreen, offscreen: off)
    }

    /// Default size when the user hasn't resized yet — 2/3 of the screen width.
    static func defaultSize(for screen: NSScreen) -> NSSize {
        let vf = screen.visibleFrame
        return NSSize(width: vf.width * (2.0 / 3.0), height: vf.height * 0.92)
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
