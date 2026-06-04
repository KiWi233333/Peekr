import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: Settings!
    private var model: AppModel!
    private var icons: IconStore!
    private var manager: WebViewManager!
    private var panel: PanelController!
    private var edge: EdgeTrigger!
    private var statusBar: StatusBarController!
    private var prefs: PreferencesWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = Settings(store: SettingsStore())
        model = AppModel(store: AppStore())
        icons = IconStore()
        icons.warm(model.apps)

        manager = WebViewManager(model: model)
        panel = PanelController(model: model, settings: settings, manager: manager, icons: icons)
        panel.onVisibilityChange = { [weak self] visible in self?.edge.setArmed(!visible) }

        // Hover the docked edge/corner to peek the panel out.
        edge = EdgeTrigger(settings: settings)
        edge.onTrigger = { [weak self] in self?.panel.show() }
        edge.start()

        applyHotKey()

        prefs = PreferencesWindowController(
            model: model, settings: settings, icons: icons,
            onApply: { [weak self] in self?.applyPreferences() }
        )

        statusBar = StatusBarController(
            model: model,
            onToggle: { [weak self] in self?.panel.toggle() },
            onTogglePin: { [weak self] in self?.model.isPinned.toggle() },
            onPreferences: { [weak self] in self?.prefs.show() }
        )

        // Keep the login item in sync with the saved preference.
        LaunchAtLogin.set(settings.launchAtLogin)
    }

    private func applyHotKey() {
        GlobalHotKeyCenter.shared.setPrimary(settings.hotKey) { [weak self] in
            self?.panel.toggle()
        }
    }

    private func applyPreferences() {
        applyHotKey()
        panel.applyLayout()
    }
}
