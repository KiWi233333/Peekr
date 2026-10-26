import AppKit
import XCTest
@testable import Peekr

@MainActor
final class NewTabWallpaperTests: XCTestCase {
    func testLegacySettingsUseNewTabDefaultsAndClampOverlay() throws {
        let legacy = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.newTabWallpaperEnabled)
        XCTAssertEqual(legacy.newTabWallpaperID, NewTabWallpaperCatalog.defaultID)
        XCTAssertFalse(legacy.newTabUsesCustomWallpaper)
        XCTAssertEqual(legacy.newTabWallpaperOverlay, 0.38)
        XCTAssertTrue(legacy.newTabShowBookmarks)
        XCTAssertTrue(legacy.newTabShowRecent)

        let decoded = try JSONDecoder().decode(
            SettingsData.self,
            from: Data(#"{"newTabWallpaperOverlay":4}"#.utf8)
        )
        XCTAssertEqual(decoded.newTabWallpaperOverlay, 0.85)
    }

    func testNewTabSettingsPersistAcrossInstances() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-newtab-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = Settings(store: SettingsStore(fileURL: url))
        settings.newTabWallpaperEnabled = false
        settings.newTabWallpaperID = "monet-coast"
        settings.newTabUsesCustomWallpaper = true
        settings.newTabCustomWallpaperPath = "/tmp/wallpaper.webp"
        settings.newTabWallpaperOverlay = 0.62
        settings.newTabShowBookmarks = false
        settings.newTabShowRecent = false

        settings.persist()
        let restored = Settings(store: SettingsStore(fileURL: url))

        XCTAssertFalse(restored.newTabWallpaperEnabled)
        XCTAssertEqual(restored.newTabWallpaperID, "monet-coast")
        XCTAssertTrue(restored.newTabUsesCustomWallpaper)
        XCTAssertEqual(restored.newTabCustomWallpaperPath, "/tmp/wallpaper.webp")
        XCTAssertEqual(restored.newTabWallpaperOverlay, 0.62)
        XCTAssertFalse(restored.newTabShowBookmarks)
        XCTAssertFalse(restored.newTabShowRecent)
    }

    func testUnknownWallpaperFallsBackToDefault() {
        XCTAssertEqual(NewTabWallpaperCatalog.item(id: "missing").id, NewTabWallpaperCatalog.defaultID)
        XCTAssertEqual(NewTabWallpaperCatalog.items.count, 6)
        XCTAssertEqual(Set(NewTabWallpaperCatalog.items.map(\.id)).count, 6)
    }

    func testCustomWallpaperImportLoadAndRemove() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-wallpaper-source-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: source) }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let data = try XCTUnwrap(bitmap?.representation(using: .png, properties: [:]))
        try data.write(to: source)

        let path = try NewTabWallpaperStorage.importImage(from: source)
        let image = NewTabWallpaperCatalog.image(selectedID: "missing", usesCustom: true, customPath: path)
        XCTAssertEqual(image?.size.width, 2)
        NewTabWallpaperStorage.removeCustomImage(atPath: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testInvalidCustomWallpaperIsRejected() {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-invalid-wallpaper-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertNoThrow(try Data("not an image".utf8).write(to: source))
        XCTAssertThrowsError(try NewTabWallpaperStorage.importImage(from: source))
    }
}
