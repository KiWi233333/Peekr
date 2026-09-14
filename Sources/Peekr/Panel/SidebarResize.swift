import CoreGraphics

/// The three useful sidebar widths. Dragging may move between these anchors,
/// but never leaves the sidebar at an arbitrary width after the gesture ends.
enum SidebarStage: CaseIterable {
    /// Chrome-style vertical tab rail: favicons and group controls only.
    case iconOnly
    /// The default tab list width requested for the normal layout.
    case normal
    /// Gives long tab titles more room without making the rail unbounded.
    case expanded

    private static let rubberBandFactor: CGFloat = 0.16
    private static let maxOvershoot: CGFloat = 18

    var width: CGFloat {
        switch self {
        case .iconOnly: return 64
        case .normal: return 220
        case .expanded: return 360
        }
    }

    /// Adds a small rubber-band past the two useful limits while dragging.
    static func elasticWidth(_ width: CGFloat) -> CGFloat {
        let minWidth = iconOnly.width
        let maxWidth = expanded.width
        if width < minWidth {
            let overshoot = min(Self.maxOvershoot, (minWidth - width) * Self.rubberBandFactor)
            return minWidth - overshoot
        }
        if width > maxWidth {
            let overshoot = min(Self.maxOvershoot, (width - maxWidth) * Self.rubberBandFactor)
            return maxWidth + overshoot
        }
        return width
    }

    static func nearest(to width: CGFloat) -> SidebarStage {
        allCases.min { abs($0.width - width) < abs($1.width - width) } ?? .expanded
    }
}
