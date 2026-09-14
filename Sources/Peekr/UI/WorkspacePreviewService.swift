import AppKit
import Observation

/// Keeps small, recent workspace previews for the Spaces overview.
///
/// Windowed CEF views only render reliably while attached to a live window, so
/// this service never tries to wake or reparent background browsers just to
/// make a thumbnail. It samples the currently visible page at a bounded rate
/// while the overview is open and lets cards fall back to their tab metadata
/// when a frame is unavailable.
@MainActor
@Observable
final class WorkspacePreviewService {
    private(set) var previews: [UUID: NSImage] = [:]

    private let interval: TimeInterval
    private var timer: Timer?
    private weak var model: AppModel?
    private weak var manager: WebViewManager?

    init(interval: TimeInterval = 0.5) {
        self.interval = max(0.25, interval)
    }

    func start(model: AppModel, manager: WebViewManager) {
        stop()
        self.model = model
        self.manager = manager
        captureCurrentWorkspace()

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard self != nil else {
                timer.invalidate()
                return
            }
            Task { @MainActor [weak self] in
                self?.captureCurrentWorkspace()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        model = nil
        manager = nil
    }

    private func captureCurrentWorkspace() {
        guard let model, let manager,
              let workspace = model.workspaces.first(where: { $0.id == model.activeWorkspaceID }) else {
            return
        }
        let validWorkspaceIDs = Set(model.workspaces.map(\.id))
        previews = previews.filter { validWorkspaceIDs.contains($0.key) }

        guard let tabID = workspace.selectedTabID ?? workspace.orderedTabIDs.first,
              let view = manager.view(for: tabID),
              let image = Self.snapshot(of: view),
              Self.isUsable(image) else {
            previews.removeValue(forKey: workspace.id)
            return
        }

        previews[workspace.id] = image
    }

    private static func snapshot(of view: NSView) -> NSImage? {
        guard view.window != nil,
              view.superview != nil,
              view.bounds.width > 1,
              view.bounds.height > 1 else { return nil }

        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)

        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        return resized(image, maxSize: CGSize(width: 640, height: 360))
    }

    private static func resized(_ image: NSImage, maxSize: CGSize) -> NSImage? {
        guard image.size.width > 1, image.size.height > 1 else { return nil }
        let scale = min(
            1,
            maxSize.width / image.size.width,
            maxSize.height / image.size.height
        )
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let result = NSImage(size: size)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        result.unlockFocus()
        return result
    }

    /// Reject transparent or uniform white frames, which are common when a
    /// windowed CEF view has not painted yet. A real white page can still use
    /// the metadata fallback; showing a blank card is less informative.
    private static func isUsable(_ image: NSImage) -> Bool {
        guard let representation = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            return true
        }

        let width = representation.pixelsWide
        let height = representation.pixelsHigh
        guard width > 1, height > 1 else { return false }

        var minLuminance: CGFloat = 1
        var maxLuminance: CGFloat = 0
        var hasOpaquePixel = false
        let stepX = max(1, width / 8)
        let stepY = max(1, height / 8)

        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let alpha = color.alphaComponent
                guard alpha > 0.02 else { continue }
                hasOpaquePixel = true
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                minLuminance = min(minLuminance, luminance)
                maxLuminance = max(maxLuminance, luminance)
            }
        }

        guard hasOpaquePixel else { return false }
        return maxLuminance - minLuminance >= 0.01 || minLuminance < 0.985
    }
}
