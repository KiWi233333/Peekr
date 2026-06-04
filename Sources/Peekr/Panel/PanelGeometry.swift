import AppKit

struct PanelLayout {
    let onscreen: NSRect
    let offscreen: NSRect
}

/// Pure geometry for anchoring, sliding and snapping the panel.
enum PanelGeometry {
    static let margin: CGFloat = 14
    static let cornerHeightFraction: CGFloat = 0.82

    /// On-screen (docked) and off-screen (hidden) frames for an anchor.
    static func layout(anchor: PanelAnchor, screen: NSScreen, width: CGFloat) -> PanelLayout {
        let vf = screen.visibleFrame
        let full = screen.frame
        let w = min(width, vf.width - 2 * margin)

        switch anchor {
        case .left:
            let on = NSRect(x: vf.minX, y: vf.minY, width: w, height: vf.height)
            return .init(onscreen: on, offscreen: NSRect(x: full.minX - w, y: vf.minY, width: w, height: vf.height))
        case .right:
            let on = NSRect(x: vf.maxX - w, y: vf.minY, width: w, height: vf.height)
            return .init(onscreen: on, offscreen: NSRect(x: full.maxX, y: vf.minY, width: w, height: vf.height))
        case .top:
            let h = min(width, vf.height - 2 * margin)
            let on = NSRect(x: vf.minX, y: vf.maxY - h, width: vf.width, height: h)
            return .init(onscreen: on, offscreen: NSRect(x: vf.minX, y: full.maxY, width: vf.width, height: h))
        case .bottom:
            let h = min(width, vf.height - 2 * margin)
            let on = NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: h)
            return .init(onscreen: on, offscreen: NSRect(x: vf.minX, y: full.minY - h, width: vf.width, height: h))
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let ch = vf.height * cornerHeightFraction
            let y = anchor.isTopSide ? vf.maxY - margin - ch : vf.minY + margin
            let x = anchor.isLeftSide ? vf.minX + margin : vf.maxX - margin - w
            let on = NSRect(x: x, y: y, width: w, height: ch)
            let offX = anchor.isLeftSide ? full.minX - w : full.maxX
            return .init(onscreen: on, offscreen: NSRect(x: offX, y: y, width: w, height: ch))
        }
    }

    /// The hover zone that peeks the panel out for a given anchor.
    static func triggerRegion(anchor: PanelAnchor, screen: NSScreen, thickness: CGFloat) -> NSRect {
        let f = screen.frame
        let t = max(2, thickness)
        let frac: CGFloat = 0.42
        let cornerH = f.height * frac

        switch anchor {
        case .left:   return NSRect(x: f.minX, y: f.minY, width: t, height: f.height)
        case .right:  return NSRect(x: f.maxX - t, y: f.minY, width: t, height: f.height)
        case .top:    return NSRect(x: f.minX, y: f.maxY - t, width: f.width, height: t)
        case .bottom: return NSRect(x: f.minX, y: f.minY, width: f.width, height: t)
        case .topLeft:     return NSRect(x: f.minX, y: f.maxY - cornerH, width: t, height: cornerH)
        case .topRight:    return NSRect(x: f.maxX - t, y: f.maxY - cornerH, width: t, height: cornerH)
        case .bottomLeft:  return NSRect(x: f.minX, y: f.minY, width: t, height: cornerH)
        case .bottomRight: return NSRect(x: f.maxX - t, y: f.minY, width: t, height: cornerH)
        }
    }

    /// Nearest of the 8 anchors to a point (used when releasing a drag).
    static func nearestAnchor(to point: NSPoint, on screen: NSScreen) -> PanelAnchor {
        let f = screen.frame
        let nx = (point.x - f.minX) / max(1, f.width)
        let ny = (point.y - f.minY) / max(1, f.height) // 0 = bottom, 1 = top
        let left = nx < 0.34, right = nx > 0.66
        let bottom = ny < 0.34, top = ny > 0.66

        if top && left { return .topLeft }
        if top && right { return .topRight }
        if bottom && left { return .bottomLeft }
        if bottom && right { return .bottomRight }
        if left { return .left }
        if right { return .right }
        if top { return .top }
        if bottom { return .bottom }
        return nx < 0.5 ? .left : .right
    }
}

extension NSScreen {
    /// Stable per-display number for remembering which screen to peek on.
    var screenNumber: Int? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int
    }
}
