import Foundation

/// The stable identifier Chrome writes for a tab group in its session log.
/// It is intentionally kept opaque: Peekr only needs identity, not Chrome's
/// internal UUID representation.
struct ChromeSessionGroupID: Hashable, Sendable {
    let high: UInt64
    let low: UInt64
}

struct ChromeSessionTab: Equatable, Sendable {
    let title: String
    let urlString: String
    let isPinned: Bool
    let groupID: ChromeSessionGroupID?
}

struct ChromeSessionGroup: Equatable, Sendable {
    let id: ChromeSessionGroupID
    let name: String
    let color: TabGroupColor
    let isCollapsed: Bool
}

struct ChromeSessionWindow: Equatable, Sendable {
    let tabs: [ChromeSessionTab]
    let selectedTabIndex: Int
    let isActive: Bool
    let title: String
}

struct ChromeSessionSnapshot: Equatable, Sendable {
    let windows: [ChromeSessionWindow]
    let groups: [ChromeSessionGroup]

    var tabCount: Int { windows.reduce(0) { $0 + $1.tabs.count } }
    var groupCount: Int {
        Set(windows.flatMap { window in window.tabs.compactMap(\.groupID) }).count
    }
}

struct ChromeSessionImportResult: Sendable {
    let importedTabIDs: [WebApp.ID]
    let importedWindowCount: Int
    let importedGroupCount: Int
    let selectedTabID: WebApp.ID?
}

enum ChromeSessionImportError: LocalizedError {
    case sessionDirectoryMissing
    case sessionFileMissing
    case unsupportedVersion(UInt32)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .sessionDirectoryMissing:
            return "The selected Chrome profile has no Sessions directory."
        case .sessionFileMissing:
            return "No readable Chrome session snapshot was found. Keep Chrome open and try again."
        case .unsupportedVersion(let version):
            return "Chrome's session format version \(version) is not supported by this Peekr version."
        case .malformed(let reason):
            return "Chrome's session snapshot could not be read: \(reason)"
        }
    }
}

/// Reads Chrome's clear-text SNSS session log. Chrome's current macOS session
/// files contain a replayable command stream rather than JSON; replaying only
/// the commands needed for tabs, groups, selection and pinning keeps this
/// importer independent of Chrome's private profile databases.
enum ChromeSessionImporter {
    private static let signature = Data("SNSS".utf8)
    private static let supportedVersion: UInt32 = 3
    private static let markerCommandID: UInt8 = 255

    private struct Navigation {
        let title: String
        let urlString: String
    }

    private struct TabState {
        var windowID: Int32?
        var visualIndex = Int32.max
        var pinned = false
        var selectedNavigationIndex: Int32 = 0
        var navigations: [Int32: Navigation] = [:]
        var groupID: ChromeSessionGroupID?
    }

    private struct WindowState {
        var selectedTabIndex = 0
        var title = ""
    }

    private struct BinaryReader {
        let data: Data
        var offset = 0

        var remaining: Int { data.count - offset }

