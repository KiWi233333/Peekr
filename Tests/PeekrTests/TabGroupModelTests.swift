import Foundation
import SwiftUI
import XCTest
@testable import Peekr

@MainActor
final class TabGroupModelTests: XCTestCase {
    func testDroppingOneUngroupedTabOntoAnotherCreatesGroupWithoutChangingTabIdentity() {
        let (model, tabs) = makeModel(count: 3)

        let group = model.combine(tabs[2].id, with: tabs[0].id)

        XCTAssertEqual(group?.tabIDs, [tabs[0].id, tabs[2].id])
        XCTAssertEqual(model.group(containing: tabs[0].id)?.id, group?.id)
        XCTAssertEqual(model.group(containing: tabs[2].id)?.id, group?.id)
        XCTAssertEqual(Set(model.allTabs.map(\.id)), Set(tabs.map(\.id)))
    }

    func testMovingOutOfFreshImplicitGroupDissolvesRemainingSingletonInPlace() throws {
        let (model, tabs) = makeModel(count: 3, provisionalNow: { 100 })
        let group = try XCTUnwrap(model.combine(tabs[2].id, with: tabs[0].id))

        model.moveTabToRoot(tabs[2].id, beforeItem: tabs[1].id)

        XCTAssertNil(model.group(group.id))
        XCTAssertNil(model.group(containing: tabs[0].id))
        XCTAssertEqual(
            model.activeWorkspace.sidebarItems,
            [.tab(tabs[0].id), .tab(tabs[2].id), .tab(tabs[1].id)]
        )
    }

    func testClosingFromFreshImplicitGroupDissolvesRemainingSingleton() throws {
        let (model, tabs) = makeModel(count: 3, provisionalNow: { 100 })
        let group = try XCTUnwrap(model.combine(tabs[2].id, with: tabs[0].id))

        model.removeApp(tabs[2].id)

        XCTAssertNil(model.group(group.id))
        XCTAssertTrue(model.activeWorkspace.sidebarItems.contains(.tab(tabs[0].id)))
        XCTAssertEqual(Set(model.allTabs.map(\.id)), Set([tabs[0].id, tabs[1].id]))
    }

    func testReopeningTabFromDissolvedImplicitGroupPreservesFormerChildOrder() throws {
        let (model, tabs) = makeModel(count: 3, provisionalNow: { 100 })
        _ = try XCTUnwrap(model.combine(tabs[2].id, with: tabs[0].id))
        model.removeApp(tabs[2].id)

        _ = model.reopenLastClosedTab()

        XCTAssertEqual(
            model.activeWorkspace.sidebarItems,
            [.tab(tabs[0].id), .tab(tabs[2].id), .tab(tabs[1].id)]
        )
    }

    func testExpiredImplicitGroupKeepsIntentionalSingleton() throws {
        var now: TimeInterval = 100
        let (model, tabs) = makeModel(count: 3, provisionalNow: { now })
        let group = try XCTUnwrap(model.combine(tabs[2].id, with: tabs[0].id))
        now += 8

        model.moveTabToRoot(tabs[2].id)

        XCTAssertEqual(model.group(group.id)?.tabIDs, [tabs[0].id])
    }

    func testRenamingImplicitGroupConfirmsItBeforeMovingChildOut() throws {
        let (model, tabs) = makeModel(count: 3, provisionalNow: { 100 })
        let group = try XCTUnwrap(model.combine(tabs[2].id, with: tabs[0].id))
        model.renameGroup(group.id, to: "Research")

        model.moveTabToRoot(tabs[2].id)

        XCTAssertEqual(model.group(group.id)?.name, "Research")
        XCTAssertEqual(model.group(group.id)?.tabIDs, [tabs[0].id])
    }

    func testConfirmingUnchangedDefaultNameConfirmsImplicitGroup() throws {
        let (model, tabs) = makeModel(count: 3, provisionalNow: { 100 })
        let group = try XCTUnwrap(model.combine(tabs[2].id, with: tabs[0].id))
        model.renameGroup(group.id, to: group.name)

        model.moveTabToRoot(tabs[2].id)

        XCTAssertEqual(model.group(group.id)?.tabIDs, [tabs[0].id])
    }

