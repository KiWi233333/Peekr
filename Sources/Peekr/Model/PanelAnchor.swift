import Foundation

/// Where the panel docks. Eight positions: four edges + four corners.
enum PanelAnchor: String, Codable, CaseIterable, Identifiable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }

    var isLeftSide: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var isRightSide: Bool { self == .right || self == .topRight || self == .bottomRight }
    var isTopSide: Bool { self == .top || self == .topLeft || self == .topRight }
    var isBottomSide: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }

    /// L/R edges and all corners slide horizontally; T/B slide vertically.
    var slidesHorizontally: Bool { self != .top && self != .bottom }

    /// Rail hugs the docked side so icons sit nearest the screen edge.
    var railOnLeft: Bool { !isRightSide }

    var label: String {
        switch self {
        case .left: return "Left edge"
        case .right: return "Right edge"
        case .top: return "Top edge"
        case .bottom: return "Bottom edge"
        case .topLeft: return "Top-left"
        case .topRight: return "Top-right"
        case .bottomLeft: return "Bottom-left"
        case .bottomRight: return "Bottom-right"
        }
    }

    var symbol: String {
        switch self {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .top: return "arrow.up"
        case .bottom: return "arrow.down"
        case .topLeft: return "arrow.up.left"
        case .topRight: return "arrow.up.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottomRight: return "arrow.down.right"
        }
    }
}
