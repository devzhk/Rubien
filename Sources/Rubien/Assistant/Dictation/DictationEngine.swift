#if os(macOS)
import Foundation

/// A system permission a dictation engine needs before it can run.
enum DictationPermission: CaseIterable, Hashable, Sendable {
    case microphone
    /// Needed only by the older recognizer; the analyzer-based engines
    /// transcribe without it.
    case speechRecognition
}

/// Why dictation could not start or had to stop. Engines throw these directly;
/// any other error is reported as `recognitionFailed`.
enum DictationFailure: Error, Equatable {
    case microphoneDenied
    case speechRecognitionDenied
    /// No on-device recognizer exists for the requested language.
    case languageUnsupported
    case noMicrophone
    /// The composer cannot take dictated text right now (an input method is
    /// composing, there is no editable editor, or it already takes dictation).
    case editorUnavailable
    case recognitionFailed(String)
}

/// Asks for the permissions an engine needs.
@MainActor
protocol DictationAuthorizing {
    /// Prompts when the permission has not been decided yet. Returns whether
    /// access is granted.
    func requestAccess(to permission: DictationPermission) async -> Bool
}

/// One speech recognizer and its audio input, used for a single session.
@MainActor
protocol DictationEngine: AnyObject {
    var requiredPermissions: Set<DictationPermission> { get }

    /// Gets the recognizer ready, downloading its language model if needed.
    /// `onProgress` reports that download from 0 to 1.
    func prepare(onProgress: @escaping @MainActor (Double) -> Void) async throws

    /// Starts capturing and recognizing. Each element is the whole transcript
    /// so far, revised as recognition proceeds. The stream ends when
    /// recognition is complete, or throws when it fails.
    func start() async throws -> AsyncThrowingStream<String, Error>

    /// Stops capturing. The stream delivers what was already heard, then ends.
    func finish()

    /// Stops everything now. Safe to call at any point, more than once, and
    /// after the stream has ended.
    func cancel()
}

/// Chooses the engine for a language, or throws `DictationFailure.languageUnsupported`.
typealias DictationEngineFactory = @MainActor (Locale) async throws -> any DictationEngine

/// Suspends for a duration; throws when cancelled. Injected so tests control time.
typealias DictationSleep = @Sendable (Duration) async throws -> Void
#endif
