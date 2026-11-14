#if os(macOS)
import AVFoundation
import Speech
import XCTest

@testable import Rubien

/// Runs the real speech analyzer on the spoken fixture. Opt-in: it needs the
/// en_US speech model installed and takes several seconds. Audio comes from the
/// file source, so the microphone is never opened.
@MainActor
final class AnalyzerDictationEngineLiveTests: XCTestCase {
    private struct TimedOut: Error {}

    override func setUp() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["RUBIEN_DICTATION_LIVE_TESTS"] != "1",
            "Set RUBIEN_DICTATION_LIVE_TESTS=1 to run")
    }

    func testSpeechTranscriberTranscribesTheSpokenFixture() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Needs macOS 26") }
        try await transcribeFixture(with: .speechTranscriber)
    }

    func testDictationTranscriberTranscribesTheSpokenFixture() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Needs macOS 26") }
        try await transcribeFixture(with: .dictationTranscriber)
    }

    @available(macOS 26.0, *)
    private func transcribeFixture(with module: AnalyzerDictationEngine.Module) async throws {
        let source = ObservedAudioSource(FileDictationAudioSource(url: dictationSpeechFixture, paced: false))
        let engine = try await makeEngine(module, source: source)
        XCTAssertEqual(engine.requiredPermissions, [])

        try await engine.prepare { _ in }
        let transcripts = try await engine.start()
        let collected = Task { () throws -> [String] in
            var all: [String] = []
            for try await transcript in transcripts { all.append(transcript) }
            return all
        }
        try await within(.seconds(10)) { await source.waitUntilEnded() }
        engine.finish()
        let all = try await within(.seconds(30)) { try await collected.value }

        let transcript = try XCTUnwrap(all.last)
        print("Live dictation transcript, \(module) (\(all.count) updates): \(transcript)")
        for word in ["compare", "attention", "mechanism", "recurrent", "networks"] {
            XCTAssertTrue(transcript.lowercased().contains(word), "missing \"\(word)\" in \"\(transcript)\"")
        }
        engine.cancel()
    }

    /// Also checks that partial text streams while audio is still arriving,
    /// before any finish: the paced file is spoken in real time.
    func testPartialsStreamWhileSpeakingAndCancelEndsTheStreamPromptly() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Needs macOS 26") }
        let source = ObservedAudioSource(FileDictationAudioSource(url: dictationSpeechFixture, paced: true))
        let engine = try await makeEngine(.speechTranscriber, source: source)
        try await engine.prepare { _ in }
        let transcripts = try await engine.start()

        var iterator = transcripts.makeAsyncIterator()
        let first = try await within(.seconds(10)) { try await iterator.next() }
        print("Live dictation partial before cancel: \(first ?? "nil")")
        XCTAssertNotNil(first)
        XCTAssertFalse(source.hasEnded, "the first partial arrives while the sentence is still being spoken")

        let cancelledAt = ContinuousClock.now
        engine.cancel()
        let rest = try await within(.seconds(2)) { () throws -> Int in
            var count = 0
            while try await iterator.next() != nil { count += 1 }
            return count
        }
        let elapsed = ContinuousClock.now - cancelledAt
        print("Stream ended \(elapsed) after cancel, \(rest) updates after it")
        XCTAssertLessThan(elapsed, .milliseconds(500))
        // A finished stream still hands out what it had queued; the stream keeps
        // only the newest transcript, so at most one arrives after cancel.
        XCTAssertLessThanOrEqual(rest, 1)

        engine.cancel()
        engine.finish()
    }

    /// The whole chain short of the UI: the controller picks and drives the real
    /// engine, and the transcript lands in a composer editor through the bridge.
    func testControllerDictatesTheFixtureIntoAComposerEditor() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Needs macOS 26") }
        let textView = ComposerTextView.makeTextView()
        textView.string = "Note:"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        let bridge = ComposerDictationBridge()
        textView.dictationBridge = bridge

        let source = ObservedAudioSource(FileDictationAudioSource(url: dictationSpeechFixture, paced: true))
        let controller = DictationController(
            makeEngine: { locale in
                try await DictationEngines.makeEngine(for: locale, audioSource: source)
            },
            // A file source needs no permission, so this is never consulted.
            authorizer: SystemDictationAuthorizer())
        let owner = DictationController.Owner()

        controller.start(owner: owner, bridge: bridge, locale: Locale(identifier: "en_US"))
        try await within(.seconds(20)) { await source.waitUntilEnded() }
        XCTAssertEqual(controller.state(for: owner), .listening)
        let whileListening = textView.string
        XCTAssertGreaterThan(whileListening.count, "Note:".count, "text streams in before Stop")

        controller.finish(owner: owner)
        _ = try await within(.seconds(10)) { () throws -> Bool in
            while controller.state != .idle { try await Task.sleep(for: .milliseconds(20)) }
            return true
        }
        XCTAssertNil(controller.failure)
        XCTAssertFalse(bridge.isActive)

        let text = textView.string
        print("Live controller result: \(text)")
        XCTAssertTrue(text.hasPrefix("Note: "), "dictation is separated from the text before it")
        for word in ["compare", "attention", "mechanism", "recurrent", "networks"] {
            XCTAssertTrue(text.lowercased().contains(word), "missing \"\(word)\" in \"\(text)\"")
        }
    }

    // MARK: Helpers

    @available(macOS 26.0, *)
    private func makeEngine(
        _ module: AnalyzerDictationEngine.Module,
        source: any DictationAudioSource
    ) async throws -> AnalyzerDictationEngine {
        let english = Locale(identifier: "en_US")
        let supported: Locale?
        switch module {
        case .speechTranscriber:
            try XCTSkipUnless(SpeechTranscriber.isAvailable, "SpeechTranscriber is unavailable on this Mac")
            supported = await SpeechTranscriber.supportedLocale(equivalentTo: english)
        case .dictationTranscriber:
            supported = await DictationTranscriber.supportedLocale(equivalentTo: english)
        }
        return AnalyzerDictationEngine(locale: try XCTUnwrap(supported), module: module, source: source)
    }

    private func within<T: Sendable>(
        _ limit: Duration,
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { @MainActor in try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let result = try await group.next(), let value = result else { throw TimedOut() }
            return value
        }
    }
}

/// Passes another source's audio through and records when it has all been read.
@MainActor
private final class ObservedAudioSource: DictationAudioSource {
    private let base: any DictationAudioSource
    private(set) var hasEnded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ base: any DictationAudioSource) {
        self.base = base
    }

    var needsMicrophone: Bool { base.needsMicrophone }

    func start() throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let upstream = try base.start()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AVAudioPCMBuffer.self)
        Task {
            do {
                for try await buffer in upstream { continuation.yield(buffer) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            hasEnded = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
        return stream
    }

    func stop() { base.stop() }

    func waitUntilEnded() async {
        if hasEnded { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
#endif
