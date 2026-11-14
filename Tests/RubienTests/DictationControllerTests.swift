#if os(macOS)
import AppKit
import XCTest

@testable import Rubien

// MARK: - Fakes

/// Suspends callers until the test opens it.
@MainActor
private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
private final class FakeEngine: DictationEngine {
    var requiredPermissions: Set<DictationPermission> = [.microphone]
    var prepareGate: Gate?
    var prepareError: Error?
    var startGate: Gate?
    var startError: Error?
    /// A real engine ends its stream when cancelled. Turning this off checks
    /// that the controller itself ignores what a cancelled engine still sends.
    var endsStreamOnCancel = true
    private(set) var calls: [String] = []
    private var reportProgress: (@MainActor (Double) -> Void)?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    func prepare(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        calls.append("prepare")
        reportProgress = onProgress
        await prepareGate?.wait()
        if let prepareError { throw prepareError }
    }

    func start() async throws -> AsyncThrowingStream<String, Error> {
        calls.append("start")
        await startGate?.wait()
        if let startError { throw startError }
        return AsyncThrowingStream { continuation = $0 }
    }

    func finish() { calls.append("finish") }

    func cancel() {
        calls.append("cancel")
        if endsStreamOnCancel { continuation?.finish() }
    }

    func progress(_ value: Double) { reportProgress?(value) }
    func emit(_ transcript: String) { continuation?.yield(transcript) }
    func complete() { continuation?.finish() }
    func fail(_ error: Error) { continuation?.finish(throwing: error) }
}

@MainActor
private final class FakeAuthorizer: DictationAuthorizing {
    var answers: [DictationPermission: Bool] = [.microphone: true, .speechRecognition: true]
    var gate: Gate?
    private(set) var requested: [DictationPermission] = []

    func requestAccess(to permission: DictationPermission) async -> Bool {
        requested.append(permission)
        await gate?.wait()
        return answers[permission] ?? false
    }
}

/// Stands in for the clock: sleeps stay pending until the test fires them.
private final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int: (duration: Duration, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var nextID = 0

    func sleep(_ duration: Duration) async throws {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { pending[id] = (duration, continuation) }
                // Cancellation may have run before the sleep was registered.
                if Task.isCancelled { resume(id, throwing: CancellationError()) }
            }
        } onCancel: {
            resume(id, throwing: CancellationError())
        }
    }

    /// Completes every pending sleep of exactly `duration`.
    func fire(_ duration: Duration) {
        let ids = lock.withLock { pending.filter { $0.value.duration == duration }.map(\.key) }
        ids.forEach { resume($0, throwing: nil) }
    }

    func pendingCount(_ duration: Duration) -> Int {
        pendingIDs(duration).count
    }

    /// Identifies the pending sleeps of `duration`, so a test can tell a timer
    /// that was replaced from one that was left running.
    func pendingIDs(_ duration: Duration) -> Set<Int> {
        lock.withLock { Set(pending.filter { $0.value.duration == duration }.map(\.key)) }
    }

    private func resume(_ id: Int, throwing error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
        if let error { entry.continuation.resume(throwing: error) } else { entry.continuation.resume() }
    }
}

// MARK: - Tests

@MainActor
final class DictationControllerTests: XCTestCase {
    /// One composer surface: a real editor and bridge, plus its owner identity.
    @MainActor
    private final class Surface {
        let owner = DictationController.Owner()
        let textView = ComposerTextView.makeTextView()
        let bridge = ComposerDictationBridge()

        init(_ text: String = "") {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.dictationBridge = bridge
        }

        var text: String { textView.string }

        func type(_ text: String) {
            textView.insertText(text, replacementRange: textView.selectedRange())
        }
    }

    private var engines: [FakeEngine] = []
    private var nextEngine: FakeEngine?
    private var factoryError: Error?
    private var factoryGate: Gate?
    private var requestedLocales: [Locale] = []
    private var authorizer: FakeAuthorizer!
    private var sleeper: ManualSleeper!
    private var controller: DictationController!

