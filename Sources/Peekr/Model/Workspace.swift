import Foundation

/// Edge-style tab-group colours. The raw value is persisted so future visual
/// changes never invalidate a user's sidebar data.
enum TabGroupColor: String, Codable, CaseIterable, Hashable {
    case blue, purple, pink, red, orange, green, gray, yellow, cyan
}

/// Platform-neutral sRGB value chosen from the system color panel. Keeping it
/// separate from the preset enum preserves old JSON and avoids persisting
/// AppKit/SwiftUI implementation details in the browser model.
struct TabGroupCustomColor: Codable, Hashable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }
}

/// A collapsible group inside one space. Tabs remain first-class `WebApp`s;
/// moving them into a group only changes these IDs, so their browser engines,
/// sessions and favicon files keep the same identity.
struct TabGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var color: TabGroupColor
    var customColor: TabGroupCustomColor?
    var isCollapsed: Bool
    var tabIDs: [WebApp.ID]

    init(
        id: UUID = UUID(),
        name: String,
        color: TabGroupColor = .blue,
        customColor: TabGroupCustomColor? = nil,
        isCollapsed: Bool = false,
        tabIDs: [WebApp.ID] = []
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.customColor = customColor
        self.isCollapsed = isCollapsed
        self.tabIDs = tabIDs
    }
}

enum SidebarItemKind: String, Codable, Hashable {
    case tab
    case group
}

/// Top-level sidebar order. Ungrouped tabs and groups may be interleaved, just
/// like Edge vertical tabs. Child ordering lives on `TabGroup.tabIDs`.
struct SidebarItem: Codable, Hashable, Identifiable {
    let kind: SidebarItemKind
    let referenceID: UUID

    var id: String { "\(kind.rawValue):\(referenceID.uuidString)" }

    static func tab(_ id: WebApp.ID) -> SidebarItem {
        SidebarItem(kind: .tab, referenceID: id)
    }

    static func group(_ id: TabGroup.ID) -> SidebarItem {
        SidebarItem(kind: .group, referenceID: id)
    }
}

/// One Arc-like Space containing Edge-like vertical tab groups. The actual tab
/// records stay in `tabs`; groups and `sidebarItems` only describe hierarchy and
/// order. `selectedTabID` lets every space remember where the user left off.
struct Workspace: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var symbol: String
    var tabs: [WebApp]
    var groups: [TabGroup]
    var sidebarItems: [SidebarItem]
    var selectedTabID: WebApp.ID?

    init(
        id: UUID = UUID(),
        name: String = "",
        symbol: String = "square.stack",
        tabs: [WebApp] = [],
        groups: [TabGroup] = [],
        sidebarItems: [SidebarItem]? = nil,
        selectedTabID: WebApp.ID? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tabs = tabs
        self.groups = groups
        self.sidebarItems = sidebarItems ?? tabs.map { .tab($0.id) }
        self.selectedTabID = selectedTabID ?? tabs.first?.id
        normalizeSidebar()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, tabs, groups, sidebarItems, selectedTabID
    }

    // Tolerant decode performs the v1 flat-list → v2 hierarchy migration in
    // place. A missing `groups`/`sidebarItems` pair becomes ungrouped tabs.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "square.stack"
        tabs = try c.decodeIfPresent([WebApp].self, forKey: .tabs) ?? []
        groups = try c.decodeIfPresent([TabGroup].self, forKey: .groups) ?? []
        sidebarItems = try c.decodeIfPresent([SidebarItem].self, forKey: .sidebarItems)
            ?? tabs.map { .tab($0.id) }
        selectedTabID = try c.decodeIfPresent(UUID.self, forKey: .selectedTabID)
            ?? tabs.first?.id
        normalizeSidebar()
    }

    /// Repairs stale or partially-written hierarchy references without dropping
    /// any tab. This also makes future schema evolution fail soft.
    mutating func normalizeSidebar() {
        let validTabIDs = Set(tabs.map(\.id))
        let validGroupIDs = Set(groups.map(\.id))
        var claimedTabs = Set<WebApp.ID>()

        for index in groups.indices {
            groups[index].tabIDs = groups[index].tabIDs.filter {
                validTabIDs.contains($0) && claimedTabs.insert($0).inserted
            }
        }

        var seenGroups = Set<TabGroup.ID>()
        sidebarItems = sidebarItems.filter { item in
            switch item.kind {
            case .tab:
                return validTabIDs.contains(item.referenceID)
                    && !claimedTabs.contains(item.referenceID)
                    && claimedTabs.insert(item.referenceID).inserted
            case .group:
                return validGroupIDs.contains(item.referenceID)
                    && seenGroups.insert(item.referenceID).inserted
            }
        }

        for group in groups where !seenGroups.contains(group.id) {
            sidebarItems.append(.group(group.id))
            seenGroups.insert(group.id)
        }
        for tab in tabs where !claimedTabs.contains(tab.id) {
            sidebarItems.append(.tab(tab.id))
            claimedTabs.insert(tab.id)
        }

        if let selectedTabID, !validTabIDs.contains(selectedTabID) {
            self.selectedTabID = orderedTabIDs.first
        } else if selectedTabID == nil {
            selectedTabID = orderedTabIDs.first
        }
    }

    var orderedTabIDs: [WebApp.ID] {
        var result: [WebApp.ID] = []
        for item in sidebarItems {
            switch item.kind {
            case .tab:
                result.append(item.referenceID)
            case .group:
                result.append(contentsOf: groups.first { $0.id == item.referenceID }?.tabIDs ?? [])
            }
        }
        return result
    }

    func group(containing tabID: WebApp.ID) -> TabGroup? {
        groups.first { $0.tabIDs.contains(tabID) }
    }
}

/// Persisted shape of the complete browser sidebar. `schemaVersion` is
/// advisory—the tolerant nested decoders remain the source of migration truth.
struct WorkspacesData: Codable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var workspaces: [Workspace]
    var activeWorkspaceID: UUID?

    init(
        schemaVersion: Int = WorkspacesData.currentSchemaVersion,
        workspaces: [Workspace],
        activeWorkspaceID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, workspaces, activeWorkspaceID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        workspaces = try c.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        activeWorkspaceID = try c.decodeIfPresent(UUID.self, forKey: .activeWorkspaceID)
    }
}
