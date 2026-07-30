import XCTest
@testable import Peekr

final class CefLocaleTests: XCTestCase {
    func testExplicitEnglishAlwaysUsesEnglishPack() {
        XCTAssertEqual(
            AppLanguage.english.cefLocaleIdentifier(preferredLanguages: ["zh-Hant-TW"]),
            "en"
        )
    }

    func testExplicitChineseFollowsTraditionalSystemVariants() {
        XCTAssertEqual(
            AppLanguage.chinese.cefLocaleIdentifier(preferredLanguages: ["zh-Hans-CN"]),
            "zh-CN"
        )
        XCTAssertEqual(
            AppLanguage.chinese.cefLocaleIdentifier(preferredLanguages: ["zh-Hant-TW"]),
            "zh-TW"
        )
        XCTAssertEqual(
            AppLanguage.chinese.cefLocaleIdentifier(preferredLanguages: ["zh-HK"]),
            "zh-TW"
        )
    }

    func testSystemLanguageFallsBackToShippedLocales() {
        XCTAssertEqual(
            AppLanguage.system.cefLocaleIdentifier(preferredLanguages: ["fr-FR"]),
            "en"
        )
        XCTAssertEqual(
            AppLanguage.system.cefLocaleIdentifier(preferredLanguages: ["zh-CN"]),
            "zh-CN"
        )
        XCTAssertEqual(
            AppLanguage.system.cefLocaleIdentifier(preferredLanguages: ["zh-MO"]),
            "zh-TW"
        )
    }
}
