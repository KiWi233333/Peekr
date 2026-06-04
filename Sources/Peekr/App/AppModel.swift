import Foundation
import Observation

/// Observable source of truth for the dock, selection and pin state.
@MainActor
@Observable
final class AppModel {
    var apps: [WebApp]
    var selectedID: WebApp.ID?
    var isPinned: Bool = false

    private let store: AppStore

    init(store: AppStore) {
        self.store = store
        let loaded = store.load()
        apps = loaded
        selectedID = loaded.first?.id
    }

    func select(_ id: WebApp.ID) {
        selectedID = id
    }

    @discardableResult
    func addApp(title: String, urlString: String) -> WebApp {
        let app = WebApp(title: title, urlString: urlString)
        apps.append(app)
        selectedID = app.id
        persist()
        return app
    }

    func update(_ app: WebApp) {
        guard let idx = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[idx] = app
        persist()
    }

    func removeApp(_ id: WebApp.ID) {
        apps.removeAll { $0.id == id }
        if selectedID == id { selectedID = apps.first?.id }
        persist()
    }

    /// Move the app identified by `draggedID` to sit just before `targetID`.
    func move(_ draggedID: WebApp.ID, before targetID: WebApp.ID) {
        guard draggedID != targetID,
              let from = apps.firstIndex(where: { $0.id == draggedID })
        else { return }
        let item = apps.remove(at: from)
        if let to = apps.firstIndex(where: { $0.id == targetID }) {
            apps.insert(item, at: to)
        } else {
            apps.append(item)
        }
        persist()
    }

    /// Reorder from a List's drag offsets (no SwiftUI dependency here).
    func moveApps(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { apps[$0] }
        for index in source.sorted(by: >) { apps.remove(at: index) }
        let adjusted = destination - source.filter { $0 < destination }.count
        apps.insert(contentsOf: moving, at: min(max(0, adjusted), apps.count))
        persist()
    }

    func persist() {
        store.save(apps)
    }
}
