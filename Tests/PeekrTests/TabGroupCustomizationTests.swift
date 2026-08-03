import Foundation
import XCTest
@testable import Peekr

@MainActor
final class TabGroupCustomizationTests: XCTestCase {
    func testGroupsKeepIndependentNamesColorsAndCollapseStyles() throws {
        let (model, tabs, _) = makeModel(count: 4)
        let research = model.addGroup(name: "Research", color: .blue, containing: [tabs[0].id])
        let build = model.addGroup(name: "Build", color: .orange, containing: [tabs[1].id])

        model.renameGroup(research.id, to: "Product Research")
        model.recolorGroup(research.id, to: .purple)
        model.toggleGroup(research.id)
        model.renameGroup(build.id, to: "Release Build")
        model.recolorGroup(build.id, to: .green)

        let styledResearch = try XCTUnwrap(model.group(research.id))
        let styledBuild = try XCTUnwrap(model.group(build.id))
        XCTAssertEqual(styledResearch.name, "Product Research")
        XCTAssertEqual(styledResearch.color, .purple)
        XCTAssertTrue(styledResearch.isCollapsed)
        XCTAssertEqual(styledBuild.name, "Release Build")
        XCTAssertEqual(styledBuild.color, .green)
        XCTAssertFalse(styledBuild.isCollapsed)
    }

    func testGroupStylesAndHierarchyPersistAcrossReload() throws {
        let (model, tabs, store) = makeModel(count: 4)
        let first = model.addGroup(name: "Design", color: .pink, containing: [tabs[0].id, tabs[1].id])
        let second = model.addGroup(name: "Engineering", color: .green, containing: [tabs[2].id])
        model.toggleGroup(first.id)
        model.moveGroup(second.id, before: first.id)

        let reloaded = AppModel(store: store)

        XCTAssertEqual(reloaded.activeWorkspace.sidebarItems.map(\.referenceID), [second.id, first.id, tabs[3].id])
        XCTAssertEqual(reloaded.group(first.id)?.name, "Design")
        XCTAssertEqual(reloaded.group(first.id)?.color, .pink)
        XCTAssertEqual(reloaded.group(first.id)?.isCollapsed, true)
        XCTAssertEqual(reloaded.group(first.id)?.tabIDs, [tabs[0].id, tabs[1].id])
        XCTAssertEqual(reloaded.group(second.id)?.name, "Engineering")
        XCTAssertEqual(reloaded.group(second.id)?.color, .green)
    }

    func testBrowserStyleColorPaletteRoundTripsThroughPersistence() throws {
        XCTAssertEqual(
            TabGroupColor.palette,
            [.gray, .blue, .red, .yellow, .green, .pink, .purple, .cyan, .orange]
        )

        for color in TabGroupColor.palette {
            let encoded = try JSONEncoder().encode(color)
            XCTAssertEqual(try JSONDecoder().decode(TabGroupColor.self, from: encoded), color)
        }
    }

    func testCustomColorPersistsCopiesAndPresetSelectionClearsIt() throws {
        let (model, tabs, store) = makeModel(count: 2)
        let group = model.addGroup(name: "Custom", color: .blue, containing: [tabs[0].id])
        let customColor = TabGroupCustomColor(red: 0.12, green: 0.34, blue: 0.56)

        model.setCustomColor(customColor, forGroup: group.id)
        let duplicate = try XCTUnwrap(model.duplicateGroup(group.id))

        XCTAssertEqual(model.group(group.id)?.customColor, customColor)
        XCTAssertEqual(model.group(duplicate.id)?.customColor, customColor)

        let reloaded = AppModel(store: store)
        XCTAssertEqual(reloaded.group(group.id)?.customColor, customColor)
        XCTAssertEqual(reloaded.group(duplicate.id)?.customColor, customColor)

        reloaded.recolorGroup(group.id, to: .orange)
        XCTAssertEqual(reloaded.group(group.id)?.color, .orange)
        XCTAssertNil(reloaded.group(group.id)?.customColor)
    }

    private func makeModel(count: Int) -> (AppModel, [WebApp], AppStore) {
        let tabs = (0..<count).map {
            WebApp(title: "Tab \($0)", urlString: "https://\($0).example")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekr-group-style-\(UUID().uuidString).json")
        let store = AppStore(fileURL: url)
        store.save(WorkspacesData(workspaces: [Workspace(tabs: tabs)]))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (AppModel(store: store), tabs, store)
    }
}
