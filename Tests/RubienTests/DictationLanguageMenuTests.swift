#if os(macOS)
import XCTest
@testable import Rubien

final class DictationLanguageShortCodeTests: XCTestCase {
    func testLatinScriptLanguagesUseTheirUppercasedCode() {
        XCTAssertEqual(DictationLanguage.shortCode(for: "en"), "EN")
        XCTAssertEqual(DictationLanguage.shortCode(for: "en-US"), "EN")
        XCTAssertEqual(DictationLanguage.shortCode(for: "de"), "DE")
        XCTAssertEqual(DictationLanguage.shortCode(for: "de-DE"), "DE")
    }

    func testHanKanaAndHangulLanguagesUseTheFirstCharacterOfTheirOwnName() {
        XCTAssertEqual(DictationLanguage.shortCode(for: "zh-CN"), "中")
        XCTAssertEqual(DictationLanguage.shortCode(for: "zh-TW"), "中")
        XCTAssertEqual(DictationLanguage.shortCode(for: "ja"), "日")
        XCTAssertEqual(DictationLanguage.shortCode(for: "ja-JP"), "日")
        XCTAssertEqual(DictationLanguage.shortCode(for: "ko"), "한")
        XCTAssertEqual(DictationLanguage.shortCode(for: "ko-KR"), "한")
    }

    /// Cantonese is written in Han, so it follows the Han rule (its own name is
    /// 粤语), which also tells it apart from Mandarin's "中".
    func testCantoneseFollowsTheHanRule() {
        XCTAssertEqual(DictationLanguage.shortCode(for: "yue-CN"), "粤")
    }

    func testMissingOrMalformedIdentifiersGetAPlaceholder() {
        XCTAssertEqual(DictationLanguage.shortCode(for: nil), "–")
        XCTAssertEqual(DictationLanguage.shortCode(for: ""), "–")
        XCTAssertEqual(DictationLanguage.shortCode(for: "garbage"), "–")
    }
}

final class DictationQuickListTests: XCTestCase {
    func testPreferredThenRecentsThenCurrent() {
        XCTAssertEqual(
            DictationLanguage.quickIdentifiers(
                preferred: ["en-US", "zh-CN"],
                recents: ["ja-JP", "fr-FR"],
                current: "de-DE"),
            ["en-US", "zh-CN", "ja-JP", "fr-FR", "de-DE"])
    }

    func testEachLanguageIsListedOnceAtItsFirstPlace() {
        XCTAssertEqual(
            DictationLanguage.quickIdentifiers(
                preferred: ["en-US", "zh-CN"],
                recents: ["zh-CN", "ja-JP", "en-US"],
                current: "ja-JP"),
            ["en-US", "zh-CN", "ja-JP"])
    }

    func testCurrentAlreadyListedIsNotRepeated() {
        XCTAssertEqual(
            DictationLanguage.quickIdentifiers(
                preferred: ["en-US"], recents: [], current: "en-US"),
            ["en-US"])
    }

    func testSystemLanguageAddsNoRow() {
        XCTAssertEqual(
            DictationLanguage.quickIdentifiers(preferred: ["en-US"], recents: [""], current: nil),
            ["en-US"])
        XCTAssertEqual(
            DictationLanguage.quickIdentifiers(preferred: [], recents: [], current: nil),
            [])
    }

    /// The developer's Mac: `Locale.preferredLanguages` is en-US, zh-Hans-US,
    /// which the transcribers map to en-US and zh-CN.
    func testPreferredLanguagesMapToTheirSupportedEquivalents() {
        XCTAssertEqual(
            DictationEngines.supportedPreferred(
                ["en-US", "zh-Hans-US"],
                equivalents: ["en-US": "en-US", "zh-Hans-US": "zh-CN"]),
            ["en-US", "zh-CN"])
    }

    func testPreferredLanguageWithoutASupportedEquivalentIsSkipped() {
        XCTAssertEqual(
            DictationEngines.supportedPreferred(
                ["tlh", "en-US"], equivalents: ["en-US": "en-US"]),
            ["en-US"])
    }

    func testPreferredLanguagesWithTheSameEquivalentAreListedOnce() {
        XCTAssertEqual(
            DictationEngines.supportedPreferred(
                ["en-GB", "en-AU", "zh-Hans-US"],
                equivalents: ["en-GB": "en-GB", "en-AU": "en-GB", "zh-Hans-US": "zh-CN"]),
            ["en-GB", "zh-CN"])
    }
}

final class DictationRecentsTests: XCTestCase {
    func testChoosingPutsTheLanguageFirst() {
        XCTAssertEqual(
            DictationLanguage.recents(afterChoosing: "ja-JP", previous: ["en-US", "zh-CN"]),
            ["ja-JP", "en-US", "zh-CN"])
    }

    func testRechoosingMovesTheLanguageToTheFront() {
        XCTAssertEqual(
            DictationLanguage.recents(afterChoosing: "zh-CN", previous: ["en-US", "zh-CN", "ja-JP"]),
            ["zh-CN", "en-US", "ja-JP"])
    }

    func testRecentsKeepAtMostFour() {
        XCTAssertEqual(RubienPreferences.assistantDictationRecentLocaleLimit, 4)
        XCTAssertEqual(
            DictationLanguage.recents(
                afterChoosing: "fr-FR",
                previous: ["en-US", "zh-CN", "ja-JP", "de-DE"]),
            ["fr-FR", "en-US", "zh-CN", "ja-JP"])
    }

    func testTheSystemLanguageIsNotRecorded() {
        let previous = ["en-US", "zh-CN"]
        XCTAssertEqual(DictationLanguage.recents(afterChoosing: nil, previous: previous), previous)
        XCTAssertEqual(DictationLanguage.recents(afterChoosing: "", previous: previous), previous)
    }
}
#endif