    func testRestylingOrCollapsingImplicitGroupConfirmsIt() throws {
        let (recolored, recoloredTabs) = makeModel(count: 3, provisionalNow: { 100 })
        let recoloredGroup = try XCTUnwrap(
            recolored.combine(recoloredTabs[2].id, with: recoloredTabs[0].id)
        )
        recolored.recolorGroup(recoloredGroup.id, to: .purple)
        recolored.moveTabToRoot(recoloredTabs[2].id)

        let (collapsed, collapsedTabs) = makeModel(count: 3, provisionalNow: { 100 })
        let collapsedGroup = try XCTUnwrap(
            collapsed.combine(collapsedTabs[2].id, with: collapsedTabs[0].id)
        )
        collapsed.toggleGroup(collapsedGroup.id)
        collapsed.moveTabToRoot(collapsedTabs[2].id)

        XCTAssertEqual(recolored.group(recoloredGroup.id)?.tabIDs, [recoloredTabs[0].id])
        XCTAssertEqual(recolored.group(recoloredGroup.id)?.color, .purple)
        XCTAssertEqual(collapsed.group(collapsedGroup.id)?.tabIDs, [collapsedTabs[0].id])
        XCTAssertEqual(collapsed.group(collapsedGroup.id)?.isCollapsed, true)
    }

    func testAddingThirdTabConfirmsImplicitGroup() throws {
        let (model, tabs) = makeModel(count: 3, provisionalNow: { 100 })
        let group = try XCTUnwrap(model.combine(tabs[2].id, with: tabs[0].id))
        let added = model.addBlankTab(toGroup: group.id)

        model.moveTabToRoot(tabs[2].id)
        model.moveTabToRoot(added.id)

        XCTAssertEqual(model.group(group.id)?.tabIDs, [tabs[0].id])
    }

    func testDuplicatingChildConfirmsImplicitGroup() throws {
        let (model, tabs) = makeModel(count: 3, provisionalNow: { 100 })
        let group = try XCTUnwrap(model.combine(tabs[2].id, with: tabs[0].id))
        let copy = try XCTUnwrap(model.duplicateTab(tabs[0].id))

        model.moveTabToRoot(copy.id)
        model.moveTabToRoot(tabs[2].id)

        XCTAssertEqual(model.group(group.id)?.tabIDs, [tabs[0].id])
    }

    func testExplicitlyCreatedDefaultNamedGroupIsNeverProvisional() {
        let (model, tabs) = makeModel(count: 3, provisionalNow: { 100 })
        let group = model.addGroup(name: "Tab Group", containing: [tabs[0].id, tabs[2].id])

        model.moveTabToRoot(tabs[2].id)

        XCTAssertEqual(model.group(group.id)?.tabIDs, [tabs[0].id])
    }

    func testMovingOrDuplicatingImplicitGroupConfirmsSource() throws {
        let (moved, movedTabs) = makeModel(count: 3, provisionalNow: { 100 })
        let movedGroup = try XCTUnwrap(moved.combine(movedTabs[2].id, with: movedTabs[0].id))
        moved.moveGroup(movedGroup.id, before: nil)
        moved.moveTabToRoot(movedTabs[2].id)

        let (duplicated, duplicatedTabs) = makeModel(count: 3, provisionalNow: { 100 })
        let duplicatedGroup = try XCTUnwrap(
            duplicated.combine(duplicatedTabs[2].id, with: duplicatedTabs[0].id)
        )
        _ = duplicated.duplicateGroup(duplicatedGroup.id)
        duplicated.moveTabToRoot(duplicatedTabs[2].id)

        XCTAssertEqual(moved.group(movedGroup.id)?.tabIDs, [movedTabs[0].id])
        XCTAssertEqual(
            duplicated.group(duplicatedGroup.id)?.tabIDs,
            [duplicatedTabs[0].id]
        )
    }

    func testMovingLastChildrenToRootRemovesEmptyGroup() {
        let (model, tabs) = makeModel(count: 3)
        let group = model.addGroup(name: "Research", containing: [tabs[0].id, tabs[1].id])

        model.moveTabToRoot(tabs[0].id)
        XCTAssertNotNil(model.group(group.id))
        model.moveTabToRoot(tabs[1].id)

        XCTAssertNil(model.group(group.id))
        XCTAssertTrue(model.activeWorkspace.sidebarItems.contains(.tab(tabs[0].id)))
        XCTAssertTrue(model.activeWorkspace.sidebarItems.contains(.tab(tabs[1].id)))
    }

    func testClosingSelectedTabSelectsNearestFollowingTabAndCanReopen() {
        let (model, tabs) = makeModel(count: 3)
        model.select(tabs[1].id)

        model.removeApp(tabs[1].id)

        XCTAssertEqual(model.selectedID, tabs[2].id)
        XCTAssertTrue(model.hasRecentlyClosedTabs)

        let reopened = model.reopenLastClosedTab()
        XCTAssertEqual(reopened?.id, tabs[1].id)
        XCTAssertEqual(model.selectedID, tabs[1].id)
        XCTAssertEqual(model.apps.map(\.id), tabs.map(\.id))
    }

