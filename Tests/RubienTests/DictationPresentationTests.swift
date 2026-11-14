#if os(macOS)
import XCTest
@testable import Rubien

final class DictationFailurePresentationTests: XCTestCase {
    private let allCases: [DictationFailure] = [
        .microphoneDenied,
        .speechRecognitionDenied,
        .languageUnsupported,
        .noMicrophone,
        .editorUnavailable,
        .recognitionFailed("The model was unavailable."),
    ]

    func testEveryFailureHasTitleAndMessage() {
        for failure in allCases {
            XCTAssertFalse(failure.title.isEmpty, "\(failure)")
            XCTAssertFalse(failure.message.isEmpty, "\(failure)")
        }
    }

    func testOnlyPermissionFailuresLinkToTheirPrivacyPane() {
        XCTAssertEqual(
            DictationFailure.microphoneDenied.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        XCTAssertEqual(
            DictationFailure.speechRecognitionDenied.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        for failure in allCases where failure != .microphoneDenied && failure != .speechRecognitionDenied {
            XCTAssertNil(failure.settingsURL, "\(failure)")
        }
    }

    func testNoMicrophoneCoversMissingAndChangedInput() {
        let message = DictationFailure.noMicrophone.message
        XCTAssertTrue(message.contains("couldn’t find a microphone"))
        XCTAssertTrue(message.contains("input device changed"))
    }

    func testRecognitionFailureShowsItsDetailWhenThereIsOne() {
        XCTAssertTrue(
            DictationFailure.recognitionFailed("The model was unavailable.").message
                .contains("The model was unavailable."))
        XCTAssertEqual(
            DictationFailure.recognitionFailed("  ").message,
            "Speech recognition failed. Try again.")
    }
}

final class DictationLanguageTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    func testStartLocaleFallsBackToTheSystemLanguage() {
        let current = Locale(identifier: "de_DE")
        XCTAssertEqual(DictationLanguage.startLocale(storedIdentifier: nil, current: current), current)
        XCTAssertEqual(DictationLanguage.startLocale(storedIdentifier: "", current: current), current)
    }

    func testStartLocaleUsesTheStoredLanguage() {
        let locale = DictationLanguage.startLocale(
            storedIdentifier: "zh-CN", current: Locale(identifier: "en_US"))
        XCTAssertEqual(locale.identifier(.bcp47), "zh-CN")
    }

    func testOptionsUseBCP47IdentifiersAndDisplayNames() {
        let options = DictationLanguage.options(
            supported: [Locale(identifier: "fr_FR"), Locale(identifier: "en_US")],
            storedIdentifier: nil,
            displayLocale: english)
        XCTAssertEqual(options.map(\.id), ["fr-FR", "en-US"])
        XCTAssertEqual(options.map(\.name), ["French (France)", "English (United States)"])
    }

    func testStoredLanguageInTheListIsNotRepeated() {
        let options = DictationLanguage.options(
            supported: [Locale(identifier: "fr_FR")],
            storedIdentifier: "fr-FR",
            displayLocale: english)
        XCTAssertEqual(options.map(\.id), ["fr-FR"])
    }

    func testStoredLanguageMissingFromTheListStaysSelectable() {
        let options = DictationLanguage.options(
            supported: [Locale(identifier: "en_US")],
            storedIdentifier: "ja-JP",
            displayLocale: english)
        XCTAssertEqual(options.map(\.id), ["ja-JP", "en-US"])
        XCTAssertEqual(options.first?.name, "Japanese (Japan)")
    }
}
#endif
