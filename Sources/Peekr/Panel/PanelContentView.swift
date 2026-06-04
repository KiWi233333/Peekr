import AppKit
import SwiftUI

/// The panel's content: a frosted icon rail (SwiftUI) on the left and the
/// active web view (managed in AppKit so it survives show/hide) on the right.
@MainActor
final class PanelContentView: NSView {
    private let model: AppModel
    private let webManager: WebViewManager

    private let railWidth: CGFloat = 64
    private let backdrop = NSVisualEffectView()
    private let webContainer = NSView()
    private var railHost: NSHostingView<SidebarRail>!

    init(model: AppModel, webManager: WebViewManager) {
        self.model = model
        self.webManager = webManager
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        autoresizesSubviews = false

        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        addSubview(backdrop)

        let rail = SidebarRail(
            model: model,
            onSelect: { [weak self] id in
                self?.model.select(id)
                self?.webManager.show(id)
            },
            onAdd: { [weak self] in self?.promptAdd() }
        )
        railHost = NSHostingView(rootView: rail)
        addSubview(railHost)

        webContainer.wantsLayer = true
        addSubview(webContainer)
        webManager.container = webContainer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContents()
    }

    private func layoutContents() {
        backdrop.frame = bounds
        railHost.frame = NSRect(x: 0, y: 0, width: railWidth, height: bounds.height)
        webContainer.frame = NSRect(
            x: railWidth,
            y: 0,
            width: max(0, bounds.width - railWidth),
            height: bounds.height
        )
        webManager.layoutCurrent()
    }

    // MARK: - Add app

    private func promptAdd() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add Web App"
        alert.informativeText = "Enter a website URL"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "https://example.com"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        let title = URL(string: text)?.host?.replacingOccurrences(of: "www.", with: "") ?? text
        let app = model.addApp(title: title, urlString: text)
        webManager.show(app.id)
    }
}