    func testReopenRestoresOriginalGroupAndChildPosition() {
        let (model, tabs) = makeModel(count: 3)
        let group = model.addGroup(name: "Docs", containing: [tabs[0].id, tabs[1].id])

        model.removeApp(tabs[0].id)
        _ = model.reopenLastClosedTab()

        XCTAssertEqual(model.group(group.id)?.tabIDs, [tabs[0].id, tabs[1].id])
    }

    func testCloseGroupClosesEveryChildAndSelectsOutsideNeighbor() {
        let (model, tabs) = makeModel(count: 4)
        let group = model.addGroup(name: "Build", containing: [tabs[1].id, tabs[2].id])
        var removed: [UUID] = []
        model.onRemove = { removed.append($0) }
        model.select(tabs[1].id)

        model.closeGroup(group.id)

        XCTAssertEqual(Set(removed), Set([tabs[1].id, tabs[2].id]))
        XCTAssertEqual(model.apps.map(\.id), [tabs[0].id, tabs[3].id])
        XCTAssertEqual(model.selectedID, tabs[3].id)
        XCTAssertNil(model.group(group.id))
    }

    func testEachWorkspaceRemembersItsSelectedTab() {
        let (model, tabs) = makeModel(count: 3)
        model.select(tabs[2].id)
        let firstSpace = model.activeWorkspaceID
        let secondSpace = model.addWorkspace().id
        let newTab = model.addBlankTab()

        model.selectWorkspace(firstSpace)
        XCTAssertEqual(model.selectedID, tabs[2].id)
        model.selectWorkspace(secondSpace)
        XCTAssertEqual(model.selectedID, newTab.id)
    }

    func testDuplicateTabStaysBesideSourceInsideItsGroup() throws {
        let (model, tabs) = makeModel(count: 3)
        let group = model.addGroup(name: "Read", containing: [tabs[0].id, tabs[1].id])

        let copy = try XCTUnwrap(model.duplicateTab(tabs[0].id))

        XCTAssertEqual(model.group(group.id)?.tabIDs, [tabs[0].id, copy.id, tabs[1].id])
        XCTAssertEqual(copy.urlString, tabs[0].urlString)
        XCTAssertEqual(model.selectedID, copy.id)
    }

    func testMovingWholeGroupChangesOnlyTopLevelOrder() {
        let (model, tabs) = makeModel(count: 4)
        let first = model.addGroup(name: "One", containing: [tabs[0].id, tabs[1].id])
        let second = model.addGroup(name: "Two", containing: [tabs[2].id, tabs[3].id])

        model.moveGroup(second.id, before: first.id)

        XCTAssertEqual(model.activeWorkspace.sidebarItems.map(\.referenceID), [second.id, first.id])
        XCTAssertEqual(model.group(first.id)?.tabIDs, [tabs[0].id, tabs[1].id])
        XCTAssertEqual(model.group(second.id)?.tabIDs, [tabs[2].id, tabs[3].id])
    }

    func testShadowTintLiftsGroupColorLightnessInHSL() throws {
        let group = TabGroup(name: "标签组", color: .blue)

        let base = try hslComponents(group.tint)
        let shadow = try hslComponents(group.shadowTint)

        XCTAssertEqual(shadow.hue, base.hue, accuracy: 0.02)
        XCTAssertGreaterThan(shadow.lightness, base.lightness)
        XCTAssertEqual(shadow.saturation, base.saturation, accuracy: 0.02)
    }

    private func hslComponents(_ color: Color) throws -> (hue: CGFloat, saturation: CGFloat, lightness: CGFloat) {
        let rgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        let maxC = max(r, g, b), minC = min(r, g, b)
        let lightness = (maxC + minC) / 2
        let delta = maxC - minC
        var hue: CGFloat = 0, saturation: CGFloat = 0
        if delta > 0 {
            saturation = lightness > 0.5 ? delta / (2 - maxC - minC) : delta / (maxC + minC)
            switch maxC {
            case r: hue = (g - b) / delta + (g < b ? 6 : 0)
            case g: hue = (b - r) / delta + 2
            default: hue = (r - g) / delta + 4
            }
            hue /= 6
        }
        return (hue, saturation, lightness)
    }

    private func makeModel(
        count: Int,
        provisionalNow: @escaping () -> TimeInterval = { 0 }
    ) -> (AppModel, [WebApp]) {
        let tabs = (0..<count).map {
            WebApp(title: "Tab \($0)", urlString: "https://\($0).example")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-groups-\(UUID().uuidString).json")
        let store = AppStore(fileURL: url)
        store.save(WorkspacesData(workspaces: [Workspace(tabs: tabs)]))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (AppModel(store: store, provisionalNow: provisionalNow), tabs)
    }

}
