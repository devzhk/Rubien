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
}
#endif
