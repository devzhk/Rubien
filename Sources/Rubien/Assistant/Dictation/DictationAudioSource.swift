#if os(macOS)
import AVFoundation

/// Audio for one dictation session, in the source's own format. A source is
/// used once: after `stop()`, `start()` returns a stream that has already ended.
@MainActor
protocol DictationAudioSource: AnyObject {
    /// Whether starting this source opens the microphone.
    var needsMicrophone: Bool { get }

    /// Starts producing audio. The stream ends after `stop()` once the buffers
    /// already produced are read, ends by itself when the source runs out, and
    /// throws when the input is lost. Throws `DictationFailure.noMicrophone`
    /// when there is no usable input.
    func start() throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error>

    /// Stops producing audio. Safe to call at any point and more than once.
    func stop()
}

/// Plays an audio file as if it were being heard, for tests and demos.
@MainActor
final class FileDictationAudioSource: DictationAudioSource {
    let needsMicrophone = false

    private let url: URL
    private let paced: Bool
    private var reader: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation?
    private var isStopped = false

    /// - Parameter paced: Deliver audio at the speed it would be spoken, rather
    ///   than as fast as the file can be read.
    init(url: URL, paced: Bool) {
        self.url = url
        self.paced = paced
    }

    func start() throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        // Unbounded: unlike a microphone, a file outruns its consumer, and
        // dropping buffers would drop words.
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AVAudioPCMBuffer.self)
        guard !isStopped, reader == nil else {
            continuation.finish()
            return stream
        }
        let file = try AVAudioFile(forReading: url)
        let reader = Task.detached { [paced] in
            await Self.read(file, paced: paced, into: continuation)
        }
        continuation.onTermination = { _ in reader.cancel() }
        self.reader = reader
        self.continuation = continuation
        return stream
    }

    func stop() {
        isStopped = true
        reader?.cancel()
        continuation?.finish()
        continuation = nil
    }

    nonisolated private static func read(
        _ file: AVAudioFile,
        paced: Bool,
        into continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
    ) async {
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(max(1, (format.sampleRate / 10).rounded()))
        do {
            while file.framePosition < file.length, !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                    throw DictationFailure.recognitionFailed("Could not allocate an audio buffer.")
                }
                try file.read(into: buffer, frameCount: chunk)
                guard buffer.frameLength > 0 else { break }
                continuation.yield(buffer)
                if paced {
                    try await Task.sleep(for: .seconds(Double(buffer.frameLength) / format.sampleRate))
                }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}

extension AVAudioPCMBuffer {
    /// A copy that owns its samples, for buffers the audio system reuses after
    /// handing them out.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            let byteCount = min(from.mDataByteSize, to.mDataByteSize)
            toData.copyMemory(from: fromData, byteCount: Int(byteCount))
        }
        return copy
    }
}
#endif
