#if os(macOS)
import AVFoundation
import Speech

/// Dictation through `SpeechAnalyzer`, fed from an injected audio source.
@available(macOS 26.0, *)
@MainActor
final class AnalyzerDictationEngine: DictationEngine {
    enum Module {
        /// The newer general-purpose model.
        case speechTranscriber
        /// The model behind system dictation, for languages or devices the
        /// newer model does not cover.
        case dictationTranscriber
    }

    private enum Transcriber: Sendable {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case .speech(let module): module
            case .dictation(let module): module
            }
        }
    }

    private typealias Output = AsyncThrowingStream<String, Error>.Continuation

    private let locale: Locale
    private let transcriber: Transcriber
    private let source: any DictationAudioSource
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var output: Output?
    private var tasks: [Task<Void, Never>] = []
    private var isFinishing = false
    private var isCancelled = false

    /// - Parameter locale: A locale the module supports, as returned by its
    ///   `supportedLocale(equivalentTo:)`.
    init(locale: Locale, module: Module, source: any DictationAudioSource) {
        self.locale = locale
        self.source = source
        switch module {
        case .speechTranscriber:
            // Without `fastResults` this model holds every result, volatile
            // ones included, until the speaker pauses, so nothing streams
            // while someone is talking.
            transcriber = .speech(SpeechTranscriber(
                locale: locale, transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults], attributeOptions: []))
        case .dictationTranscriber:
            transcriber = .dictation(DictationTranscriber(
                locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults], attributeOptions: []))
        }
    }

    var requiredPermissions: Set<DictationPermission> {
        source.needsMicrophone ? [.microphone] : []
    }

    func prepare(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        let modules = [transcriber.module]
        try await Self.reserve(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await install(request, onProgress: onProgress)
        }
        try checkNotCancelled()
        // Asked before the model is installed, this is nil even for a
        // supported language.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw DictationFailure.languageUnsupported
        }
        try checkNotCancelled()
        let analyzer = SpeechAnalyzer(
            modules: modules, options: .init(priority: .userInitiated, modelRetention: .lingering))
        self.analyzer = analyzer
        analyzerFormat = format
        try await analyzer.prepareToAnalyze(in: format)
        try checkNotCancelled()
    }

    func start() async throws -> AsyncThrowingStream<String, Error> {
        guard let analyzer, let analyzerFormat else {
            throw isCancelled
                ? CancellationError()
                : DictationFailure.recognitionFailed("The recognizer was not prepared.")
        }
        // Each element is the whole transcript, so a consumer that falls behind
        // needs only the newest one.
        let (transcripts, output) = AsyncThrowingStream.makeStream(
            of: String.self, bufferingPolicy: .bufferingNewest(1))
        let (inputs, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.output = output
        self.input = input
        if isCancelled {
            output.finish()
            input.finish()
            return transcripts
        }
        tasks.append(Task { [transcriber] in await Self.publish(transcriber, to: output) })
        do {
            try await analyzer.start(inputSequence: inputs)
            // A cancel that ran while the analyzer was starting may have
            // reached it before the start did.
            guard !isCancelled else {
                await analyzer.cancelAndFinishNow()
                return transcripts
            }
            let audio = try source.start()
            tasks.append(Task {
                await Self.feed(audio, as: analyzerFormat, into: input, failing: output, analyzer: analyzer)
            })
        } catch {
            cancel()
            throw error
        }
        return transcripts
    }

    func finish() {
        guard !isCancelled, !isFinishing, let analyzer, let output else { return }
        isFinishing = true
        source.stop()
        tasks.append(Task {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                output.finish(throwing: error)
            }
        })
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        source.stop()
        input?.finish()
        output?.finish()
        tasks.forEach { $0.cancel() }
        tasks = []
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    // MARK: Preparation

    private func checkNotCancelled() throws {
        if isCancelled { throw CancellationError() }
    }

    /// An app may reserve at most `AssetInventory.maximumReservedLocales`
    /// languages. When all are taken, one other reservation is released: Rubien
    /// dictates in one language at a time, so the others are left over from
    /// earlier language settings, and the model of a released language is only
    /// removed if the system needs the space.
    private static func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        let identifier = locale.identifier(.bcp47)
        guard !reserved.contains(where: { $0.identifier(.bcp47) == identifier }) else { return }
        if reserved.count >= AssetInventory.maximumReservedLocales, let stale = reserved.first {
            await AssetInventory.release(reservedLocale: stale)
        }
        try await AssetInventory.reserve(locale: locale)
    }

    private func install(
        _ request: AssetInstallationRequest,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let progress = request.progress
        let reporter = Task {
            while !Task.isCancelled {
                onProgress(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
        onProgress(1)
    }

    // MARK: Streaming

    nonisolated private static func publish(_ transcriber: Transcriber, to output: Output) async {
        var accumulator = AnalyzerTranscriptAccumulator()
        func apply(_ text: AttributedString, isFinal: Bool) {
            if accumulator.apply(text: String(text.characters), isFinal: isFinal) {
                output.yield(accumulator.transcript)
            }
        }
        do {
            switch transcriber {
            case .speech(let module):
                for try await result in module.results { apply(result.text, isFinal: result.isFinal) }
            case .dictation(let module):
                for try await result in module.results { apply(result.text, isFinal: result.isFinal) }
            }
            output.finish()
        } catch {
            output.finish(throwing: error)
        }
    }

    /// Converts source audio into analyzer input until the source ends. A
    /// source that fails (the input device went away) fails the transcript.
    nonisolated private static func feed(
        _ audio: AsyncThrowingStream<AVAudioPCMBuffer, Error>,
        as format: AVAudioFormat,
        into input: AsyncStream<AnalyzerInput>.Continuation,
        failing output: Output,
        analyzer: SpeechAnalyzer
    ) async {
        let converter = AnalyzerAudioConverter(format: format)
        do {
            for try await buffer in audio {
                if let converted = try converter.convert(buffer) {
                    input.yield(AnalyzerInput(buffer: converted))
                }
            }
            if let remainder = try converter.flush() {
                input.yield(AnalyzerInput(buffer: remainder))
            }
            input.finish()
        } catch {
            input.finish()
            output.finish(throwing: error)
            await analyzer.cancelAndFinishNow()
        }
    }
}

/// Converts audio to one format, keeping the resampler's state from buffer to
/// buffer so a stream converts without gaps.
final class AnalyzerAudioConverter {
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(format: AVAudioFormat) {
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format {
            guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
                throw DictationFailure.recognitionFailed("Unsupported audio format: \(buffer.format)")
            }
            converter.downmix = true
            self.converter = converter
        }
        return try run(input: buffer)
    }

    /// The audio still held in the resampler at the end of the stream.
    func flush() throws -> AVAudioPCMBuffer? {
        guard converter != nil else { return nil }
        return try run(input: nil)
    }

    /// Converts `input`, or drains the converter when `input` is nil. The
    /// simple buffer-to-buffer `convert(to:from:)` cannot change sample rate.
    private func run(input: AVAudioPCMBuffer?) throws -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let ratio = format.sampleRate / converter.inputFormat.sampleRate
        let expected = (Double(input?.frameLength ?? 0) * ratio).rounded(.up)
        // Headroom for what the resampler held back from the previous buffer.
        let capacity = AVAudioFrameCount(expected) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw DictationFailure.recognitionFailed("Could not allocate an audio buffer.")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let input else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw error ?? DictationFailure.recognitionFailed("Audio conversion failed.")
        }
        return output.frameLength > 0 ? output : nil
    }
}
#endif
