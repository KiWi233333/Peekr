import Foundation
import XCTest
@testable import Peekr

final class ChromeSessionImporterTests: XCTestCase {
    func testReadsTabsGroupsPinningAndActiveTabFromSNSS() throws {
        let windowID: Int32 = 42
        let firstTabID: Int32 = 100
        let secondTabID: Int32 = 101
        let groupID = ChromeSessionGroupID(high: 0x1111, low: 0x2222)

        var file = Data("SNSS".utf8)
        file.appendUInt32(3)
        file.append(command: 0, payload: data { $0.appendInt32(windowID); $0.appendInt32(firstTabID) })
        file.append(command: 0, payload: data { $0.appendInt32(windowID); $0.appendInt32(secondTabID) })
        file.append(command: 2, payload: data { $0.appendInt32(firstTabID); $0.appendInt32(0) })
        file.append(command: 2, payload: data { $0.appendInt32(secondTabID); $0.appendInt32(1) })
        file.append(command: 6, payload: navigation(
            tabID: firstTabID,
            index: 0,
            url: "https://example.com/one",
            title: "One"
        ))
        file.append(command: 6, payload: navigation(
            tabID: secondTabID,
            index: 0,
            url: "https://example.com/two",
            title: "二"
        ))
        file.append(command: 12, payload: data {
            $0.appendInt32(firstTabID)
            $0.appendUInt8(1)
            $0.append(contentsOf: repeatElement(0, count: 3))
        })
        file.append(command: 25, payload: data {
            $0.appendInt32(secondTabID)
            $0.appendUInt32(0)
            $0.appendUInt64(groupID.high)
            $0.appendUInt64(groupID.low)
            $0.appendUInt8(1)
            $0.append(contentsOf: repeatElement(0, count: 7))
        })
        file.append(command: 27, payload: groupMetadata(
            id: groupID,
            name: "Research",
            color: 6,
            collapsed: true
        ))
        file.append(command: 8, payload: data { $0.appendInt32(windowID); $0.appendInt32(1) })
        file.append(command: 20, payload: data { $0.appendInt32(windowID) })
        file.append(command: 255, payload: Data())

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Peekr-Session-\(UUID().uuidString)")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try ChromeSessionImporter.readSessionFile(at: url)

        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.tabCount, 2)
        XCTAssertEqual(snapshot.groupCount, 1)
        XCTAssertEqual(snapshot.windows[0].selectedTabIndex, 1)
        XCTAssertTrue(snapshot.windows[0].isActive)
        XCTAssertEqual(snapshot.windows[0].tabs.map(\.urlString), [
            "https://example.com/one",
            "https://example.com/two",
        ])
        XCTAssertTrue(snapshot.windows[0].tabs[0].isPinned)
        XCTAssertEqual(snapshot.windows[0].tabs[1].title, "二")
        XCTAssertEqual(snapshot.groups[0].name, "Research")
        XCTAssertEqual(snapshot.groups[0].color, .purple)
        XCTAssertTrue(snapshot.groups[0].isCollapsed)
    }

    func testRejectsSessionWithoutMarker() throws {
        var file = Data("SNSS".utf8)
        file.appendUInt32(3)
        file.append(command: 20, payload: data { $0.appendInt32(1) })

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Peekr-Session-\(UUID().uuidString)")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ChromeSessionImporter.readSessionFile(at: url)) { error in
            guard case ChromeSessionImportError.malformed(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "session marker is missing")
        }
    }

    @MainActor
    func testAppModelImportsChromeOrderGroupVisualsAndSelection() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Peekr-Session-Model-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let model = AppModel(store: AppStore(fileURL: storeURL))
        let groupID = ChromeSessionGroupID(high: 1, low: 2)
        let session = ChromeSessionSnapshot(
            windows: [ChromeSessionWindow(
                tabs: [
                    ChromeSessionTab(title: "A", urlString: "https://a.example", isPinned: false, groupID: groupID),
                    ChromeSessionTab(title: "B", urlString: "https://b.example", isPinned: true, groupID: nil),
                ],
                selectedTabIndex: 0,
                isActive: true,
                title: ""
            )],
            groups: [ChromeSessionGroup(
                id: groupID,
                name: "Research",
                color: .orange,
                isCollapsed: true
            )]
        )

        let result = model.importChromeSession(session)

        XCTAssertEqual(result.importedTabIDs.count, 2)
        XCTAssertEqual(model.allTabs.map(\.urlString).suffix(2), ["https://a.example", "https://b.example"])
        XCTAssertEqual(model.activeWorkspace.sidebarItems.map(\.kind), [.tab, .tab, .group])
        XCTAssertEqual(
            model.apps.map(\.urlString),
            ["https://b.example", "https://www.google.com/", "https://a.example"]
        )
        XCTAssertEqual(model.selectedID, result.importedTabIDs[0])
        XCTAssertEqual(model.activeWorkspace.groups.count, 1)
        XCTAssertEqual(model.activeWorkspace.groups[0].name, "Research")
        XCTAssertEqual(model.activeWorkspace.groups[0].color, .orange)
        XCTAssertTrue(model.activeWorkspace.groups[0].isCollapsed)
    }

    private func data(_ body: (inout Data) -> Void) -> Data {
        var result = Data()
        body(&result)
        return result
    }

    private func navigation(tabID: Int32, index: Int32, url: String, title: String) -> Data {
        let body = data {
            $0.appendInt32(tabID)
            $0.appendInt32(index)
            $0.appendString(url)
            $0.appendString16(title)
            $0.appendString("")
            $0.appendInt32(0)
        }
        return data {
            $0.appendUInt32(UInt32(body.count))
            $0.append(body)
        }
    }

    private func groupMetadata(
        id: ChromeSessionGroupID,
        name: String,
        color: UInt32,
        collapsed: Bool
    ) -> Data {
        let body = data {
            $0.appendUInt64(id.high)
            $0.appendUInt64(id.low)
            $0.appendString16(name)
            $0.appendUInt32(color)
            $0.appendUInt8(collapsed ? 1 : 0)
            $0.appendUInt8(0)
        }
        return data {
            $0.appendUInt32(UInt32(body.count))
            $0.append(body)
        }
    }
}

private extension Data {
    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        for index in 0..<4 { append(UInt8(truncatingIfNeeded: value >> UInt32(index * 8))) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        for index in 0..<8 { append(UInt8(truncatingIfNeeded: value >> UInt64(index * 8))) }
    }

    mutating func appendInt32(_ value: Int32) {
        appendUInt32(UInt32(bitPattern: value))
    }

    mutating func appendString(_ value: String) {
        let bytes = Data(value.utf8)
        appendInt32(Int32(bytes.count))
        append(bytes)
        appendPadding(for: bytes.count)
    }

    mutating func appendString16(_ value: String) {
        let bytes = Data(value.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
        appendInt32(Int32(value.utf16.count))
        append(bytes)
        appendPadding(for: bytes.count)
    }

    mutating func appendPadding(for byteCount: Int) {
        append(contentsOf: repeatElement(0, count: (4 - (byteCount % 4)) % 4))
    }

    mutating func append(command id: UInt8, payload: Data) {
        let size = UInt16(payload.count + 1)
        appendUInt16(size)
        appendUInt8(id)
        append(payload)
    }
}
