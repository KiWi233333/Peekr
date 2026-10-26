import CefKit
import XCTest
@testable import Peekr

@MainActor
final class DataSurfaceTests: XCTestCase {
    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-\(name)-\(UUID().uuidString).json")
    }

    private func download(
        id: UInt32,
        state: WebDownloadState,
        received: Int64 = 0,
        total: Int64 = 100,
        location: URL? = nil
    ) -> WebDownload {
        WebDownload(
            id: id,
            url: URL(string: "https://example.com/file-\(id).zip"),
            fileName: "file-\(id).zip",
            receivedBytes: received,
            totalBytes: total,
            state: state,
            location: location
        )
    }

    // MARK: - InternalPage

    func testInternalPageURLsRoundTrip() {
        let pages: [InternalPage] = [
            .newTab,
            .history,
            .downloads,
            .bookmarks,
            .settings,
            .siteSettings("https://example.com"),
            .siteSettings("https://example.com:8443/a&b=c?d"),
            .siteSettings(""),
            .clearData,
            .shortcuts,
        ]

        for page in pages {
            XCTAssertEqual(page.url.scheme, "peekr")
            XCTAssertTrue(InternalPage.isInternal(page.url))
            XCTAssertEqual(InternalPage.from(page.url), page)
            XCTAssertEqual(InternalPage.from(URL(string: page.urlString)!), page)
        }

        XCTAssertEqual(InternalPage.newTab.urlString, "peekr://newtab")
        XCTAssertEqual(InternalPage.clearData.urlString, "peekr://clear-data")
        XCTAssertEqual(InternalPage.siteSettings("").urlString, "peekr://site-settings")
        XCTAssertEqual(
            InternalPage.from(URL(string: "peekr://site-settings")!),
            .siteSettings("")
        )
        XCTAssertNil(InternalPage.from(URL(string: "https://example.com")!))
        XCTAssertFalse(InternalPage.isInternal(URL(string: "https://example.com")!))
    }

    func testInternalPageCodableRoundTripsThroughURL() throws {
        let page = InternalPage.siteSettings("https://example.com:8443")
        let data = try JSONEncoder().encode(page)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(encoded.contains("site-settings"))
        XCTAssertEqual(try JSONDecoder().decode(InternalPage.self, from: data), page)
    }

    // MARK: - Settings

    func testSettingsDecodeFillsMissingKeysAndClampsValues() throws {
        let legacy = Data(#"{"anchor":"left","panelWidth":480,"autoHide":false}"#.utf8)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: legacy)
        XCTAssertEqual(decoded.anchor, .left)
        XCTAssertEqual(decoded.panelWidth, 480)
        XCTAssertFalse(decoded.autoHide)
        XCTAssertEqual(decoded.homePage, "")
        XCTAssertEqual(decoded.startupBehavior, .newTab)
        XCTAssertEqual(decoded.downloadDirectory, "")
        XCTAssertFalse(decoded.askWhereToSave)
        XCTAssertEqual(decoded.defaultZoom, 0)
        XCTAssertTrue(decoded.rememberPermissions)
        XCTAssertTrue(decoded.blockPopups)
        XCTAssertEqual(decoded.historyRetentionDays, 0)

        let empty = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, SettingsData())

        let outOfRange = Data(
            #"{"defaultZoom":12,"historyRetentionDays":-4,"startupBehavior":"sometimes"}"#.utf8
        )
        let clamped = try JSONDecoder().decode(SettingsData.self, from: outOfRange)
        XCTAssertEqual(clamped.defaultZoom, 5)
        XCTAssertEqual(clamped.historyRetentionDays, 0)
        XCTAssertEqual(clamped.startupBehavior, .newTab)
    }

    // MARK: - History

    private struct LegacyHistoryEntry: Codable {
        let urlString: String
        let title: String
        let lastVisited: Date
    }

    func testHistoryMigratesV1EntriesAndCountsVisits() throws {
        let fileURL = temporaryFile("history")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let newer = old.addingTimeInterval(60)
        let legacy = [
            LegacyHistoryEntry(urlString: "https://old.example", title: "Old", lastVisited: old),
            LegacyHistoryEntry(urlString: "https://new.example", title: "New", lastVisited: newer),
        ]
        try JSONEncoder().encode(legacy).write(to: fileURL)

        let store = HistoryStore(fileURL: fileURL)
        XCTAssertEqual(store.entries.map(\.urlString), ["https://new.example", "https://old.example"])
        let migrated = try XCTUnwrap(store.entries.last)
        XCTAssertEqual(migrated.visitCount, 1)
        XCTAssertEqual(migrated.firstVisited, old)
        XCTAssertEqual(migrated.lastVisited, old)

        store.record(url: URL(string: "https://old.example")!, title: "Old, updated")
        let revisited = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(revisited.urlString, "https://old.example")
        XCTAssertEqual(revisited.title, "Old, updated")
        XCTAssertEqual(revisited.visitCount, 2)
        XCTAssertEqual(revisited.firstVisited, old)
        XCTAssertGreaterThan(revisited.lastVisited, old)
        XCTAssertEqual(HistoryStore(fileURL: fileURL).entries, store.entries)
    }

    func testHistorySearchTopSitesRemovalAndPruning() throws {
        let fileURL = temporaryFile("history")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = HistoryStore(fileURL: fileURL)

        store.record(url: URL(string: "https://example.com/alpha")!, title: "Alpha")
        store.record(url: URL(string: "https://other.example/beta")!, title: "Beta")
        store.record(url: URL(string: "https://example.com/alpha")!, title: "Alpha")

        XCTAssertEqual(store.search("EXAMPLE").count, 2)
        XCTAssertEqual(store.search("beta").map(\.urlString), ["https://other.example/beta"])
        XCTAssertEqual(store.search("alpha").first?.visitCount, 2)
        XCTAssertEqual(store.search("", limit: 1).map(\.urlString), ["https://example.com/alpha"])
        XCTAssertTrue(store.search("nothing").isEmpty)
        XCTAssertTrue(store.search("alpha", limit: 0).isEmpty)

        XCTAssertEqual(store.topSites(limit: 1).map(\.urlString), ["https://example.com/alpha"])

        store.remove(urlString: "https://example.com/alpha")
        XCTAssertEqual(store.entries.map(\.urlString), ["https://other.example/beta"])
        store.removeAll()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(HistoryStore(fileURL: fileURL).entries.isEmpty)

        let recent = Date()
        let stale = recent.addingTimeInterval(-60 * 86_400)
        let legacy = [
            LegacyHistoryEntry(urlString: "https://stale.example", title: "Stale", lastVisited: stale),
            LegacyHistoryEntry(urlString: "https://recent.example", title: "Recent", lastVisited: recent),
        ]
        try JSONEncoder().encode(legacy).write(to: fileURL)
        let pruned = HistoryStore(fileURL: fileURL)
        pruned.prune(olderThan: 30)
        XCTAssertEqual(pruned.entries.map(\.urlString), ["https://recent.example"])
    }

    func testHistorySkipsNonRecordableSchemes() {
        let fileURL = temporaryFile("history")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = HistoryStore(fileURL: fileURL)

        for raw in [
            "peekr://history",
            "about:blank",
            "data:text/plain,hello",
            "javascript:alert(1)",
            "chrome://settings",
        ] {
            store.record(url: URL(string: raw)!, title: raw)
        }
        XCTAssertTrue(store.entries.isEmpty)

        store.record(url: URL(string: "https://example.com")!, title: "Example")
        XCTAssertEqual(store.entries.map(\.urlString), ["https://example.com"])
    }

    // MARK: - Downloads

    func testDownloadStorePersistsAcrossInstances() throws {
        let fileURL = temporaryFile("downloads")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = DownloadStore(fileURL: fileURL)
        store.update(download(id: 1, state: .downloading, received: 10))
        store.setPaused(1, true)
        XCTAssertTrue(store.isPaused(1))
        XCTAssertEqual(store.activeCount, 1)

        let startedAt = try XCTUnwrap(store.record(for: 1)?.startedAt)
        let location = URL(fileURLWithPath: "/tmp/file-1.zip")
        store.update(download(id: 1, state: .completed, received: 100, location: location))

        XCTAssertFalse(store.isPaused(1))
        let record = try XCTUnwrap(store.record(for: 1))
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.startedAt, startedAt)
        XCTAssertNotNil(record.endedAt)
        XCTAssertEqual(record.location, location)

        let reloaded = DownloadStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records.first?.state, .completed)
        XCTAssertEqual(reloaded.record(for: 1)?.startedAt, startedAt)
        XCTAssertEqual(reloaded.record(for: 1)?.location, location)
    }

    func testDownloadStoreRecoversInterruptedActiveRecords() throws {
        let fileURL = temporaryFile("downloads")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = DownloadStore(fileURL: fileURL)
        store.update(download(id: 7, state: .downloading, received: 25))
        store.setPaused(7, true)

        let reloaded = DownloadStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.activeCount, 0)
        XCTAssertFalse(reloaded.isPaused(7))
        let recovered = try XCTUnwrap(reloaded.record(for: 7))
        XCTAssertEqual(recovered.state, .failed)
        XCTAssertFalse(recovered.isPaused)
        XCTAssertNil(recovered.endedAt)
    }

    func testDownloadStoreReidentifiesHistoricalRowWhenCEFReusesAnID() {
        let fileURL = temporaryFile("downloads")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = DownloadStore(fileURL: fileURL)
        store.update(download(id: 1, state: .completed, received: 100))

        let reloaded = DownloadStore(fileURL: fileURL)
        reloaded.update(download(id: 1, state: .downloading, received: 0))

        XCTAssertEqual(reloaded.records.count, 2)
        XCTAssertEqual(reloaded.record(for: 1)?.state, .downloading)
        XCTAssertEqual(reloaded.records.filter { $0.state == .completed }.count, 1)
    }

    func testDownloadStoreRemoveAndClearFinishedPersist() {
        let fileURL = temporaryFile("downloads")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = DownloadStore(fileURL: fileURL)
        store.update(download(id: 1, state: .downloading, received: 5))
        store.update(download(id: 2, state: .completed, received: 100))
        store.update(download(id: 3, state: .canceled))
        store.setPaused(1, true)

        store.clearFinished()
        XCTAssertEqual(store.records.map(\.id), [1])
        XCTAssertTrue(store.isPaused(1))
        XCTAssertEqual(DownloadStore(fileURL: fileURL).records.map(\.id), [1])

        store.remove(id: 1)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(store.isPaused(1))
        XCTAssertTrue(DownloadStore(fileURL: fileURL).records.isEmpty)
    }

    // MARK: - Bookmarks

    func testBookmarkCRUDMoveAndExport() throws {
        let fileURL = temporaryFile("bookmarks")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let model = BookmarksModel(store: BookmarkStore(fileURL: fileURL))

        XCTAssertTrue(model.isEmpty)
        XCTAssertTrue(model.add(title: "Example", urlString: "https://example.com"))
        XCTAssertFalse(model.add(title: "Duplicate", urlString: "https://example.com"))
        XCTAssertTrue(model.contains(urlString: "https://example.com"))
        let example = try XCTUnwrap(model.bookmark(for: "https://example.com"))
        XCTAssertEqual(example.title, "Example")

        let workID = try XCTUnwrap(model.createFolder(name: " Work ", in: nil))
        XCTAssertEqual(model.roots.last?.title, "Work")
        XCTAssertNil(model.createFolder(name: "   ", in: nil))
        XCTAssertNil(model.createFolder(name: "Missing", in: UUID()))

        XCTAssertTrue(model.add(title: "Docs", urlString: "https://example.com/docs", toFolder: workID))
        let nestedID = try XCTUnwrap(model.createFolder(name: "Nested", in: workID))
        XCTAssertTrue(model.add(
            title: "Nested link",
            urlString: "https://example.com/nested",
            toFolder: nestedID
        ))
        XCTAssertFalse(model.add(
            title: "Orphan",
            urlString: "https://example.com/orphan",
            toFolder: UUID()
        ))

        XCTAssertEqual(model.allBookmarks().count, 3)
        XCTAssertEqual(model.search("DOCS").map(\.urlString), ["https://example.com/docs"])
        XCTAssertTrue(model.search("work").isEmpty)

        model.update(id: example.id, title: "Example 2", urlString: nil)
        XCTAssertEqual(model.bookmark(for: "https://example.com")?.title, "Example 2")
        model.update(id: workID, title: "Job", urlString: nil)
        XCTAssertEqual(model.roots.last?.title, "Job")
        XCTAssertEqual(model.roots.last?.children?.count, 2)

        model.move(id: example.id, toFolder: workID, at: 0)
        XCTAssertEqual(model.roots.count, 1)
        let job = try XCTUnwrap(model.roots.first)
        XCTAssertEqual(job.children?.first?.title, "Example 2")
        XCTAssertEqual(job.children?.count, 3)

        model.move(id: workID, toFolder: nestedID, at: nil)
        XCTAssertEqual(model.roots.count, 1)
        XCTAssertEqual(model.roots.first?.title, "Job")
        let nested = try XCTUnwrap(model.roots.first?.children?.last)
        XCTAssertEqual(nested.title, "Nested")
        XCTAssertEqual(nested.children?.count, 1)

        model.move(id: example.id, toFolder: nil, at: 1)
        XCTAssertEqual(model.roots.map(\.title), ["Job", "Example 2"])

        let html = model.exportHTML()
        XCTAssertTrue(html.contains("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        XCTAssertTrue(html.contains("<DT><H3>Job</H3>"))
        XCTAssertTrue(html.contains("<DT><H3>Nested</H3>"))
        XCTAssertTrue(html.contains("HREF=\"https://example.com/nested\""))
        XCTAssertTrue(html.hasSuffix("</DL><p>\n"))

        let reloaded = BookmarksModel(store: BookmarkStore(fileURL: fileURL))
        XCTAssertEqual(reloaded.roots.map(\.title), ["Job", "Example 2"])
        XCTAssertTrue(reloaded.contains(urlString: "https://example.com/docs"))
        XCTAssertTrue(reloaded.contains(urlString: "https://example.com/nested"))

        reloaded.remove(workID)
        XCTAssertFalse(reloaded.contains(urlString: "https://example.com/docs"))
        XCTAssertTrue(reloaded.contains(urlString: "https://example.com"))
    }

    func testBookmarkExportEscapesHTML() {
        let fileURL = temporaryFile("bookmarks")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let model = BookmarksModel(store: BookmarkStore(fileURL: fileURL))

        model.add(title: "A & B <tag>", urlString: "https://example.com/?a=1&b=2")
        let html = model.exportHTML()
        XCTAssertTrue(html.contains("A &amp; B &lt;tag&gt;"))
        XCTAssertTrue(html.contains("HREF=\"https://example.com/?a=1&amp;b=2\""))
    }

    // MARK: - Site permissions

    func testSitePermissionStoreNormalizesAndRemembers() {
        let store = SitePermissionStore()
        XCTAssertTrue(store.isEmpty)

        store.remember(origin: "https://Example.com/path/", permission: .camera, allowed: true)
        XCTAssertEqual(store.decision(origin: "https://example.com", permission: .camera), true)
        XCTAssertNil(store.decision(origin: "https://example.com", permission: .microphone))
        XCTAssertEqual(store.sites["https://example.com"], [.camera: true])
        XCTAssertFalse(store.isEmpty)

        store.remember(
            origin: "https://example.com",
            permissions: [.microphone, .notifications],
            allowed: false
        )
        XCTAssertEqual(store.decision(origin: "https://example.com/", permission: .microphone), false)
        XCTAssertEqual(store.sites["https://example.com"]?.count, 3)

        XCTAssertEqual(SitePermissionStore.normalize("HTTPS://Example.com/"), "https://example.com")
        XCTAssertEqual(SitePermissionStore.normalize(" Example.COM/ "), "example.com")
        XCTAssertEqual(
            SitePermissionStore.normalize("https://example.com:8443/a"),
            "https://example.com:8443"
        )

        store.forget(origin: "https://example.com/")
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.decision(origin: "https://example.com", permission: .camera))
    }

    func testSitePermissionStorePersistsAndForgetsAll() {
        let fileURL = temporaryFile("permissions")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = SitePermissionStore(fileURL: fileURL)
        store.remember(origin: "https://example.com", permission: .geolocation, allowed: false)

        let reloaded = SitePermissionStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.decision(origin: "https://example.com/", permission: .geolocation), false)
        XCTAssertEqual(reloaded.sites["https://example.com"], [.geolocation: false])

        reloaded.forgetAll()
        XCTAssertTrue(reloaded.isEmpty)
        XCTAssertTrue(SitePermissionStore(fileURL: fileURL).isEmpty)
    }

    // MARK: - Zoom

    func testZoomStoreDefaultFallbackAndLegacyFileCompatibility() {
        let fileURL = temporaryFile("zoom")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try? Data(#"{"https://example.com":3}"#.utf8).write(to: fileURL)

        var store = ZoomStore(fileURL: fileURL)
        XCTAssertEqual(store.defaultLevel, 0)
        XCTAssertEqual(store.level(for: "https://example.com"), 3)
        XCTAssertEqual(store.level(for: "https://other.example"), 0)

        store.setDefault(8)
        XCTAssertEqual(store.defaultLevel, 5)
        XCTAssertEqual(store.level(for: "https://other.example"), 5)

        store.set(-1, for: "https://other.example")
        XCTAssertEqual(store.level(for: "https://other.example"), -1)
        store.reset(for: "https://other.example")
        XCTAssertEqual(store.level(for: "https://other.example"), 5)

        store.set(0, for: "https://example.com")
        XCTAssertEqual(store.level(for: "https://example.com"), 0)

        let reloaded = ZoomStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.defaultLevel, 5)
        XCTAssertEqual(reloaded.level(for: "https://example.com"), 0)

        var clearable = reloaded
        clearable.clear()
        let cleared = ZoomStore(fileURL: fileURL)
        XCTAssertEqual(cleared.defaultLevel, 0)
        XCTAssertEqual(cleared.level(for: "https://other.example"), 0)
    }

    // MARK: - Permission mapping

    func testPermissionKindMapping() {
        let all: CefPermissionKind = [
            .camera, .microphone, .geolocation, .notifications, .clipboard,
            .midi, .pointerLock, .storageAccess, .sensors, .windowManagement,
            .downloads, .other,
        ]
        XCTAssertEqual(CefPermissionPrompt.permissions(for: all), SitePermissionStore.Permission.allCases)
        XCTAssertTrue(CefPermissionPrompt.permissions(for: []).isEmpty)
        XCTAssertEqual(
            CefPermissionPrompt.permissions(for: [.camera, .microphone]),
            [.camera, .microphone]
        )
    }

    // MARK: - Localization

    func testLocalizedShellStrings() {
        let english = Localized(isChinese: false)
        let chinese = Localized(isChinese: true)

        XCTAssertEqual(english.zoomLevel(0), "100%")
        XCTAssertEqual(english.zoomLevel(1), "120%")
        XCTAssertEqual(english.findMatchCount(current: 3, total: 9), "3/9")
        XCTAssertEqual(english.rememberForThisSite, "Remember for this site")
        XCTAssertEqual(chinese.newTab, "新建标签")
        XCTAssertEqual(chinese.history, "历史")
        XCTAssertEqual(chinese.rememberForThisSite, "记住此站点的选择")
    }
}
