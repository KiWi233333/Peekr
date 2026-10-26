import AppKit
import XCTest
@testable import Peekr

final class ProfileAvatarStoreTests: XCTestCase {
    private func makeChromeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-avatar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let localState = [
            "profile": [
                "last_used": "Default",
                "info_cache": [
                    "Default": ["name": "Default"],
                    "Profile 1": ["name": "Work"],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: localState)
        try data.write(to: root.appendingPathComponent("Local State"))
        return root
    }

    private func writeAvatar(in root: URL, profile: String, file: String) throws {
        let directory = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let data = try XCTUnwrap(bitmap?.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(file))
    }

    func testDefaultProfileReadsChromeAvatar() throws {
        let root = try makeChromeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAvatar(in: root, profile: "Default", file: "Google Profile Picture.png")

        let image = ProfileAvatarStore.image(for: .defaultProfile, chromeRoot: root)

        XCTAssertEqual(image?.size.width, 4)
    }

    func testAvatarThumbnailUsesRequestedLogicalSize() throws {
        let image = try XCTUnwrap(NSImage(named: NSImage.applicationIconName))

        let thumbnail = ProfileAvatarStore.thumbnail(from: image, size: 23)

        XCTAssertEqual(thumbnail.size, NSSize(width: 23, height: 23))
    }

    func testAvatarThumbnailHasTransparentCornersAndOpaqueCenter() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }

        let thumbnail = ProfileAvatarStore.thumbnail(from: image, size: 23)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: thumbnail.tiffRepresentation!))

        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
        XCTAssertEqual(bitmap.colorAt(x: 11, y: 11)?.alphaComponent, 1)
    }

    func testCustomProfileMatchesChromeDisplayNameAndFallbackFilename() throws {
        let root = try makeChromeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAvatar(in: root, profile: "Profile 1", file: "Profile Picture.png")

        let image = ProfileAvatarStore.image(for: BrowserProfile(name: "Work"), chromeRoot: root)

        XCTAssertEqual(image?.size.width, 4)
        XCTAssertNil(ProfileAvatarStore.image(for: BrowserProfile(name: "Missing"), chromeRoot: root))
        XCTAssertNil(ProfileAvatarStore.image(for: .incognitoProfile, chromeRoot: root))
    }
}
