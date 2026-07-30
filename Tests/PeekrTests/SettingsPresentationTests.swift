import XCTest
@testable import Peekr

@MainActor
final class SettingsPresentationTests: XCTestCase {
    func testAutoHidePolicyPreservesLegacyStorageMeaning() {
        XCTAssertEqual(
            AutoHidePolicy(autoHide: false, mode: .mouseLeave),
            .off
        )
        XCTAssertEqual(
            AutoHidePolicy(autoHide: true, mode: .focusLoss),
            .focusLoss
        )
        XCTAssertEqual(
            AutoHidePolicy(autoHide: true, mode: .mouseLeave),
            .mouseLeave
        )

        XCTAssertFalse(AutoHidePolicy.off.storedValues.autoHide)
        XCTAssertEqual(
            AutoHidePolicy.focusLoss.storedValues.mode,
            .focusLoss
        )
        XCTAssertEqual(
            AutoHidePolicy.mouseLeave.storedValues.mode,
            .mouseLeave
        )
    }

    func testRepeatedBrowserBookmarkImportRefreshesExistingFolder() {
        let existingID = UUID()
        let manual = BookmarkNode(title: "Manual", urlString: "https://example.com")
        let roots = [
            manual,
            BookmarkNode(
                id: existingID,
                title: "Chrome",
                children: [BookmarkNode(title: "Old", urlString: "https://old.example")]
            ),
        ]
        let refreshed = [
            BookmarkNode(title: "New", urlString: "https://new.example")
        ]

        let result = BookmarksModel.replacingImportedFolder(
            in: roots,
            folderName: "Chrome",
            with: refreshed
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], manual)
        XCTAssertEqual(result[1].id, existingID)
        XCTAssertEqual(result[1].children, refreshed)
    }

    func testFirstBrowserBookmarkImportAppendsFolder() {
        let roots = [
            BookmarkNode(title: "Manual", urlString: "https://example.com")
        ]
        let imported = [
            BookmarkNode(title: "Docs", urlString: "https://developer.apple.com")
        ]

        let result = BookmarksModel.replacingImportedFolder(
            in: roots,
            folderName: "Chrome",
            with: imported
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.last?.title, "Chrome")
        XCTAssertEqual(result.last?.children, imported)
    }
}
