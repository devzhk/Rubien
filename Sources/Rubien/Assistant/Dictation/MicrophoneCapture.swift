#if os(macOS)
import AVFoundation
import RubienExceptionCatcher

/// The default input device, through `AVAudioEngine`.
@MainActor
final class MicrophoneCapture: DictationAudioSource {
    typealias Continuation = AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation

    /// About eight seconds of audio at the tap's buffer size. A consumer that
    /// stalls longer loses the oldest audio rather than growing memory.
    private static let bufferLimit = 96
    private static let tapBufferSize: AVAudioFrameCount = 4096
    /// A device that keeps reconfiguring must not restart capture forever.
    /// Restarts further apart than `restartWindow` start a new count.
    private static let restartLimit = 3
    private static let restartWindow: Duration = .seconds(5)

    let needsMicrophone = true

    private var engine: AVAudioEngine?
    /// Identifies `engine`, so a change reported by an engine already replaced
    /// does not restart its successor.
    private var engineGeneration = 0
    private var isTapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var continuation: Continuation?
    private var isStopped = false
    private var hasStarted = false
    private var restarts = 0
    private var lastRestart: ContinuousClock.Instant?

    func start() throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingNewest(Self.bufferLimit))
        guard !isStopped, !hasStarted, engine == nil else {
            continuation.finish()
            return stream
        }
        self.continuation = continuation
        do {
            try startEngine(into: continuation)
        } catch {
            stop()
            throw (error as? DictationFailure) ?? .noMicrophone
        }
        // A change reported while the engine was starting is handled on the
        // main actor, which this method holds, so it runs after this point.
        hasStarted = true
        return stream
    }

    func stop() {
        isStopped = true
        tearDownEngine()
        continuation?.finish()
        continuation = nil
    }

    /// Builds a new engine and starts capturing from it. A device change can
    /// leave an engine's input node with the old format, and installing a tap
    /// or starting with a format that no longer matches the hardware raises an
    /// Objective-C exception, which Swift cannot catch.
    private func startEngine(into continuation: Continuation) throws {
        let engine = AVAudioEngine()
        engineGeneration += 1
        self.engine = engine
        // Observed before starting: a Bluetooth headset can switch profile as
        // its input opens, which is during `start()`.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
            using: Self.configurationChangeHandler(for: self, generation: engineGeneration))

        var failure: Error?
        let exception = ExceptionCatcher.catchException {
            let input = engine.inputNode
            let hardwareFormat = input.inputFormat(forBus: 0)
            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
                failure = DictationFailure.noMicrophone
                return
            }
            input.installTap(
                onBus: 0, bufferSize: Self.tapBufferSize, format: nil,
                block: Self.tapBlock(yieldingTo: continuation))
            isTapInstalled = true
            engine.prepare()
            do { try engine.start() } catch { failure = error }
        }
        if exception != nil { throw DictationFailure.noMicrophone }
        if let failure { throw failure }
    }

    private func tearDownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let engine {
            let hadTap = isTapInstalled
            // The input node of an engine whose device just went away can raise
            // here as well.
            _ = ExceptionCatcher.catchException {
                if hadTap { engine.inputNode.removeTap(onBus: 0) }
                engine.stop()
            }
        }
        isTapInstalled = false
        engine = nil
    }

    /// The engine stops itself when the input device or its format changes,
    /// which includes a Bluetooth headset switching to its call profile as
    /// recording begins. Capture resumes on a new engine built for the new
    /// configuration.
    private func resumeAfterConfigurationChange(generation: Int) {
        guard !isStopped, hasStarted, generation == engineGeneration, let continuation else { return }
        let now = ContinuousClock.now
        if let lastRestart, now - lastRestart > Self.restartWindow { restarts = 0 }
        restarts += 1
        lastRestart = now
        tearDownEngine()
        do {
            guard restarts <= Self.restartLimit else { throw DictationFailure.noMicrophone }
            try startEngine(into: continuation)
        } catch {
            // Without a continuation, a later change cannot reopen the input
            // before the consumer's `stop()` arrives.
            tearDownEngine()
            self.continuation = nil
            continuation.finish(throwing: DictationFailure.noMicrophone)
        }
    }

    // Both closures run on audio-system queues, so they are built outside the
    // main actor.

    /// Tearing the engine down inside this handler can deadlock, so it only
    /// hands off to the main actor.
    nonisolated private static func configurationChangeHandler(
        for capture: MicrophoneCapture,
        generation: Int
    ) -> @Sendable (Notification) -> Void {
        { [weak capture] _ in
            Task { @MainActor in capture?.resumeAfterConfigurationChange(generation: generation) }
        }
    }

    /// Touches nothing but the continuation.
    nonisolated private static func tapBlock(yieldingTo continuation: Continuation) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let copy = buffer.deepCopy() { continuation.yield(copy) }
        }
    }
}
#endif
