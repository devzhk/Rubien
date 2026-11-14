#if os(macOS)
import AVFoundation
import XCTest

@testable import Rubien

/// A three-second spoken sentence, 16 kHz mono 16-bit: "Compare the attention
/// mechanism with recurrent networks." Loaded relative to `#filePath`, like the
/// other fixtures, so no resource declaration is needed.
let dictationSpeechFixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/dictation-attention.wav")

@MainActor
final class DictationAudioSourceTests: XCTestCase {
    func testFileSourceDeliversTheWholeFileThenEnds() async throws {
        let length = try AVAudioFile(forReading: dictationSpeechFixture).length
        let source = FileDictationAudioSource(url: dictationSpeechFixture, paced: false)
        XCTAssertFalse(source.needsMicrophone)

        var frames: AVAudioFramePosition = 0
        var buffers = 0
        for try await buffer in try source.start() {
            XCTAssertEqual(buffer.format.sampleRate, 16000)
            XCTAssertEqual(buffer.format.channelCount, 1)
            frames += AVAudioFramePosition(buffer.frameLength)
            buffers += 1
        }
        XCTAssertEqual(frames, length)
        XCTAssertGreaterThan(buffers, 1, "the file is delivered in chunks")
    }

    func testStoppingAPacedFileSourceEndsItsStream() async throws {
        let source = FileDictationAudioSource(url: dictationSpeechFixture, paced: true)
        var iterator = try source.start().makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertNotNil(first)

        let stoppedAt = ContinuousClock.now
        source.stop()
        source.stop()
        while try await iterator.next() != nil {}
        XCTAssertLessThan(ContinuousClock.now - stoppedAt, .milliseconds(500))
    }

    func testSourceIsUsedOnce() async throws {
        let stoppedFirst = FileDictationAudioSource(url: dictationSpeechFixture, paced: false)
        stoppedFirst.stop()
        for try await _ in try stoppedFirst.start() { XCTFail("a stopped source delivers nothing") }

        let source = FileDictationAudioSource(url: dictationSpeechFixture, paced: false)
        for try await _ in try source.start() {}
        for try await _ in try source.start() { XCTFail("a second start delivers nothing") }
    }

    func testMissingFileThrowsFromStart() {
        let source = FileDictationAudioSource(
            url: URL(fileURLWithPath: "/nonexistent/dictation.wav"), paced: false)
        XCTAssertThrowsError(try source.start())
    }

    func testDeepCopyOwnsItsSamples() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 4
        for channel in 0..<2 {
            for frame in 0..<4 { buffer.floatChannelData![channel][frame] = Float(channel * 10 + frame) }
        }
        let copy = try XCTUnwrap(buffer.deepCopy())
        buffer.floatChannelData![1][2] = -1

        XCTAssertEqual(copy.frameLength, 4)
        XCTAssertEqual(copy.format, format)
        XCTAssertEqual(copy.floatChannelData![0][3], 3)
        XCTAssertEqual(copy.floatChannelData![1][2], 12)
    }
}

final class AnalyzerAudioConverterTests: XCTestCase {
    private let analyzerFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    func testResamplesAStreamWithoutDroppingAudio() throws {
        let microphoneFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let converter = AnalyzerAudioConverter(format: analyzerFormat)
        var frames = 0
        // One second at 48 kHz, in chunks the size of a microphone tap.
        for chunk in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: microphoneFormat, frameCapacity: 4800))
            buffer.frameLength = 4800
            for channel in 0..<2 {
                for frame in 0..<4800 {
                    let t = Double(chunk * 4800 + frame) / 48000
                    buffer.floatChannelData![channel][frame] = Float(sin(2 * .pi * 440 * t) * 0.5)
                }
            }
            if let converted = try converter.convert(buffer) {
                XCTAssertEqual(converted.format, analyzerFormat)
                frames += Int(converted.frameLength)
            }
        }
        if let remainder = try converter.flush() { frames += Int(remainder.frameLength) }
        XCTAssertEqual(Double(frames), 16000, accuracy: 2)
    }

    func testMatchingFormatPassesThrough() throws {
        let converter = AnalyzerAudioConverter(format: analyzerFormat)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: 160))
        buffer.frameLength = 160
        XCTAssertTrue(try converter.convert(buffer) === buffer)
        XCTAssertNil(try converter.flush())
    }
}
#endif
