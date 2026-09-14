import SwiftUI

/// Shared geometry constants for the Spaces shared-element transition.
enum SpacesMorph {
    /// Corner radius of a card preview in the overview grid (`SpaceCard`).
    static let cardPreviewCorner: CGFloat = 11
}

/// Astro view-transition style morph: one snapshot interpolates frame, corner
/// radius, crop and opacity between the browser card's frame and its Space
/// card preview frame. Driven by a single animatable `progress` (0...1).
struct SpacesMorphModifier: ViewModifier, Animatable {
    var progress: Double
    var from: CGRect
    var to: CGRect
    var fromCorner: CGFloat
    var toCorner: CGFloat
    var fromOpacity: Double = 1
    var toOpacity: Double = 1

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = progress
        let frame = CGRect(
            x: from.minX + (to.minX - from.minX) * t,
            y: from.minY + (to.minY - from.minY) * t,
            width: from.width + (to.width - from.width) * t,
            height: from.height + (to.height - from.height) * t
        )
        let corner = fromCorner + (toCorner - fromCorner) * t
        content
            // scaledToFill matches how the destination card renders the same
            // snapshot, so both endpoints of the flight are pixel-identical to
            // the surface being revealed.
            .scaledToFill()
            .frame(width: frame.width, height: frame.height)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .opacity(fromOpacity + (toOpacity - fromOpacity) * t)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
    }
}
