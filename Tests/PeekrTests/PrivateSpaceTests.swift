import AppKit
import XCTest
@testable import Peekr

@MainActor
final class PrivateSpaceTests: XCTestCase {
    private final class FakeEngine: WebEngine {
        let hostView = NSView()
        var navState = NavState()
        var onNavStateChange: ((NavState) -> Void)?
        var onDownloadChange: ((WebDownload) -> Void)?
        var activity = WebActivitySnapshot(audio: .silent)
        private(set) var loadedURLs: [URL] = []

        func load(_ url: URL) { loadedURLs.append(url) }
        func goBack() {}
        func goForward() {}
        func reload() {}
        func stopLoading() {}
        func close() {}
        func iconLinkURLs() async -> [URL] { [] }

        func publish(_ state: NavState) {
            navState = state
            onNavStateChange?(state)
        }

        func publish(_ download: WebDownload) {
            onDownloadChange?(download)
        }
    }

    private final class FakeFactory: WebEngineFactory {
        private(set) var engines: [FakeEngine] = []

        func makeEngine(for app: WebApp, profile: BrowserProfile) -> WebEngine {
            let engine = FakeEngine()
            engines.append(engine)
            return engine
        }
    }

    func testPrivateWorkspaceUsesTheIncognitoProfile() throws {
        let model = makeModel()
        let normalWorkspaceID = model.activeWorkspaceID
        var switches: [(Workspace.ID, Workspace.ID)] = []
        model.onWorkspaceSwitch = { switches.append(($0, $1)) }

        let workspace = model.addPrivateWorkspace()
        let tab = try XCTUnwrap(workspace.tabs.first)

        XCTAssertTrue(workspace.isPrivate)
        XCTAssertEqual(workspace.profileID, BrowserProfile.incognitoID)
        XCTAssertEqual(workspace.symbol, "eye.slash")
        XCTAssertTrue(workspace.name.isEmpty)
        XCTAssertEqual(tab.urlString, InternalPage.newTab.urlString)
        XCTAssertEqual(model.activeWorkspaceID, workspace.id)
        XCTAssertEqual(model.selectedID, tab.id)
        XCTAssertEqual(switches.count, 1)
        XCTAssertEqual(switches.first?.0, normalWorkspaceID)
        XCTAssertEqual(switches.first?.1, workspace.id)

        XCTAssertEqual(model.profile(workspace.profileID)?.id, BrowserProfile.incognitoID)
        XCTAssertTrue(model.profile(forTab: tab.id).isIncognito)
        XCTAssertFalse(model.profiles.contains(where: \.isIncognito))
        XCTAssertTrue(model.isPrivateWorkspace(workspace.id))
        XCTAssertTrue(model.isPrivateTab(tab.id))
        XCTAssertFalse(model.isPrivateTab(model.workspaces[0].tabs[0].id))
    }

