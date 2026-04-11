import XCTest
@testable import Rubien
@testable import RubienCore

final class ReaderExtractionManagerTests: XCTestCase {
    func testYouTubeTranscriptBootstrapScriptIncludesTranscriptEndpointFlow() {
        let script = ReaderExtractionManager.youtubeTranscriptBootstrapScriptForTesting()

        XCTAssertTrue(script.contains("getTranscriptEndpoint"))
        XCTAssertTrue(script.contains("/youtubei/v1/get_transcript"))
        XCTAssertTrue(script.contains("extractTranscriptFromRendererJSON"))
        XCTAssertTrue(script.contains("transcriptSegmentRenderer"))
        XCTAssertTrue(script.contains("X-YouTube-Client-Name"))
    }

    func testYouTubeFallbackBootstrapScriptKeepsDescriptionOutOfBodyHTML() {
        let script = ReaderExtractionManager.youtubeFallbackBootstrapScriptForTesting()

        XCTAssertFalse(script.contains("rubien-yt-desc"))
        XCTAssertTrue(script.contains("excerpt: desc"))
        XCTAssertTrue(script.contains("rubien-youtube-fallback"))
    }
}
