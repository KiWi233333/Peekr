import AppKit
import WebKit

/// Creates and caches one WKWebView per app, keeping them alive across
/// show/hide so sessions, scroll position and playback are never lost.
/// Each app gets its own persistent data store → isolated cookies/logins.
@MainActor
final class WebViewManager: NSObject {
    weak var container: NSView?

    private let model: AppModel
    private var views: [UUID: WKWebView] = [:]
    private var currentID: UUID?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show(_ id: UUID) {
        guard let container, let app = model.apps.first(where: { $0.id == id }) else { return }
        let view = webView(for: app)
        if currentID == id, view.superview === container { return }

        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        currentID = id
    }

    func layoutCurrent() {
        guard let container, let id = currentID, let view = views[id] else { return }
        view.frame = container.bounds
    }

    // MARK: - Private

    private func webView(for app: WebApp) -> WKWebView {
        if let existing = views[app.id] { return existing }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = makeDataStore(for: app.id)
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.preferences.isElementFullscreenEnabled = true
        config.allowsAirPlayForMediaPlayback = true

        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        if let url = app.url {
            view.load(URLRequest(url: url))
        }
        views[app.id] = view
        return view
    }

    /// Per-app persistent isolation needs a bundle identifier; fall back to the
    /// shared store when running the bare executable via `swift run`.
    private func makeDataStore(for id: UUID) -> WKWebsiteDataStore {
        if Bundle.main.bundleIdentifier != nil {
            return WKWebsiteDataStore(forIdentifier: id)
        }
        return .default()
    }
}
