import XCTest
@testable import Peekr

@MainActor
final class SearchEngineTests: XCTestCase {
    func testGoogleIsDefaultForFreshAndLegacySettings() throws {
        XCTAssertEqual(SettingsData().searchEngine, .google)

        let legacy = try JSONDecoder().decode(
            SettingsData.self,
            from: Data(#"{"webEngine":"system"}"#.utf8)
        )
        XCTAssertEqual(legacy.searchEngine, .google)

        let encoded = try JSONEncoder().encode(legacy)
        let encodedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNil(encodedObject["webEngine"])
    }

    func testEverySearchEngineBuildsItsOwnHomepageAndQueryURL() throws {
        let expected: [SearchEngine: (host: String, queryName: String)] = [
            .google: ("www.google.com", "q"),
            .bing: ("www.bing.com", "q"),
            .duckDuckGo: ("duckduckgo.com", "q"),
            .baidu: ("www.baidu.com", "wd"),
        ]

        for engine in SearchEngine.allCases {
            let values = try XCTUnwrap(expected[engine])
            XCTAssertEqual(engine.homepageURL.host, values.host)
            let url = try XCTUnwrap(engine.searchURL(for: "liquid glass & tabs"))
            XCTAssertEqual(url.host, values.host)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(
                components.queryItems?.first(where: { $0.name == values.queryName })?.value,
                "liquid glass & tabs"
            )
        }
    }

    func testInitialNewTabAndNewWorkspaceFollowCurrentSearchEngine() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-search-engine-\(UUID().uuidString).json")
        var selected: SearchEngine = .bing
        let model = AppModel(
            store: AppStore(fileURL: storeURL),
            searchEngine: { selected }
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storeURL) }

        XCTAssertEqual(model.apps.map(\.urlString), [SearchEngine.bing.homepageURL.absoluteString])

        selected = .duckDuckGo
        let tab = model.addBlankTab()
        XCTAssertEqual(tab.title, SearchEngine.duckDuckGo.displayName)
        XCTAssertEqual(tab.urlString, SearchEngine.duckDuckGo.homepageURL.absoluteString)

        selected = .baidu
        let workspace = model.addWorkspace()
        XCTAssertEqual(workspace.tabs.map(\.urlString), [SearchEngine.baidu.homepageURL.absoluteString])
        XCTAssertEqual(workspace.selectedTabID, workspace.tabs.first?.id)
    }

    func testOmniboxUsesSelectedEngineButKeepsURLsAsURLs() throws {
        let search = try XCTUnwrap(
            WebViewManager.url(fromOmnibox: "peekr browser", searchEngine: .bing)
        )
        XCTAssertEqual(search.host, "www.bing.com")
        XCTAssertEqual(
            URLComponents(url: search, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value,
            "peekr browser"
        )

        XCTAssertEqual(
            WebViewManager.url(fromOmnibox: "example.com", searchEngine: .baidu)?.absoluteString,
            "https://example.com"
        )
    }

    func testOmniboxTreatsLocalAddressesAndExplicitSchemesAsNavigation() throws {
        XCTAssertEqual(
            WebViewManager.url(fromOmnibox: "localhost")?.absoluteString,
            "http://localhost"
        )
        XCTAssertEqual(
            WebViewManager.url(fromOmnibox: "localhost:3000/dev")?.absoluteString,
            "http://localhost:3000/dev"
        )
        XCTAssertEqual(
            WebViewManager.url(fromOmnibox: "127.0.0.1:8080")?.absoluteString,
            "http://127.0.0.1:8080"
        )
        XCTAssertEqual(
            WebViewManager.url(fromOmnibox: "[::1]:3000")?.absoluteString,
            "http://[::1]:3000"
        )
        XCTAssertEqual(
            WebViewManager.url(fromOmnibox: "file:///tmp/report.html")?.absoluteString,
            "file:///tmp/report.html"
        )
        // …but bare words and dotted phrases still search.
        let search = try XCTUnwrap(WebViewManager.url(fromOmnibox: "local host", searchEngine: .duckDuckGo))
        XCTAssertEqual(search.host, "duckduckgo.com")
    }

    func testOmniboxSuggestionIdentityIsStableAcrossRefreshes() {
        let first = OmniboxSuggestion(
            kind: .tab,
            primary: "Peekr",
            secondary: "peekr.app",
            target: "https://peekr.app"
        )
        let refreshed = OmniboxSuggestion(
            kind: .tab,
            primary: "Peekr Browser",
            secondary: "peekr.app",
            target: "https://peekr.app"
        )
        let bookmark = OmniboxSuggestion(
            kind: .bookmark,
            primary: "Peekr",
            secondary: nil,
            target: "https://peekr.app"
        )

        XCTAssertEqual(first.id, refreshed.id)
        XCTAssertNotEqual(first.id, bookmark.id)
    }

    func testOmniboxPrefersRecentHistoryBeforeSearchAction() {
        let history = HistoryEntry(
            urlString: "https://docs.example/guide",
            title: "Guide",
            lastVisited: Date()
        )

        let suggestions = OmniboxSuggestions.local(
            for: "guide",
            tabs: [],
            bookmarks: [],
            history: [history],
            searchLabel: "Search with Google"
        )

        XCTAssertEqual(suggestions.first?.kind, .history)
        XCTAssertEqual(suggestions.first?.target, history.urlString)
        XCTAssertEqual(suggestions.dropFirst().first?.kind, .search)
    }

    func testOmniboxFallsBackToSearchWithoutMatchingHistory() {
        let suggestions = OmniboxSuggestions.local(
            for: "guide",
            tabs: [],
            bookmarks: [],
            history: [HistoryEntry(
                urlString: "https://news.example/home",
                title: "News",
                lastVisited: Date()
            )],
            searchLabel: "Search with Google"
        )

        XCTAssertEqual(suggestions.first?.kind, .search)
        XCTAssertEqual(suggestions.first?.target, "guide")
    }

    func testOmniboxRanksCurrentTabBeforeOtherTabsAndSearchAction() {
        let currentID = UUID()
        let other = WebApp(title: "Home", urlString: "https://x.com/home")
        let current = WebApp(id: currentID, title: "Profile", urlString: "https://x.com")

        let suggestions = OmniboxSuggestions.local(
            for: "x.com",
            tabs: [other, current],
            bookmarks: [],
            currentTabID: currentID,
            searchLabel: "Search with Google"
        )

        XCTAssertEqual(suggestions.prefix(2).map(\.kind), [.tab, .tab])
        XCTAssertEqual(suggestions[0].target, current.urlString)
        XCTAssertEqual(suggestions[1].target, other.urlString)
        XCTAssertEqual(suggestions[2].kind, .openURL)
    }
}