    func testPrivateWorkspacesAreExcludedFromPersistence() throws {
        let storeURL = temporaryFile("private-space-store")
        let profileURL = temporaryFile("private-space-profiles")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: profileURL)
        }
        let store = AppStore(fileURL: storeURL)
        let profileStore = ProfileStore(fileURL: profileURL)
        let normal = Workspace(
            name: "Home",
            tabs: [WebApp(title: "Home", urlString: "https://home.example")]
        )
        store.save(WorkspacesData(workspaces: [normal], activeWorkspaceID: normal.id))

        let model = AppModel(store: store, profileStore: profileStore)
        XCTAssertEqual(model.activeWorkspaceID, normal.id)
        let privateWorkspace = model.addPrivateWorkspace()
        model.renameWorkspace(privateWorkspace.id, to: "Renamed private")

        let data = try Data(contentsOf: storeURL)
        let persisted = try JSONDecoder().decode(WorkspacesData.self, from: data)
        XCTAssertEqual(persisted.workspaces.map(\.id), [normal.id])
        XCTAssertEqual(persisted.activeWorkspaceID, normal.id)
        XCTAssertFalse(persisted.workspaces.contains(where: \.isPrivate))
        XCTAssertTrue(model.workspaces.contains { $0.id == privateWorkspace.id })
        XCTAssertEqual(model.activeWorkspaceID, privateWorkspace.id)

        let reloaded = AppModel(store: store, profileStore: profileStore)
        XCTAssertEqual(reloaded.workspaces.map(\.id), [normal.id])
        XCTAssertEqual(reloaded.activeWorkspaceID, normal.id)
        XCTAssertFalse(reloaded.workspaces.contains(where: \.isPrivate))
    }

    func testRemovingTheLastNormalWorkspaceIsRejected() {
        let model = makeModel()
        let normalWorkspaceID = model.activeWorkspaceID
        let privateWorkspace = model.addPrivateWorkspace()

        model.removeWorkspace(normalWorkspaceID)

        XCTAssertEqual(model.workspaces.filter { !$0.isPrivate }.map(\.id), [normalWorkspaceID])

        model.removeWorkspace(privateWorkspace.id)

        XCTAssertFalse(model.workspaces.contains { $0.id == privateWorkspace.id })
        XCTAssertEqual(model.activeWorkspaceID, normalWorkspaceID)
    }

    func testWorkspaceTolerantDecodeDefaultsIsPrivateToFalse() throws {
        let legacy = Data(#"{"name":"Legacy","symbol":"square.stack","tabs":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(Workspace.self, from: legacy)
        XCTAssertFalse(decoded.isPrivate)

        let encoded = try JSONEncoder().encode(Workspace(name: "Private", isPrivate: true))
        XCTAssertTrue(try JSONDecoder().decode(Workspace.self, from: encoded).isPrivate)
    }

    func testProfileRegistryNeverPersistsTheIncognitoProfile() throws {
        let legacy = Data(#"{"name":"Legacy"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(BrowserProfile.self, from: legacy).isIncognito)
        XCTAssertTrue(BrowserProfile.incognitoProfile.isIncognito)

        let registry = ProfileRegistry(profiles: [.defaultProfile, .incognitoProfile])
        XCTAssertFalse(registry.normalized().profiles.contains { $0.id == BrowserProfile.incognitoID })
    }

    func testPrivateTabsSkipHistoryRecording() throws {
        let storeURL = temporaryFile("private-history-store")
        let profileURL = temporaryFile("private-history-profiles")
        let historyURL = temporaryFile("private-history")
        let zoomURL = temporaryFile("private-history-zoom")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: profileURL)
            try? FileManager.default.removeItem(at: historyURL)
            try? FileManager.default.removeItem(at: zoomURL)
        }
        let model = AppModel(
            store: AppStore(fileURL: storeURL),
            profileStore: ProfileStore(fileURL: profileURL)
        )
        let normalWorkspaceID = model.activeWorkspaceID
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore(),
            historyStore: HistoryStore(fileURL: historyURL),
            zoomStore: ZoomStore(fileURL: zoomURL)
        )

        model.addPrivateWorkspace()
        let privateTab = model.addApp(
            title: "Private Page",
            urlString: "https://private.example/page"
        )
        manager.activate(privateTab.id)
        let privateURL = try XCTUnwrap(URL(string: "https://private.example/page"))
        factory.engines[0].publish(NavState(
            isLoading: false,
            url: privateURL,
            title: "Private Page"
        ))

        XCTAssertTrue(manager.historyEntries.isEmpty)

        model.selectWorkspace(normalWorkspaceID)
        let normalTab = try XCTUnwrap(model.apps.first?.id)
        manager.activate(normalTab)
        factory.engines[1].publish(NavState(
            isLoading: false,
            url: URL(string: "https://public.example/page"),
            title: "Public Page"
        ))

        XCTAssertEqual(manager.historyEntries.map(\.urlString), ["https://public.example/page"])
    }

    func testPrivateDownloadsStayInMemoryOnly() {
        let downloadsURL = temporaryFile("private-downloads")
        defer { try? FileManager.default.removeItem(at: downloadsURL) }
        let store = DownloadStore(fileURL: downloadsURL)

        store.update(download(id: 41, state: .completed), persist: false)
        store.update(download(id: 42, state: .downloading), persist: false)
        store.setPaused(42, true)

        XCTAssertEqual(store.records.map(\.id), [42, 41])
        XCTAssertTrue(store.isPaused(42))
        XCTAssertNil(store.record(for: 41))
        XCTAssertNil(store.record(for: 42))

        store.update(download(id: 43, state: .completed))

        XCTAssertEqual(store.records.map(\.id), [42, 43, 41])
        XCTAssertEqual(store.record(for: 43)?.state, .completed)

        let reloaded = DownloadStore(fileURL: downloadsURL)
        XCTAssertEqual(reloaded.records.map(\.id), [43])
        XCTAssertFalse(reloaded.isPaused(42))
    }

    func testPrivateDownloadsDoNotPersistThroughTheManager() {
        let storeURL = temporaryFile("private-manager-store")
        let profileURL = temporaryFile("private-manager-profiles")
        let downloadsURL = temporaryFile("private-manager-downloads")
        let historyURL = temporaryFile("private-manager-history")
        let zoomURL = temporaryFile("private-manager-zoom")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: profileURL)
            try? FileManager.default.removeItem(at: downloadsURL)
            try? FileManager.default.removeItem(at: historyURL)
            try? FileManager.default.removeItem(at: zoomURL)
        }
        let model = AppModel(
            store: AppStore(fileURL: storeURL),
            profileStore: ProfileStore(fileURL: profileURL)
        )
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore(),
            historyStore: HistoryStore(fileURL: historyURL),
            zoomStore: ZoomStore(fileURL: zoomURL),
            downloadStore: DownloadStore(fileURL: downloadsURL)
        )

        model.addPrivateWorkspace()
        let tab = model.addApp(
            title: "Private Download",
            urlString: "https://private.example/file.zip"
        )
        manager.activate(tab.id)
        factory.engines[0].publish(download(id: 5, state: .completed))

        XCTAssertEqual(manager.downloads.records.map(\.id), [5])
        XCTAssertNil(manager.downloads.record(for: 5))
        XCTAssertTrue(DownloadStore(fileURL: downloadsURL).records.isEmpty)
    }

    private func makeModel() -> AppModel {
        let storeURL = temporaryFile("private-space")
        let profileURL = temporaryFile("private-space-profile")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: profileURL)
        }
        return AppModel(
            store: AppStore(fileURL: storeURL),
            profileStore: ProfileStore(fileURL: profileURL)
        )
    }

    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-\(name)-\(UUID().uuidString).json")
    }

    private func download(id: UInt32, state: WebDownloadState) -> WebDownload {
        WebDownload(
            id: id,
            url: URL(string: "https://example.com/file-\(id).zip"),
            fileName: "file-\(id).zip",
            receivedBytes: state == .downloading ? 10 : 100,
            totalBytes: 100,
            state: state,
            location: nil
        )
    }
}