        mutating func readUInt8() throws -> UInt8 {
            guard remaining >= 1 else { throw ChromeSessionImportError.malformed("truncated byte") }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func readUInt16() throws -> UInt16 {
            guard remaining >= 2 else { throw ChromeSessionImportError.malformed("truncated command size") }
            let value = UInt16(data[offset])
                | UInt16(data[offset + 1]) << 8
            offset += 2
            return value
        }

        mutating func readUInt32() throws -> UInt32 {
            guard remaining >= 4 else { throw ChromeSessionImportError.malformed("truncated 32-bit value") }
            let value = UInt32(data[offset])
                | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16
                | UInt32(data[offset + 3]) << 24
            offset += 4
            return value
        }

        mutating func readInt32() throws -> Int32 {
            Int32(bitPattern: try readUInt32())
        }

        mutating func readUInt64() throws -> UInt64 {
            guard remaining >= 8 else { throw ChromeSessionImportError.malformed("truncated 64-bit value") }
            var value: UInt64 = 0
            for index in 0..<8 {
                value |= UInt64(data[offset + index]) << UInt64(index * 8)
            }
            offset += 8
            return value
        }

        mutating func readString() throws -> String {
            let byteCount = try readLength()
            let bytes = try readBytes(byteCount)
            return String(data: bytes, encoding: .utf8) ?? ""
        }

        /// Pickle's WriteString16 stores the UTF-16 code-unit count, not the
        /// byte count used by WriteString.
        mutating func readString16() throws -> String {
            let characterCount = try readLength()
            guard characterCount <= Int.max / 2 else {
                throw ChromeSessionImportError.malformed("invalid UTF-16 length")
            }
            let bytes = try readBytes(characterCount * 2)
            return String(data: bytes, encoding: .utf16LittleEndian) ?? ""
        }

        private mutating func readLength() throws -> Int {
            let raw = try readInt32()
            guard raw >= 0 else { throw ChromeSessionImportError.malformed("negative string length") }
            return Int(raw)
        }

        private mutating func readBytes(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else {
                throw ChromeSessionImportError.malformed("truncated string payload")
            }
            let start = offset
            offset += count
            let padding = (4 - (count % 4)) % 4
            guard padding <= remaining else {
                throw ChromeSessionImportError.malformed("truncated pickle padding")
            }
            offset += padding
            return data.subdata(in: start..<(start + count))
        }
    }

    static func readSession(from profile: ChromeProfile) throws -> ChromeSessionSnapshot {
        let directory = profile.sessionsDirectoryURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ChromeSessionImportError.sessionDirectoryMissing
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("Session_") }
        .sorted { sessionTimestamp($0) > sessionTimestamp($1) }

        guard !files.isEmpty else { throw ChromeSessionImportError.sessionFileMissing }

