import XCTest
@testable import Peekr

@MainActor
final class BrowsingDataCleanerTests: XCTestCase {
    private struct Harness {
        let cleaner: BrowsingDataCleaner
        let files: [URL]
    }

    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-\(name)-\(UUID().uuidString).json")
    }

    private func makeHarness() -> Harness {
        let historyURL = temporaryFile("clear-history")
        let downloadsURL = temporaryFile("clear-downloads")
        let permissionsURL = temporaryFile("clear-permissions")
        let zoomURL = temporaryFile("clear-zoom")
        let cleaner = BrowsingDataCleaner(
            history: HistoryStore(fileURL: historyURL),
            downloads: DownloadStore(fileURL: downloadsURL),
            permissions: SitePermissionStore(fileURL: permissionsURL),
            zoom: ZoomStore(fileURL: zoomURL)
        )
        return Harness(
            cleaner: cleaner,
            files: [historyURL, downloadsURL, permissionsURL, zoomURL]
        )
    }

    private func cleanup(_ harness: Harness) {
        for file in harness.files {
            try? FileManager.default.removeItem(at: file)
        }
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

    private func seed(_ cleaner: BrowsingDataCleaner) {
        cleaner.history.record(
            url: URL(string: "https://example.com/article")!,
            title: "Example article"
        )
        cleaner.downloads.update(download(id: 1, state: .completed))
        cleaner.downloads.update(download(id: 2, state: .downloading))
        cleaner.permissions.remember(
            origin: "https://example.com",
            permission: .camera,
            allowed: true
        )
        cleaner.zoom.set(2, for: "https://example.com")
    }

    func testAllOptionsClearEveryStoreAndCEFData() {
        let harness = makeHarness()
        defer { cleanup(harness) }
        let cleaner = harness.cleaner
        seed(cleaner)

        var cefCalls: [(cookies: Bool, cache: Bool)] = []
        var completions = 0
        cleaner.clearCEFData = { cookies, cache, completion in
            cefCalls.append((cookies, cache))
            completion()
        }

        cleaner.clear(BrowsingDataSelection()) { completions += 1 }

        XCTAssertEqual(completions, 1)
        XCTAssertEqual(cefCalls.count, 1)
        XCTAssertEqual(cefCalls.first?.cookies, true)
        XCTAssertEqual(cefCalls.first?.cache, true)
        XCTAssertTrue(cleaner.history.entries.isEmpty)
        XCTAssertEqual(cleaner.downloads.records.map(\.id), [2])
        XCTAssertTrue(cleaner.permissions.isEmpty)
        XCTAssertEqual(cleaner.zoom.level(for: "https://example.com"), 0)
        XCTAssertEqual(cleaner.zoom.defaultLevel, 0)
    }

    func testOnlyLocalOptionsNeverTouchCEF() {
        let harness = makeHarness()
        defer { cleanup(harness) }
        let cleaner = harness.cleaner
        seed(cleaner)

        var cefCalls = 0
        var completions = 0
        cleaner.clearCEFData = { _, _, completion in
            cefCalls += 1
            completion()
        }

        var selection = BrowsingDataSelection()
        selection.cookies = false
        selection.cache = false
        cleaner.clear(selection) { completions += 1 }

        XCTAssertEqual(cefCalls, 0)
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(cleaner.history.entries.isEmpty)
        XCTAssertEqual(cleaner.downloads.records.map(\.id), [2])
        XCTAssertTrue(cleaner.permissions.isEmpty)
        XCTAssertEqual(cleaner.zoom.level(for: "https://example.com"), 0)
    }

    func testOnlyCookiesPassesCookiesWithoutCache() {
        let harness = makeHarness()
        defer { cleanup(harness) }
        let cleaner = harness.cleaner
        seed(cleaner)

        var cefCalls: [(cookies: Bool, cache: Bool)] = []
        var completions = 0
        cleaner.clearCEFData = { cookies, cache, completion in
            cefCalls.append((cookies, cache))
            completion()
        }

        var selection = BrowsingDataSelection()
        selection.history = false
        selection.downloads = false
        selection.permissions = false
        selection.zoom = false
        selection.cache = false
        cleaner.clear(selection) { completions += 1 }

        XCTAssertEqual(completions, 1)
        XCTAssertEqual(cefCalls.count, 1)
        XCTAssertEqual(cefCalls.first?.cookies, true)
        XCTAssertEqual(cefCalls.first?.cache, false)
        XCTAssertFalse(cleaner.history.entries.isEmpty)
        XCTAssertEqual(cleaner.downloads.records.count, 2)
        XCTAssertFalse(cleaner.permissions.isEmpty)
        XCTAssertEqual(cleaner.zoom.level(for: "https://example.com"), 2)
    }

    func testEmptySelectionTouchesNothingButStillCompletes() {
        let harness = makeHarness()
        defer { cleanup(harness) }
        let cleaner = harness.cleaner
        seed(cleaner)

        var cefCalls = 0
        var completions = 0
        cleaner.clearCEFData = { _, _, completion in
            cefCalls += 1
            completion()
        }

        var selection = BrowsingDataSelection()
        selection.history = false
        selection.downloads = false
        selection.cookies = false
        selection.cache = false
        selection.permissions = false
        selection.zoom = false
        XCTAssertTrue(selection.isEmpty)

        cleaner.clear(selection) { completions += 1 }

        XCTAssertEqual(cefCalls, 0)
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(cleaner.history.entries.isEmpty)
        XCTAssertEqual(cleaner.downloads.records.count, 2)
        XCTAssertFalse(cleaner.permissions.isEmpty)
        XCTAssertEqual(cleaner.zoom.level(for: "https://example.com"), 2)
    }

    func testCleanerWaitsForAsynchronousCEFCompletion() {
        let harness = makeHarness()
        defer { cleanup(harness) }
        let cleaner = harness.cleaner
        seed(cleaner)

        var pending: (() -> Void)?
        var completions = 0
        cleaner.clearCEFData = { _, _, completion in
            pending = completion
        }

        cleaner.clear(BrowsingDataSelection()) { completions += 1 }

        XCTAssertEqual(completions, 0)
        XCTAssertNotNil(pending)
        XCTAssertTrue(cleaner.history.entries.isEmpty)

        pending?()
        pending?()

        XCTAssertEqual(completions, 1)
    }
}
