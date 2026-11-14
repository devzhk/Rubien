#if os(macOS)
import Foundation
import Speech

/// Picks the dictation engine for a language.
@MainActor
enum DictationEngines {
    /// Whether this system has an engine at all. The analyzer engines need
    /// macOS 26; the older recognizer is not offered.
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// A `DictationEngineFactory` that listens to the microphone.
    static func makeEngine(for locale: Locale) async throws -> any DictationEngine {
        try await makeEngine(for: locale, audioSource: MicrophoneCapture())
    }

    /// Prefers `SpeechTranscriber`, then `DictationTranscriber`, for the first
    /// one that supports `locale`. Throws `DictationFailure.languageUnsupported`
    /// when neither does.
    static func makeEngine(
        for locale: Locale,
        audioSource: any DictationAudioSource
    ) async throws -> any DictationEngine {
        guard #available(macOS 26.0, *) else { throw DictationFailure.languageUnsupported }
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return AnalyzerDictationEngine(locale: supported, module: .speechTranscriber, source: audioSource)
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return AnalyzerDictationEngine(locale: supported, module: .dictationTranscriber, source: audioSource)
        }
        throw DictationFailure.languageUnsupported
    }
}
#endif