        var lastError: Error = ChromeSessionImportError.sessionFileMissing
        for file in files {
            do {
                return try readSessionFile(at: file)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func readSessionFile(at url: URL) throws -> ChromeSessionSnapshot {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 8, data.prefix(4) == signature else {
            throw ChromeSessionImportError.malformed("invalid SNSS header")
        }

        let version = data.subdata(in: 4..<8).withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(as: UInt32.self).littleEndian
        }
        guard version == supportedVersion else {
            throw ChromeSessionImportError.unsupportedVersion(version)
        }

        var reader = BinaryReader(data: data, offset: 8)
        var tabs: [Int32: TabState] = [:]
        var windows: [Int32: WindowState] = [:]
        var groups: [ChromeSessionGroupID: ChromeSessionGroup] = [:]
        var closedWindows = Set<Int32>()
        var activeWindowID: Int32?
        var reachedMarker = false

        while reader.remaining > 0 {
            let commandSize = Int(try reader.readUInt16())
            guard commandSize >= 1, commandSize <= reader.remaining else {
                throw ChromeSessionImportError.malformed("invalid command size")
            }
            let commandData = reader.data.subdata(
                in: reader.offset..<(reader.offset + commandSize)
            )
            reader.offset += commandSize

            var commandReader = BinaryReader(data: commandData)
            let commandID = try commandReader.readUInt8()
            let payload = commandData.subdata(in: commandReader.offset..<commandData.count)
            if commandID == markerCommandID {
                reachedMarker = true
                break
            }
            try replay(
                commandID,
                payload: payload,
                tabs: &tabs,
                windows: &windows,
                groups: &groups,
                closedWindows: &closedWindows,
                activeWindowID: &activeWindowID
            )
        }

        guard reachedMarker else {
            throw ChromeSessionImportError.malformed("session marker is missing")
        }
        return makeSnapshot(
            tabs: tabs,
            windows: windows,
            groups: groups,
            closedWindows: closedWindows,
            activeWindowID: activeWindowID
        )
    }

    private static func replay(
        _ commandID: UInt8,
        payload: Data,
        tabs: inout [Int32: TabState],
        windows: inout [Int32: WindowState],
        groups: inout [ChromeSessionGroupID: ChromeSessionGroup],
        closedWindows: inout Set<Int32>,
        activeWindowID: inout Int32?
    ) throws {
        var reader = BinaryReader(data: payload)
        switch commandID {
        case 0: // SetTabWindow
            let windowID = try reader.readInt32()
            let tabID = try reader.readInt32()
            tabs[tabID, default: TabState()].windowID = windowID
            _ = windows[windowID, default: WindowState()]
        case 2: // SetTabIndexInWindow
            let tabID = try reader.readInt32()
            tabs[tabID, default: TabState()].visualIndex = try reader.readInt32()
        case 6: // UpdateTabNavigation
            try replayNavigation(payload, tabs: &tabs)
        case 7: // SetSelectedNavigationIndex
            let tabID = try reader.readInt32()
            tabs[tabID, default: TabState()].selectedNavigationIndex = try reader.readInt32()
        case 8: // SetSelectedTabInIndex
            let windowID = try reader.readInt32()
            windows[windowID, default: WindowState()].selectedTabIndex = Int(try reader.readInt32())
        case 12: // SetPinnedState
            let tabID = try reader.readInt32()
            _ = try reader.readUInt8()
            tabs[tabID, default: TabState()].pinned = payload.count > 4 && payload[4] != 0
        case 16: // TabClosed
            let tabID = try reader.readInt32()
            tabs.removeValue(forKey: tabID)
        case 17: // WindowClosed
            let windowID = try reader.readInt32()
            closedWindows.insert(windowID)
            windows.removeValue(forKey: windowID)
        case 20: // SetActiveWindow
            activeWindowID = try reader.readInt32()
        case 25: // SetTabGroup
            try replayTabGroupAssignment(payload, tabs: &tabs)
        case 27: // SetTabGroupMetadata
            try replayTabGroupMetadata(payload, groups: &groups)
        case 31: // SetWindowUserTitle
            _ = try reader.readUInt32() // Pickle payload size
            let windowID = try reader.readInt32()
            windows[windowID, default: WindowState()].title = try reader.readString()
        default:
            // Bounds, window state, split tabs, extension data and other
            // commands do not affect the browser state Peekr can reproduce.
            break
        }
    }

    private static func replayNavigation(
        _ payload: Data,
        tabs: inout [Int32: TabState]
    ) throws {
        var reader = BinaryReader(data: payload)
        _ = try reader.readUInt32() // Pickle payload size
        let tabID = try reader.readInt32()
        let navigationIndex = try reader.readInt32()
        let url = try reader.readString()
        let title = try reader.readString16()
        _ = try reader.readString() // serialized page state
        _ = try reader.readInt32() // transition type
        tabs[tabID, default: TabState()].navigations[navigationIndex] = Navigation(
            title: title,
            urlString: url
        )
    }

    private static func replayTabGroupAssignment(
        _ payload: Data,
        tabs: inout [Int32: TabState]
    ) throws {
        guard payload.count >= 25 else {
            throw ChromeSessionImportError.malformed("invalid tab-group assignment")
        }
        var reader = BinaryReader(data: payload)
        let tabID = try reader.readInt32()
        _ = try reader.readUInt32() // struct alignment before SerializedToken
        let groupID = ChromeSessionGroupID(
            high: try reader.readUInt64(),
            low: try reader.readUInt64()
        )
        let hasGroup = payload[24] != 0
        tabs[tabID, default: TabState()].groupID = hasGroup ? groupID : nil
    }

    private static func replayTabGroupMetadata(
        _ payload: Data,
        groups: inout [ChromeSessionGroupID: ChromeSessionGroup]
    ) throws {
        var reader = BinaryReader(data: payload)
        _ = try reader.readUInt32() // Pickle payload size
        let groupID = ChromeSessionGroupID(
            high: try reader.readUInt64(),
            low: try reader.readUInt64()
        )
        let name = try reader.readString16()
        let color = try reader.readUInt32()
        let isCollapsed = try reader.readUInt8() != 0
        _ = try reader.readUInt8() // is_saved
        groups[groupID] = ChromeSessionGroup(
            id: groupID,
            name: name,
            color: tabGroupColor(forChromeValue: color),
            isCollapsed: isCollapsed
        )
    }

    private static func makeSnapshot(
        tabs: [Int32: TabState],
        windows: [Int32: WindowState],
        groups: [ChromeSessionGroupID: ChromeSessionGroup],
        closedWindows: Set<Int32>,
        activeWindowID: Int32?
    ) -> ChromeSessionSnapshot {
        let groupedTabs = Dictionary(grouping: tabs.compactMap { tabID, state -> (Int32, Int32, TabState)? in
            guard let windowID = state.windowID,
                  !closedWindows.contains(windowID),
                  state.navigations[state.selectedNavigationIndex] != nil
                      || !state.navigations.isEmpty else { return nil }
            return (windowID, tabID, state)
        }, by: \.0)

        let windowIDs = Set(groupedTabs.keys).union(windows.keys).subtracting(closedWindows)
        let orderedWindowIDs = windowIDs.sorted()
        let resolvedActiveWindowID = activeWindowID.flatMap { windowIDs.contains($0) ? $0 : nil }
            ?? orderedWindowIDs.first

        let resultWindows = orderedWindowIDs.compactMap { windowID -> ChromeSessionWindow? in
            let rawTabs = groupedTabs[windowID, default: []]
                .sorted { lhs, rhs in
                    if lhs.2.visualIndex == rhs.2.visualIndex { return lhs.1 < rhs.1 }
                    return lhs.2.visualIndex < rhs.2.visualIndex
                }
                .compactMap { _, _, state -> ChromeSessionTab? in
                    let navigation = state.navigations[state.selectedNavigationIndex]
                        ?? state.navigations.max { lhs, rhs in lhs.key < rhs.key }?.value
                    guard let navigation, !navigation.urlString.isEmpty else { return nil }
                    return ChromeSessionTab(
                        title: navigation.title,
                        urlString: navigation.urlString,
                        isPinned: state.pinned,
                        groupID: state.groupID
                    )
                }
            guard !rawTabs.isEmpty else { return nil }
            let selectedIndex = min(
                max(windows[windowID]?.selectedTabIndex ?? 0, 0),
                rawTabs.count - 1
            )
            return ChromeSessionWindow(
                tabs: rawTabs,
                selectedTabIndex: selectedIndex,
                isActive: windowID == resolvedActiveWindowID,
                title: windows[windowID]?.title ?? ""
            )
        }

        // Group metadata can outlive all tabs after a group is closed. Only
        // groups represented by an imported tab belong in the snapshot.
        let usedGroupIDs = Set(resultWindows.flatMap { window in
            window.tabs.compactMap(\.groupID)
        })
        let resultGroups = usedGroupIDs
            .sorted { lhs, rhs in
                if lhs.high == rhs.high { return lhs.low < rhs.low }
                return lhs.high < rhs.high
            }
            .compactMap { groups[$0] }
        return ChromeSessionSnapshot(windows: resultWindows, groups: resultGroups)
    }

    private static func tabGroupColor(forChromeValue value: UInt32) -> TabGroupColor {
        switch value {
        case 0: return .gray
        case 1: return .blue
        case 2: return .red
        case 3: return .yellow
        case 4: return .green
        case 5: return .pink
        case 6: return .purple
        case 7: return .cyan
        case 8: return .orange
        default: return .gray
        }
    }

    private static func sessionTimestamp(_ url: URL) -> UInt64 {
        UInt64(url.lastPathComponent.split(separator: "_").last ?? "") ?? 0
    }
}
