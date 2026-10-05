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
}
