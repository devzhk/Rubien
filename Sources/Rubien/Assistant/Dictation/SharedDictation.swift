#if os(macOS)
import Foundation

extension DictationController {
    /// The app's one controller, listening to the microphone.
    static let shared = DictationController(
        makeEngine: sharedEngineFactory(),
        authorizer: SystemDictationAuthorizer())

    private static func sharedEngineFactory() -> DictationEngineFactory {
        #if DEBUG
        // Debug builds can dictate a recording through the real composer, with
        // no microphone and no permission prompt.
        if let path = ProcessInfo.processInfo.environment["RUBIEN_DICTATION_AUDIO_FILE"],
           !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return { locale in
                try await DictationEngines.makeEngine(
                    for: locale,
                    audioSource: FileDictationAudioSource(url: url, paced: true))
            }
        }
        #endif
        return { locale in try await DictationEngines.makeEngine(for: locale) }
    }
}

/// The language dictation starts in, and how Settings lists the choices.
enum DictationLanguage {
    struct Option: Equatable, Identifiable {
        /// A BCP-47 identifier.
        let id: String
        let name: String
    }

    /// The language a new session uses: the one chosen in Settings, else the
    /// system language. Read at every start, since reader windows are reused.
    static func startLocale(
        storedIdentifier: String? = RubienPreferences.assistantDictationLocaleIdentifier,
        current: Locale = .current
    ) -> Locale {
        guard let storedIdentifier, !storedIdentifier.isEmpty else { return current }
        return Locale(identifier: storedIdentifier)
    }

    /// The picker's languages, excluding "System language". A stored language
    /// that is no longer supported stays listed, first, so the picker can still
    /// show it.
    static func options(
        supported: [Locale],
        storedIdentifier: String?,
        displayLocale: Locale = .current
    ) -> [Option] {
        var options = supported.map {
            let id = $0.identifier(.bcp47)
            return Option(id: id, name: displayName(for: id, in: displayLocale))
        }
        if let storedIdentifier, !storedIdentifier.isEmpty,
           !options.contains(where: { $0.id == storedIdentifier }) {
            options.insert(
                Option(id: storedIdentifier, name: displayName(for: storedIdentifier, in: displayLocale)),
                at: 0)
        }
        return options
    }

    static func displayName(for identifier: String, in displayLocale: Locale = .current) -> String {
        displayLocale.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// The language's name without its region ("English", not "English (United
    /// States)"), for "System Language (English)".
    static func languageName(of locale: Locale, in displayLocale: Locale = .current) -> String {
        if let code = locale.language.languageCode?.identifier,
           let name = displayLocale.localizedString(forLanguageCode: code) {
            return name
        }
        return displayName(for: locale.identifier(.bcp47), in: displayLocale)
    }

    // MARK: Composer language menu

    /// The composer menu's label for a language: the first character of the
    /// language's name for itself when it is written in Han, kana, or Hangul
    /// ("中", "日", "한", "粤"); otherwise its uppercased language code ("EN",
    /// "DE"). A missing or malformed identifier gets a neutral placeholder.
    static func shortCode(for identifier: String?) -> String {
        let placeholder = "–"
        guard let identifier, !identifier.isEmpty else { return placeholder }
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier,
              (2...3).contains(code.count),
              code.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return placeholder }

        let script = Locale.Language(identifier: language.maximalIdentifier).script?.identifier
        if let script, eastAsianScripts.contains(script),
           let ownName = Locale(identifier: identifier).localizedString(forLanguageCode: code),
           let first = ownName.first,
           first.unicodeScalars.allSatisfy(isEastAsianLetter) {
            return String(first)
        }
        return code.uppercased()
    }

    /// Scripts that are not written with Latin-style letters, so a code like
    /// "ZH" means less to their readers than the language's own first character.
    private static let eastAsianScripts: Set<String> = [
        "Hans", "Hant", "Hani", "Jpan", "Hira", "Kana", "Hrkt", "Kore", "Hang",
    ]

    private static func isEastAsianLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF: return true  // Han
        case 0x3040...0x30FF, 0x31F0...0x31FF: return true  // Hiragana, Katakana
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return true  // Hangul
        default: return false
        }
    }

    /// The menu's quick list, as BCP-47 identifiers: the system's preferred
    /// languages that dictation supports, then recently chosen languages, then
    /// the current choice; each listed once, in that order.
    static func quickIdentifiers(
        preferred: [String],
        recents: [String],
        current: String?
    ) -> [String] {
        var seen = Set<String>()
        return (preferred + recents + [current ?? ""]).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    /// The recent languages after choosing `identifier`: it moves to the front,
    /// and the list keeps at most `limit`. Choosing the system language (nil or
    /// empty) leaves the list as it was.
    static func recents(
        afterChoosing identifier: String?,
        previous: [String],
        limit: Int = RubienPreferences.assistantDictationRecentLocaleLimit
    ) -> [String] {
        guard let identifier, !identifier.isEmpty else { return previous }
        return Array(([identifier] + previous.filter { $0 != identifier }).prefix(limit))
    }

    /// Makes `identifier` (nil for the system language) the dictation language,
    /// and records it as a recent choice. The composer menu and Settings both
    /// choose through here.
    static func choose(_ identifier: String?) {
        RubienPreferences.assistantDictationLocaleIdentifier = identifier
        RubienPreferences.assistantDictationRecentLocaleIdentifiers = recents(
            afterChoosing: identifier,
            previous: RubienPreferences.assistantDictationRecentLocaleIdentifiers)
    }
}

/// The languages the composer menu lists, loaded once per composer surface
/// (both lists are asynchronous Speech calls).
struct DictationLanguageLists: Equatable {
    /// Every supported language, for "All Languages".
    var supported: [Locale] = []
    /// The system's preferred languages mapped to supported ones (BCP-47).
    var preferred: [String] = []
    var isLoaded = false

    static func load() async -> DictationLanguageLists {
        DictationLanguageLists(
            supported: await DictationEngines.supportedLocales(),
            preferred: await DictationEngines.preferredLanguageIdentifiers(),
            isLoaded: true)
    }
}
#endif
