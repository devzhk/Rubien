#if os(macOS)
import Foundation

/// Runs at most one dictation session for the whole app and feeds its transcript
/// to the composer that started it.
///
/// A session can end three ways. `finish` is the user's Stop: capture stops, and
/// words already heard still arrive for up to `finishDeadline`. `freeze` stops
/// at once and keeps exactly the text on screen; it is what sending, switching
/// surfaces, and quitting use. An interruption from the editor (the user typed)
/// freezes too.
///
/// The app keeps one controller for its whole life. A running session holds the
/// controller until it ends.
@MainActor
final class DictationController: ObservableObject {
    /// Identifies one composer surface for as long as its view lives.
    struct Owner: Hashable {
        private let id = UUID()
    }

    enum State: Equatable {
        case idle
        /// Waiting on a permission prompt or on the engine getting ready.
        /// `progress` is set while a speech model downloads.
        case preparing(progress: Double?)
        case listening
        /// Capture has stopped; the last words are still being recognized.
        case finishing
    }

    struct Failure: Equatable {
        let owner: Owner
        let reason: DictationFailure
    }

    static let finishDeadline: Duration = .milliseconds(1500)
    /// A session that hears nothing new for this long finishes by itself, so a
    /// forgotten microphone does not stay open.
    static let silenceTimeout: Duration = .seconds(30)

    @Published private(set) var state: State = .idle
    /// The surface `state` belongs to. Every other surface is idle.
    @Published private(set) var owner: Owner?
    @Published private(set) var failure: Failure?

    /// Doubles as the session's generation: asynchronous work captures its
    /// session and continues only while that object is still the current one.
    private final class Session {
        let owner: Owner
        let bridge: ComposerDictationBridge
        var engine: (any DictationEngine)?
        var lastTranscript: String?
        var run: Task<Void, Never>?
        var silenceTimer: Task<Void, Never>?
        var deadline: Task<Void, Never>?

        init(owner: Owner, bridge: ComposerDictationBridge) {
            self.owner = owner
            self.bridge = bridge
        }
    }

    private var session: Session?
    private let makeEngine: DictationEngineFactory
    private let authorizer: any DictationAuthorizing
    private let sleep: DictationSleep

    init(
        makeEngine: @escaping DictationEngineFactory,
        authorizer: any DictationAuthorizing,
        sleep: @escaping DictationSleep = { try await Task.sleep(for: $0) }
    ) {
        self.makeEngine = makeEngine
        self.authorizer = authorizer
        self.sleep = sleep
    }

    func state(for owner: Owner) -> State {
        self.owner == owner ? state : .idle
    }

    // MARK: Starting and stopping

    /// Starts dictating into `bridge`'s editor. A session that is already
    /// running, for this or any other surface, is frozen first.
    func start(
        owner: Owner,
        bridge: ComposerDictationBridge,
        locale: Locale,
        separatingFromPrecedingText: Bool = false
    ) {
        freezeAll()
        failure = nil
        let session = Session(owner: owner, bridge: bridge)
        self.session = session
        self.owner = owner
        state = .preparing(progress: nil)
        session.run = Task { [weak self] in
            await self?.run(
                session, locale: locale, separatingFromPrecedingText: separatingFromPrecedingText)
        }
    }

    /// The user's Stop. While listening, capture stops and the last words are
    /// still applied; at any other stage the session simply ends.
    func finish(owner: Owner) {
        guard let session, session.owner == owner else { return }
        guard state == .listening, let engine = session.engine else {
            close(session)
            return
        }
        state = .finishing
        session.silenceTimer?.cancel()
        engine.finish()
        session.deadline = Task { [weak self, sleep] in
            do { try await sleep(Self.finishDeadline) } catch { return }
            guard !Task.isCancelled else { return }
            self?.close(session)
        }
    }

    /// Stops now and keeps the text as it is shown. Does nothing unless `owner`
    /// holds the session, so a surface that is going away cannot stop the one
    /// that took over from it.
    func freeze(owner: Owner) {
        guard let session, session.owner == owner else { return }
        close(session)
    }

    /// Stops whichever session is running.
    func freezeAll() {
        if let session { close(session) }
    }

    func clearFailure(owner: Owner) {
        if failure?.owner == owner { failure = nil }
    }

    // MARK: Session

    private func isCurrent(_ session: Session) -> Bool {
        self.session === session
    }

    private func run(
        _ session: Session,
        locale: Locale,
        separatingFromPrecedingText: Bool
    ) async {
        // Every await below can outlast the session; each is followed by a
        // check that this session is still the current one.
        do {
            let engine = try await makeEngine(locale)
            guard isCurrent(session) else {
                engine.cancel()
                return
            }
            session.engine = engine

            for permission in DictationPermission.allCases
            where engine.requiredPermissions.contains(permission) {
                let granted = await authorizer.requestAccess(to: permission)
                guard isCurrent(session) else { return }
                guard granted else {
                    throw permission == .microphone
                        ? DictationFailure.microphoneDenied
                        : DictationFailure.speechRecognitionDenied
                }
            }

            // Weak: an engine may keep this callback, and the session keeps the engine.
            try await engine.prepare { [weak self, weak session] progress in
                guard let self, let session, self.isCurrent(session),
                      case .preparing = self.state
                else { return }
                self.state = .preparing(progress: progress)
            }
            guard isCurrent(session) else { return }

            // Claim the editor before opening the microphone, so a composer
            // that cannot take text never starts a recording.
            guard session.bridge.begin(separatingFromPrecedingText: separatingFromPrecedingText)
            else { throw DictationFailure.editorUnavailable }
            guard isCurrent(session) else {
                // Ended from an editor callback while the editor was being
                // claimed; give the claim back.
                session.bridge.end()
                return
            }
            session.bridge.onInterruption = { [weak self] in self?.close(session) }

            let transcripts = try await engine.start()
            guard isCurrent(session) else {
                // The session ended while the engine was starting; make sure
                // a capture that began after that cancel does not stay open.
                engine.cancel()
                return
            }
            state = .listening
            restartSilenceTimer(for: session)

            for try await transcript in transcripts {
                guard isCurrent(session) else { return }
                session.bridge.update(transcript: transcript)
                // Only new text counts as activity; an engine repeating itself
                // must not keep the microphone open.
                guard isCurrent(session), transcript != session.lastTranscript else { continue }
                session.lastTranscript = transcript
                if state == .listening { restartSilenceTimer(for: session) }
            }
            close(session)
        } catch {
            guard isCurrent(session) else { return }
            close(session)
            failure = Failure(
                owner: session.owner,
                reason: (error as? DictationFailure) ?? .recognitionFailed(error.localizedDescription))
        }
    }

    /// The one place a session ends. Late calls for a session that is no longer
    /// current do nothing, which is what drops results that arrive after a stop.
    private func close(_ session: Session) {
        guard isCurrent(session) else { return }
        self.session = nil
        owner = nil
        state = .idle
        session.bridge.onInterruption = nil
        session.bridge.end()
        session.engine?.cancel()
        session.engine = nil
        session.run?.cancel()
        session.silenceTimer?.cancel()
        session.deadline?.cancel()
    }

    private func restartSilenceTimer(for session: Session) {
        session.silenceTimer?.cancel()
        session.silenceTimer = Task { [weak self, sleep] in
            do { try await sleep(Self.silenceTimeout) } catch { return }
            guard !Task.isCancelled, let self, self.isCurrent(session) else { return }
            self.finish(owner: session.owner)
        }
    }
}
#endif
