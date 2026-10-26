import AppKit
import XCTest
@testable import Peekr

final class SlidePanelShortcutTests: XCTestCase {
    func testPlainCommandQIsTheQuitEquivalent() {
        XCTAssertTrue(SlidePanel.isPlainCommandKeyEquivalent(
            flags: [.command],
            charactersIgnoringModifiers: "q",
            character: "q"
        ))
    }

    @MainActor
    func testRepeatedCommandQReachesTheQuitHandler() throws {
        let panel = SlidePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 640))
        var quitCount = 0
        panel.onQuitShortcut = { quitCount += 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "q",
            charactersIgnoringModifiers: "q",
            isARepeat: false,
            keyCode: 12
        ))

        XCTAssertTrue(panel.performKeyEquivalent(with: event))
        XCTAssertTrue(panel.performKeyEquivalent(with: event))
        XCTAssertEqual(quitCount, 2)
    }

    func testPlainCommandWIsTheTabCloseEquivalent() {
        XCTAssertTrue(SlidePanel.isCloseTabKeyEquivalent(
            flags: [.command],
            charactersIgnoringModifiers: "w"
        ))
    }

    func testWindowCloseVariantsAreNotTabCloseEquivalents() {
        let variants: [NSEvent.ModifierFlags] = [
            [.command, .shift],
            [.command, .option],
            [.command, .control],
            [],
        ]
        for flags in variants {
            XCTAssertFalse(SlidePanel.isCloseTabKeyEquivalent(
                flags: flags,
                charactersIgnoringModifiers: "w"
            ))
        }
    }

    func testOtherCommandKeysAreNotTabCloseEquivalents() {
        XCTAssertFalse(SlidePanel.isCloseTabKeyEquivalent(
            flags: [.command],
            charactersIgnoringModifiers: "q"
        ))
    }

    func testShiftCommandWIsTheWindowCloseEquivalent() {
        XCTAssertTrue(SlidePanel.isCloseWindowKeyEquivalent(
            flags: [.command, .shift],
            charactersIgnoringModifiers: "w"
        ))
        XCTAssertFalse(SlidePanel.isCloseWindowKeyEquivalent(
            flags: [.command],
            charactersIgnoringModifiers: "w"
        ))
        XCTAssertFalse(SlidePanel.isCloseWindowKeyEquivalent(
            flags: [.command, .shift, .option],
            charactersIgnoringModifiers: "w"
        ))
    }

    @MainActor
    func testCloseTabHidesPanelForLastTabOrEmptySelection() {
        XCTAssertTrue(PanelController.shouldHideForCloseTab(tabCount: 1))
        XCTAssertTrue(PanelController.shouldHideForCloseTab(tabCount: 0))
        XCTAssertFalse(PanelController.shouldHideForCloseTab(tabCount: 2))
    }
}
