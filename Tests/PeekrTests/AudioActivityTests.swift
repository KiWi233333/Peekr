import AppKit
import XCTest
@testable import Peekr

@MainActor
final class AudioActivityTests: XCTestCase {
    func testConsoleMessageMapsOnlyExplicitProbeValues() {
        XCTAssertEqual(
            CefSwiftEngine.audioActivity(fromConsoleMessage: "__PEEKR_AUDIO__:1"),
            .audible
        )
        XCTAssertEqual(
            CefSwiftEngine.audioActivity(fromConsoleMessage: "__PEEKR_AUDIO__:0"),
            .silent
        )

        XCTAssertNil(CefSwiftEngine.audioActivity(fromConsoleMessage: "__PEEKR_AUDIO__:"))
        XCTAssertNil(CefSwiftEngine.audioActivity(fromConsoleMessage: "__PEEKR_AUDIO__:2"))
        XCTAssertNil(CefSwiftEngine.audioActivity(fromConsoleMessage: "__PEEKR_AUDIO__:true"))
        XCTAssertNil(CefSwiftEngine.audioActivity(fromConsoleMessage: "__PEEKR_AUDIO__: 1"))
        XCTAssertNil(CefSwiftEngine.audioActivity(fromConsoleMessage: "__PEEKR_AUDIO__:1:0"))
        XCTAssertNil(CefSwiftEngine.audioActivity(fromConsoleMessage: "__PEEKR_AUDIO_SMOKE__:1"))
        XCTAssertNil(CefSwiftEngine.audioActivity(fromConsoleMessage: ""))
        XCTAssertNil(CefSwiftEngine.audioActivity(fromConsoleMessage: "console noise"))
    }

    func testAudibleAndSilentCallbacksTrackTheTab() {
        let (model, factory, manager, storeURL) = makeManager()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let id = model.apps[0].id
        manager.activate(id)

        XCTAssertTrue(model.audibleTabIDs.isEmpty)

        factory.engines[0].publishAudio(.audible)
        XCTAssertTrue(model.audibleTabIDs.contains(id))

        factory.engines[0].publishAudio(.silent)
        XCTAssertFalse(model.audibleTabIDs.contains(id))
    }

    func testClosingTheEngineRemovesTheAudibleTab() {
        let (model, factory, manager, storeURL) = makeManager()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let id = model.apps[0].id
        manager.activate(id)
        factory.engines[0].publishAudio(.audible)
        XCTAssertTrue(model.audibleTabIDs.contains(id))

        manager.discard(id)

        XCTAssertEqual(factory.engines[0].closeCount, 1)
        XCTAssertFalse(model.audibleTabIDs.contains(id))
    }

    func testMutedPageReportingAudibleStaysSilent() {
        let (model, factory, manager, storeURL) = makeManager()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let id = model.apps[0].id
        manager.activate(id)
        manager.toggleMute(id)
        XCTAssertTrue(model.tab(id)?.isMuted == true)

        factory.engines[0].publishAudio(.audible)

        XCTAssertEqual(factory.engines[0].activity.audio, .silent)
        XCTAssertFalse(model.audibleTabIDs.contains(id))

        manager.toggleMute(id)

        XCTAssertEqual(factory.engines[0].activity.audio, .audible)
        XCTAssertTrue(model.audibleTabIDs.contains(id))
    }

    func testActivationSeedsAudibleStateFromTheEngine() {
        let (model, factory, manager, storeURL) = makeManager()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let id = model.apps[0].id
        manager.activate(id)

        factory.engines[0].measuredAudio = .audible
        manager.activate(id)

        XCTAssertTrue(model.audibleTabIDs.contains(id))
    }

    func testCloseAllClearsEveryAudibleTab() {
        let (model, factory, manager, storeURL) = makeManager()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let id = model.apps[0].id
        manager.activate(id)
        factory.engines[0].publishAudio(.audible)
        XCTAssertTrue(model.audibleTabIDs.contains(id))

        manager.closeAll()

        XCTAssertTrue(model.audibleTabIDs.isEmpty)
    }

    private func makeManager() -> (AppModel, FakeFactory, WebViewManager, URL) {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-audio-\(UUID().uuidString).json")
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let factory = FakeFactory()
        let manager = WebViewManager(
            model: model,
            factory: factory,
            badges: BadgeStore(),
            icons: IconStore()
        )
        return (model, factory, manager, storeURL)
    }
}

@MainActor
private final class FakeEngine: WebEngine {
    let hostView = NSView()
    var navState = NavState()
    var onNavStateChange: ((NavState) -> Void)?
    var onDownloadChange: ((WebDownload) -> Void)?
    var onAudioActivityChange: ((WebAudioActivity) -> Void)?
    var measuredAudio: WebAudioActivity = .unknown
    var isAudioMuted = false
    private(set) var closeCount = 0

    var activity: WebActivitySnapshot {
        WebActivitySnapshot(audio: isAudioMuted ? .silent : measuredAudio)
    }

    func load(_ url: URL) {}
    func goBack() {}
    func goForward() {}
    func reload() {}
    func stopLoading() {}
    func close() { closeCount += 1 }
    func iconLinkURLs() async -> [URL] { [] }

    func publishAudio(_ audio: WebAudioActivity) {
        measuredAudio = audio
        onAudioActivityChange?(audio)
    }
}

@MainActor
private final class FakeFactory: WebEngineFactory {
    private(set) var engines: [FakeEngine] = []

    func makeEngine(for app: WebApp, profile: BrowserProfile) -> WebEngine {
        let engine = FakeEngine()
        engines.append(engine)
        return engine
    }
}