    override func setUp() async throws {
        try await super.setUp()
        engines = []
        nextEngine = nil
        factoryError = nil
        factoryGate = nil
        requestedLocales = []
        authorizer = FakeAuthorizer()
        let sleeper = ManualSleeper()
        self.sleeper = sleeper
        controller = DictationController(
            makeEngine: { [unowned self] locale in
                requestedLocales.append(locale)
                await factoryGate?.wait()
                if let factoryError { throw factoryError }
                let engine = nextEngine ?? FakeEngine()
                nextEngine = nil
                engines.append(engine)
                return engine
            },
            authorizer: authorizer,
            sleep: { try await sleeper.sleep($0) })
    }

    override func tearDown() async throws {
        // Let every suspended session run to its end, so no test leaves work
        // (and the controller it holds) parked on a gate.
        controller.freezeAll()
        factoryGate?.open()
        authorizer.gate?.open()
        for engine in engines + [nextEngine].compactMap({ $0 }) {
            engine.prepareGate?.open()
            engine.startGate?.open()
            engine.complete()
        }
        engines = []
        controller = nil
        try await super.tearDown()
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Condition was not met in time", file: file, line: line)
    }

    /// Gives already-scheduled work a chance to run, for asserting that
    /// something did not happen.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func startListening(_ surface: Surface) async -> FakeEngine {
        let count = engines.count
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: Locale(identifier: "en_US"))
        await waitUntil { self.engines.count > count && self.controller.state == .listening }
        return engines[count]
    }

    // MARK: Starting

    func testStartPreparesThenListensAndStreamsIntoTheEditor() async {
        let surface = Surface("Note:")
        let other = Surface()
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(controller.state(for: surface.owner), .preparing(progress: nil))
        XCTAssertEqual(controller.state(for: other.owner), .idle)

        await waitUntil { self.controller.state == .listening }
        let engine = engines[0]
        XCTAssertEqual(requestedLocales, [Locale(identifier: "en_GB")])
        XCTAssertEqual(authorizer.requested, [.microphone])
        XCTAssertEqual(engine.calls, ["prepare", "start"])
        XCTAssertEqual(controller.state(for: other.owner), .idle)

        engine.emit("hello")
        await waitUntil { surface.text == "Note: hello" }
        engine.emit("hello world")
        await waitUntil { surface.text == "Note: hello world" }
    }

    func testRequestsEachPermissionTheEngineNeedsMicrophoneFirst() async {
        let engine = FakeEngine()
        engine.requiredPermissions = [.speechRecognition, .microphone]
        nextEngine = engine
        let surface = Surface()
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: .current)
        await waitUntil { self.controller.state == .listening }
        XCTAssertEqual(authorizer.requested, [.microphone, .speechRecognition])
    }

    func testDownloadProgressIsReportedWhilePreparing() async {
        let engine = FakeEngine()
        engine.prepareGate = Gate()
        nextEngine = engine
        let surface = Surface()
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: .current)
        await waitUntil { engine.calls == ["prepare"] }

        engine.progress(0.4)
        XCTAssertEqual(controller.state, .preparing(progress: 0.4))
        engine.prepareGate?.open()
        await waitUntil { self.controller.state == .listening }

        // A late progress report must not pull the state back to preparing.
        engine.progress(0.9)
        XCTAssertEqual(controller.state, .listening)
    }

    /// The caret can move during a permission prompt or model download, so
    /// whether to separate from the preceding text is asked when the editor is
    /// claimed, not when Start is clicked.
    func testSeparationIsDecidedWhenTheEditorIsClaimed() async {
        authorizer.gate = Gate()
        let surface = Surface("abc")
        var asked = 0
        var separate = false
        controller.start(
            owner: surface.owner, bridge: surface.bridge, locale: .current,
            separatingFromPrecedingText: {
                asked += 1
                return separate
            })
        await waitUntil { self.authorizer.requested == [.microphone] }
        XCTAssertEqual(asked, 0)

        separate = true
        authorizer.gate?.open()
        await waitUntil { self.controller.state == .listening }
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(surface.bridge.isActive)

        engines[0].emit("中文")
        await waitUntil { surface.text == "abc 中文" }
    }

    // MARK: Failures

    func testDeniedMicrophoneFailsWithoutTouchingTheEngineOrEditor() async {
        authorizer.answers[.microphone] = false
        let surface = Surface("abc")
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: .current)
        await waitUntil { self.controller.failure != nil }

        XCTAssertEqual(
            controller.failure,
            .init(owner: surface.owner, reason: .microphoneDenied))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.owner)
        XCTAssertEqual(engines[0].calls, ["cancel"])
        XCTAssertFalse(surface.bridge.isActive)

        controller.clearFailure(owner: Surface().owner)
        XCTAssertNotNil(controller.failure)
        controller.clearFailure(owner: surface.owner)
        XCTAssertNil(controller.failure)
    }

    func testDeniedSpeechRecognitionIsReportedForEnginesThatNeedIt() async {
        let engine = FakeEngine()
        engine.requiredPermissions = [.microphone, .speechRecognition]
        nextEngine = engine
        authorizer.answers[.speechRecognition] = false
        let surface = Surface()
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: .current)
        await waitUntil { self.controller.failure != nil }
        XCTAssertEqual(controller.failure?.reason, .speechRecognitionDenied)
    }

    func testUnsupportedLanguageFromTheFactoryIsReported() async {
        factoryError = DictationFailure.languageUnsupported
        let surface = Surface()
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: .current)
        await waitUntil { self.controller.failure != nil }
        XCTAssertEqual(controller.failure?.reason, .languageUnsupported)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(authorizer.requested.isEmpty)
    }

    func testEditorThatCannotTakeTextFailsBeforeTheMicrophoneOpens() async {
        let surface = Surface("ab")
        surface.textView.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: .current)
        await waitUntil { self.controller.failure != nil }

        XCTAssertEqual(controller.failure?.reason, .editorUnavailable)
        XCTAssertEqual(engines[0].calls, ["prepare", "cancel"])
    }

    func testEngineStartFailureEndsTheEditorSession() async {
        let engine = FakeEngine()
        engine.startError = DictationFailure.noMicrophone
        nextEngine = engine
        let surface = Surface()
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: .current)
        await waitUntil { self.controller.failure != nil }

        XCTAssertEqual(controller.failure?.reason, .noMicrophone)
        XCTAssertFalse(surface.bridge.isActive)
        XCTAssertEqual(controller.state, .idle)
    }

    func testRecognitionErrorKeepsTheTextAndReportsTheFailure() async {
        struct Boom: LocalizedError { var errorDescription: String? { "recognizer stopped" } }
        let surface = Surface()
        let engine = await startListening(surface)
        engine.emit("hello")
        await waitUntil { surface.text == "hello" }

        engine.fail(Boom())
        await waitUntil { self.controller.failure != nil }
        XCTAssertEqual(controller.failure?.reason, .recognitionFailed("recognizer stopped"))
        XCTAssertEqual(surface.text, "hello")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(surface.bridge.isActive)
    }

    // MARK: Finish

    func testFinishStopsCaptureAppliesLastWordsThenEnds() async {
        let surface = Surface()
        let engine = await startListening(surface)
        engine.emit("hello wor")
        await waitUntil { surface.text == "hello wor" }

        controller.finish(owner: surface.owner)
        XCTAssertEqual(controller.state, .finishing)
        XCTAssertEqual(engine.calls, ["prepare", "start", "finish"])

        engine.emit("hello world.")
        await waitUntil { surface.text == "hello world." }
        engine.complete()
        await waitUntil { self.controller.state == .idle }
        XCTAssertNil(controller.failure)
        XCTAssertFalse(surface.bridge.isActive)
        XCTAssertEqual(surface.text, "hello world.")
    }

    func testFinishDeadlineEndsASessionWhoseEngineNeverCompletes() async {
        let surface = Surface()
        let engine = await startListening(surface)
        engine.emit("hello")
        await waitUntil { surface.text == "hello" }

        controller.finish(owner: surface.owner)
        await waitUntil { self.sleeper.pendingCount(DictationController.finishDeadline) == 1 }
        sleeper.fire(DictationController.finishDeadline)
        await waitUntil { self.controller.state == .idle }
        XCTAssertEqual(engine.calls.last, "cancel")

        // Words that arrive after the deadline are dropped.
        engine.emit("hello world")
        await settle()
        XCTAssertEqual(surface.text, "hello")
    }

    func testFinishWhilePreparingCancelsInsteadOfWaiting() async {
        let engine = FakeEngine()
        engine.prepareGate = Gate()
        nextEngine = engine
        let surface = Surface()
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: .current)
        await waitUntil { engine.calls == ["prepare"] }

        controller.finish(owner: surface.owner)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(engine.calls, ["prepare", "cancel"])

        // The preparation completing afterwards must not bring the session back.
        engine.prepareGate?.open()
        await settle()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(engine.calls.contains("start"))
        XCTAssertFalse(surface.bridge.isActive)
    }

    func testSecondStopWhileFinishingEndsImmediately() async {
        let surface = Surface()
        let engine = await startListening(surface)
        controller.finish(owner: surface.owner)
        controller.finish(owner: surface.owner)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(engine.calls.last, "cancel")
    }

    // MARK: Freeze and interruptions

    func testFreezeKeepsVisibleTextAndDropsLateResults() async {
        let surface = Surface()
        let engine = await startListening(surface)
        engine.emit("hello")
        await waitUntil { surface.text == "hello" }

        engine.endsStreamOnCancel = false
        controller.freeze(owner: surface.owner)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(engine.calls.last, "cancel")
        XCTAssertFalse(surface.bridge.isActive)

        engine.emit("hello world")
        await settle()
        XCTAssertEqual(surface.text, "hello")
        XCTAssertNil(controller.failure)
    }

    func testEngineCompletingByItselfEndsTheSessionCleanly() async {
        let surface = Surface()
        let engine = await startListening(surface)
        engine.emit("hello")
        await waitUntil { surface.text == "hello" }

        engine.complete()
        await waitUntil { self.controller.state == .idle }
        XCTAssertNil(controller.failure)
        XCTAssertNil(controller.owner)
        XCTAssertFalse(surface.bridge.isActive)
        XCTAssertEqual(surface.text, "hello")
    }

    func testAnEndedSessionReleasesItsEngine() async {
        let surface = Surface()
        weak var releasedEngine: FakeEngine?
        do {
            let engine = await startListening(surface)
            releasedEngine = engine
            // The engine keeps the progress callback, as a real one may.
            engine.progress(1)
        }
        controller.freeze(owner: surface.owner)
        engines = []
        await waitUntil { releasedEngine == nil }
    }

    func testTypingFreezesTheSession() async {
        let surface = Surface()
        let engine = await startListening(surface)
        engine.emit("hello")
        await waitUntil { surface.text == "hello" }

        surface.type("!")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.owner)
        XCTAssertEqual(engine.calls.last, "cancel")
        XCTAssertEqual(surface.text, "hello!")
    }

    func testTypingDuringFinishDrainFreezes() async {
        let surface = Surface()
        let engine = await startListening(surface)
        engine.emit("hello")
        await waitUntil { surface.text == "hello" }
        controller.finish(owner: surface.owner)

        surface.type("!")
        XCTAssertEqual(controller.state, .idle)
        engine.emit("hello world")
        await settle()
        XCTAssertEqual(surface.text, "hello!")
    }

    func testFreezeDuringAPermissionPromptNeverStartsTheEngine() async {
        authorizer.gate = Gate()
        let surface = Surface()
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: .current)
        await waitUntil { self.authorizer.requested == [.microphone] }

        controller.freeze(owner: surface.owner)
        XCTAssertEqual(controller.state, .idle)
        authorizer.gate?.open()
        await settle()

        XCTAssertEqual(engines[0].calls, ["cancel"])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.failure)
    }

    func testFreezeWhileTheEngineIsBeingChosenCancelsItWhenItArrives() async {
        factoryGate = Gate()
        let surface = Surface()
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: .current)
        await waitUntil { self.requestedLocales.count == 1 }

        controller.freeze(owner: surface.owner)
        factoryGate?.open()
        await waitUntil { self.engines.count == 1 }
        await settle()
        XCTAssertEqual(engines[0].calls, ["cancel"])
        XCTAssertEqual(controller.state, .idle)
    }

    func testFreezeWhileTheEngineIsStartingClosesTheCaptureItOpened() async {
        let engine = FakeEngine()
        engine.startGate = Gate()
        nextEngine = engine
        let surface = Surface()
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: .current)
        await waitUntil { engine.calls == ["prepare", "start"] }

        controller.freeze(owner: surface.owner)
        XCTAssertFalse(surface.bridge.isActive)
        engine.startGate?.open()
        await settle()
        // Cancelled once by the freeze and again once the start returned.
        XCTAssertEqual(engine.calls, ["prepare", "start", "cancel", "cancel"])
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: Ownership

    func testStopsFromAnotherSurfaceAreIgnored() async {
        let surface = Surface()
        let other = Surface()
        _ = await startListening(surface)

        controller.finish(owner: other.owner)
        controller.freeze(owner: other.owner)
        XCTAssertEqual(controller.state(for: surface.owner), .listening)
    }

    func testStartingElsewhereFreezesTheFirstSurfaceAndIgnoresItsLateResults() async {
        let first = Surface()
        let second = Surface()
        let firstEngine = await startListening(first)
        firstEngine.emit("one")
        await waitUntil { first.text == "one" }

        let secondEngine = await startListening(second)
        XCTAssertEqual(firstEngine.calls.last, "cancel")
        XCTAssertFalse(first.bridge.isActive)
        XCTAssertEqual(controller.state(for: first.owner), .idle)
        XCTAssertEqual(controller.state(for: second.owner), .listening)

        firstEngine.emit("one two")
        secondEngine.emit("three")
        await waitUntil { second.text == "three" }
        XCTAssertEqual(first.text, "one")

        // The surface that lost the session cannot stop its successor.
        controller.freeze(owner: first.owner)
        first.type("!")
        XCTAssertEqual(controller.state(for: second.owner), .listening)
    }

    func testRestartingFromTheSameSurfaceWhilePreparingReplacesTheSession() async {
        let first = FakeEngine()
        first.prepareGate = Gate()
        nextEngine = first
        let surface = Surface()
        controller.start(owner: surface.owner, bridge: surface.bridge, locale: .current)
        await waitUntil { first.calls == ["prepare"] }

        let second = await startListening(surface)
        XCTAssertEqual(first.calls, ["prepare", "cancel"])

        // The abandoned preparation finishing late must not disturb its successor.
        first.progress(0.5)
        first.prepareGate?.open()
        await settle()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertFalse(first.calls.contains("start"))
        second.emit("hi")
        await waitUntil { surface.text == "hi" }
    }

    func testFreezeAllStopsWhicheverSurfaceIsActive() async {
        let surface = Surface()
        let engine = await startListening(surface)
        controller.freezeAll()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(engine.calls.last, "cancel")
    }

    // MARK: Silence

    func testOnlyNewWordsPostponeTheSilenceTimeout() async {
        let silence = DictationController.silenceTimeout
        let surface = Surface()
        let engine = await startListening(surface)
        await waitUntil { self.sleeper.pendingCount(silence) == 1 }
        let first = sleeper.pendingIDs(silence)

        // New words replace the pending timer with a fresh one.
        engine.emit("hello")
        await waitUntil { surface.text == "hello" }
        await waitUntil {
            self.sleeper.pendingCount(silence) == 1 && self.sleeper.pendingIDs(silence) != first
        }
        let second = sleeper.pendingIDs(silence)
        XCTAssertEqual(controller.state, .listening)

        // An engine repeating the same transcript is not activity.
        engine.emit("hello")
        await settle()
        XCTAssertEqual(sleeper.pendingIDs(silence), second)

        sleeper.fire(silence)
        await waitUntil { self.controller.state == .finishing }
        XCTAssertEqual(engine.calls.last, "finish")
        XCTAssertEqual(sleeper.pendingCount(silence), 0)
    }
}
#endif
