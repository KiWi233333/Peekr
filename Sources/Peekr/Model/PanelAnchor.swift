import Foundation

/// Where the panel docks. Six positions: the two side edges + four corners.
/// (Top/bottom edges are intentionally unsupported — the rail is vertical.)
enum PanelAnchor: String, Codable, CaseIterable, Identifiable {
    case left, right
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var isCorner: Bool { self != .left && self != .right }

    var isLeftSide: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var isRightSide: Bool { self == .right || self == .topRight || self == .bottomRight }
    var isTopSide: Bool { self == .topLeft || self == .topRight }
    var isBottomSide: Bool { self == .bottomLeft || self == .bottomRight }

    /// All supported anchors slide in horizontally (the rail hugs a side).
    var slidesHorizontally: Bool { true }

    /// Rail hugs the docked side so icons sit nearest the screen edge.
    var railOnLeft: Bool { !isRightSide }

    var label: String {
        switch self {
        case .left: return "Left edge"
        case .right: return "Right edge"
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
        case .topLeft: return "arrow.up.left"
        case .topRight: return "arrow.up.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottomRight: return "arrow.down.right"
        }
    }
}
