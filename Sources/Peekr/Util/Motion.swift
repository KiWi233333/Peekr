import SwiftUI

/// Shared motion language for Peekr's native SwiftUI surfaces. Keep timings in
/// one place so drag reordering, collapse and drop feedback feel related.
enum Motion {
    /// A tightly damped spring: responsive enough to follow a drop without the
    /// playful bounce that would make a browser sidebar feel unstable.
    static let sidebarReorder = Animation.spring(
        response: 0.30,
        dampingFraction: 0.86,
        blendDuration: 0.06
    )

    static let sidebarCollapse = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.20)
    static let sidebarDropTarget = Animation.easeOut(duration: 0.10)
    static let sidebarStyle = Animation.easeInOut(duration: 0.16)
}
