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

    func removeApp(_ id: WebApp.ID) {
        apps.removeAll { $0.id == id }
        if selectedID == id { selectedID = apps.first?.id }
        persist()
    }

    func persist() {
        store.save(apps)
    }
}
