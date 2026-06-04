import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var panel: PanelController!
    private var edge: EdgeTrigger!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = AppStore()
        model = AppModel(store: store)
        panel = PanelController(model: model)

        // Hover the right screen edge to peek the panel out.
        edge = EdgeTrigger()
        edge.onTrigger = { [weak self] in self?.panel.show() }
        edge.start()

        // Global hotkey: ⌃⌥Space toggles the panel from anywhere.
        GlobalHotKeyCenter.shared.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey)
        ) { [weak self] in
            self?.panel.toggle()
        }

        statusBar = StatusBarController(
            model: model,
            onToggle: { [weak self] in self?.panel.toggle() },
            onTogglePin: { [weak self] in self?.model.isPinned.toggle() }
        )
    }
}
