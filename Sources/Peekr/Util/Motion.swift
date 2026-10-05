import AppKit
import SwiftUI

/// Shared motion language for Peekr's native SwiftUI surfaces. Keep timings in
/// one place so drag reordering, collapse and drop feedback feel related.
enum Motion {
    enum Duration {
        static let dropTarget = 0.10
        static let controlFeedback = 0.12
        static let dropdownClose = 0.15
        static let sidebarStyle = 0.16
        static let iconSwap = 0.20
        static let sidebarCollapse = 0.20
        static let panelClose = 0.20
        static let panelOpen = 0.24
        static let dropdownOpen = 0.25
        static let panelLayout = 0.25
        static let panelSnap = 0.30
        static let spacesMorph = 0.34
    }

    private static func standard(_ duration: TimeInterval) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    /// A tightly damped spring: responsive enough to follow a drop without the
    /// playful bounce that would make a browser sidebar feel unstable.
    static let sidebarReorder = Animation.spring(
        response: 0.30,
        dampingFraction: 0.86,
        blendDuration: 0.06
    )

    static let sidebarCollapse = standard(Duration.sidebarCollapse)
    static let sidebarResize = Animation.spring(
        response: 0.26,
        dampingFraction: 0.94,
        blendDuration: 0.02
    )
    static let sidebarDropTarget = Animation.easeOut(duration: Duration.dropTarget)
    static let sidebarStyle = Animation.easeInOut(duration: Duration.sidebarStyle)
    static let controlFeedback = Animation.easeOut(duration: Duration.controlFeedback)
    static let iconSwap = Animation.easeInOut(duration: Duration.iconSwap)
    static let dropdownOpen = standard(Duration.dropdownOpen)
    static let dropdownClose = standard(Duration.dropdownClose)
    /// Short grace period that lets an omnibox suggestion receive a click after
    /// AppKit ends editing on the native text field.
    static let suggestionDismissGrace = Swift.Duration.milliseconds(120)
    static let badgePop = Animation.spring(response: 0.42, dampingFraction: 0.62)
    static let tileSelection = Animation.spring(response: 0.28, dampingFraction: 0.72)
    static let spacesMorph = standard(Duration.spacesMorph)

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// AppKit counterpart to the SwiftUI motion tokens. Keeping the hosted web
    /// view inside an implicit-animation transaction lets it continue painting
    /// while the real panel frame moves.
    @MainActor
    static func appKit(
        _ duration: TimeInterval,
        animations: @escaping () -> Void,
        reducedMotion: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard !reduceMotion else {
            (reducedMotion ?? animations)()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22, 1, 0.36, 1
            )
            context.allowsImplicitAnimation = true
            animations()
        } completionHandler: {
            completion?()
        }
    }
}
