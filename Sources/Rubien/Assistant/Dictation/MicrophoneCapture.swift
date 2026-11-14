#if os(macOS)
import AVFoundation

/// The default input device, through `AVAudioEngine`.
@MainActor
final class MicrophoneCapture: DictationAudioSource {
    typealias Continuation = AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation

    /// About eight seconds of audio at the tap's buffer size. A consumer that
    /// stalls longer loses the oldest audio rather than growing memory.
    private static let bufferLimit = 96
    private static let tapBufferSize: AVAudioFrameCount = 4096
    /// A device that keeps reconfiguring must not restart capture forever.
    private static let restartLimit = 3

    let needsMicrophone = true

    private var engine: AVAudioEngine?
    private var isTapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var continuation: Continuation?
    private var isStopped = false
    private var restarts = 0

    func start() throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingNewest(Self.bufferLimit))
        guard !isStopped, engine == nil else {
            continuation.finish()
            return stream
        }
        let engine = AVAudioEngine()
        self.engine = engine
        self.continuation = continuation
        do {
            try startCapturing(engine, into: continuation)
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
                using: Self.configurationChangeHandler(for: self))
        } catch {
            stop()
            throw (error as? DictationFailure) ?? .noMicrophone
        }
        return stream
    }

    func stop() {
        isStopped = true
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let engine {
            if isTapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        isTapInstalled = false
        engine = nil
        continuation?.finish()
        continuation = nil
    }

    private func startCapturing(_ engine: AVAudioEngine, into continuation: Continuation) throws {
        let input = engine.inputNode
        if isTapInstalled {
            input.removeTap(onBus: 0)
            isTapInstalled = false
        }
        // Using an input node whose hardware format is empty raises an
        // exception rather than an error.
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw DictationFailure.noMicrophone
        }
        input.installTap(
            onBus: 0, bufferSize: Self.tapBufferSize, format: nil,
            block: Self.tapBlock(yieldingTo: continuation))
        isTapInstalled = true
        engine.prepare()
        try engine.start()
    }

    /// The engine stops itself when the input device or its format changes,
    /// which includes a Bluetooth headset switching to its call profile as
    /// recording begins. Capture resumes on the new configuration; the tap is
    /// reinstalled because its format belongs to the old one.
    private func resumeAfterConfigurationChange() {
        guard !isStopped, let engine, let continuation else { return }
        restarts += 1
        do {
            guard restarts <= Self.restartLimit else { throw DictationFailure.noMicrophone }
            try startCapturing(engine, into: continuation)
        } catch {
            // `stop()` cleans up later, on the consumer's path.
            continuation.finish(throwing: DictationFailure.noMicrophone)
        }
    }

    // Both closures run on audio-system queues, so they are built outside the
    // main actor.

    /// Tearing the engine down inside this handler can deadlock, so it only
    /// hands off to the main actor.
    nonisolated private static func configurationChangeHandler(
        for capture: MicrophoneCapture
    ) -> @Sendable (Notification) -> Void {
        { [weak capture] _ in
            Task { @MainActor in capture?.resumeAfterConfigurationChange() }
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
