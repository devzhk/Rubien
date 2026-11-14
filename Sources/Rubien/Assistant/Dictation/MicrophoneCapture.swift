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

    let needsMicrophone = true

    private var engine: AVAudioEngine?
    private var isTapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var continuation: Continuation?
    private var isStopped = false

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
            // Using an input node whose hardware format is empty raises an
            // exception rather than an error.
            let input = engine.inputNode
            let hardwareFormat = input.inputFormat(forBus: 0)
            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
                throw DictationFailure.noMicrophone
            }
            input.installTap(
                onBus: 0, bufferSize: Self.tapBufferSize, format: nil,
                block: Self.tapBlock(yieldingTo: continuation))
            isTapInstalled = true
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
                using: Self.configurationChangeHandler(endingWith: continuation))
            engine.prepare()
            try engine.start()
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

    // Both closures run on audio-system queues, so they are built outside the
    // main actor and touch nothing but the continuation.

    nonisolated private static func tapBlock(yieldingTo continuation: Continuation) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let copy = buffer.deepCopy() { continuation.yield(copy) }
        }
    }

    /// The engine has stopped itself because the input device changed. Tearing
    /// it down inside this handler can deadlock, so the handler only ends the
    /// stream; `stop()` cleans up later on the caller's path.
    nonisolated private static func configurationChangeHandler(
        endingWith continuation: Continuation
    ) -> @Sendable (Notification) -> Void {
        { _ in continuation.finish(throwing: DictationFailure.noMicrophone) }
    }
}
#endif
