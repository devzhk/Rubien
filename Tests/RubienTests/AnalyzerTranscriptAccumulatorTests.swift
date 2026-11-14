#if os(macOS)
import XCTest

@testable import Rubien

final class AnalyzerTranscriptAccumulatorTests: XCTestCase {
    func testFinalSegmentsAppendInOrder() {
        var accumulator = AnalyzerTranscriptAccumulator()
        accumulator.apply(text: "Compare the attention", isFinal: true)
        accumulator.apply(text: " mechanism", isFinal: true)
        accumulator.apply(text: " with recurrent networks.", isFinal: true)
        XCTAssertEqual(accumulator.transcript, "Compare the attention mechanism with recurrent networks.")
        XCTAssertEqual(accumulator.finalized, accumulator.transcript)
        XCTAssertEqual(accumulator.volatile, "")
    }

    func testVolatileTailIsReplacedEachTime() {
        var accumulator = AnalyzerTranscriptAccumulator()
        accumulator.apply(text: "Compare the", isFinal: true)
        var shown: [String] = []
        for guess in [" at", " attend", " attention mech", " attention mechanism"] {
            accumulator.apply(text: guess, isFinal: false)
            shown.append(accumulator.transcript)
        }
        XCTAssertEqual(shown, [
            "Compare the at",
            "Compare the attend",
            "Compare the attention mech",
            "Compare the attention mechanism",
        ])
        XCTAssertEqual(accumulator.finalized, "Compare the")
    }

    func testFinalResultReplacesTheVolatileGuessForTheSameSpeech() {
        var accumulator = AnalyzerTranscriptAccumulator()
        accumulator.apply(text: "Recurrent net", isFinal: false)
        accumulator.apply(text: "Recurrent networks", isFinal: false)
        accumulator.apply(text: "Recurrent networks.", isFinal: true)
        XCTAssertEqual(accumulator.transcript, "Recurrent networks.")
        XCTAssertEqual(accumulator.volatile, "")

        accumulator.apply(text: " They", isFinal: false)
        XCTAssertEqual(accumulator.transcript, "Recurrent networks. They")
    }

    func testFinalResultCanDifferFromTheLastGuess() {
        var accumulator = AnalyzerTranscriptAccumulator()
        accumulator.apply(text: "attention mechanic", isFinal: false)
        accumulator.apply(text: "attention mechanism", isFinal: true)
        XCTAssertEqual(accumulator.transcript, "attention mechanism")
    }

    func testEmptyResults() {
        var accumulator = AnalyzerTranscriptAccumulator()
        XCTAssertFalse(accumulator.apply(text: "", isFinal: false))
        XCTAssertFalse(accumulator.apply(text: "", isFinal: true))
        XCTAssertEqual(accumulator.transcript, "")

        accumulator.apply(text: "Hello", isFinal: false)
        XCTAssertTrue(accumulator.apply(text: "", isFinal: false), "an empty guess clears the tail")
        XCTAssertEqual(accumulator.transcript, "")

        accumulator.apply(text: "Hello", isFinal: true)
        accumulator.apply(text: " there", isFinal: false)
        XCTAssertTrue(accumulator.apply(text: "", isFinal: true), "an empty final result drops the guess")
        XCTAssertEqual(accumulator.transcript, "Hello")
    }

    func testReportsWhetherTheTranscriptChanged() {
        var accumulator = AnalyzerTranscriptAccumulator()
        XCTAssertTrue(accumulator.apply(text: "Hello", isFinal: false))
        XCTAssertFalse(accumulator.apply(text: "Hello", isFinal: false))
        XCTAssertFalse(accumulator.apply(text: "Hello", isFinal: true), "confirming the guess shows no change")
        XCTAssertTrue(accumulator.apply(text: " world", isFinal: false))
    }

    func testRecognizerSpacingIsKept() {
        var accumulator = AnalyzerTranscriptAccumulator()
        accumulator.apply(text: " Leading", isFinal: true)
        accumulator.apply(text: "joined", isFinal: true)
        accumulator.apply(text: "  two spaces ", isFinal: true)
        accumulator.apply(text: "注意力机制", isFinal: true)
        accumulator.apply(text: "。", isFinal: false)
        XCTAssertEqual(accumulator.transcript, " Leadingjoined  two spaces 注意力机制。")
    }
}
#endif
