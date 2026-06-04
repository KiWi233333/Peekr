import SwiftUI

/// Hosts the active (cached) web page view. Re-attaches when `currentID`
/// changes; the view itself is owned by `WebViewManager` (via its `WebEngine`)
/// so it survives swaps.
struct WebContainer: NSViewRepresentable {
    let manager: WebViewManager
    let currentID: UUID?

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        guard let id = currentID, let web = manager.view(for: id) else {
            host.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if web.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            web.frame = host.bounds
            web.autoresizingMask = [.width, .height]
            host.addSubview(web)
        }
    }
}
