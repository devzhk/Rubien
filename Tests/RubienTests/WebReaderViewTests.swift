import XCTest
@testable import Rubien
@testable import RubienCore

final class WebReaderViewTests: XCTestCase {
    func testTranscriptMarkupDetectionIgnoresCSSClassDefinitions() {
        let html = """
        <html>
        <head>
          <style>
            .rubien-yt-transcript { border: 1px solid red; }
          </style>
        </head>
        <body>
          <article class="article"><div id="article-content">Hello</div></article>
        </body>
        </html>
        """

        XCTAssertFalse(WebReaderViewModel.htmlContainsRenderedTranscriptBlock(html))
    }

    func testTranscriptMarkupDetectionRecognizesRenderedBlockAndPlaceholder() {
        let rendered = #"<details class="rubien-yt-transcript" open><summary>字幕 / Transcript</summary><pre>x</pre></details>"#
        XCTAssertTrue(WebReaderViewModel.htmlContainsRenderedTranscriptBlock(rendered))

        let placeholder = #"<div id="rubien-yt-transcript-loading" class="rubien-yt-transcript"></div>"#
        XCTAssertTrue(WebReaderViewModel.htmlContainsRenderedTranscriptBlock(placeholder))
    }

    func testYouTubeCoverCleanupRemovesLeadingStandaloneMediaBlock() {
        let html = """
        <div class="rubien-md-media-block"><img class="rubien-md-image" src="https://img.youtube.com/vi/demo/mqdefault.jpg" alt="cover" loading="lazy"></div>
        <p>正文第一段</p>
        """

        let cleaned = WebReaderViewModel.htmlByRemovingLeadingYouTubeCoverMedia(html)

        XCTAssertFalse(cleaned.contains("rubien-md-media-block"))
        XCTAssertTrue(cleaned.contains("<p>正文第一段</p>"))
    }

    func testYouTubeCleanupRemovesLegacyFallbackShellAndSummary() {
        let html = """
        <article class="rubien-youtube-fallback"><div class="rubien-yt-player-shell" data-watch-url="https://www.youtube.com/watch?v=demo"><button class="rubien-yt-player-wrap" type="button"><img src="https://img.youtube.com/vi/demo/maxresdefault.jpg" alt=""><div class="rubien-yt-play-btn">▶</div></button><div class="rubien-yt-player-actions"><a class="rubien-yt-open-link" href="https://www.youtube.com/watch?v=demo" target="_blank" rel="noopener noreferrer">在浏览器中打开</a></div></div><p class="rubien-yt-desc">摘要</p><details class="rubien-yt-transcript" open><summary>字幕 / Transcript</summary><pre>line</pre></details></article>
        """

        let cleaned = WebReaderViewModel.cleanedYouTubeArticleBodyHTML(html)

        XCTAssertFalse(cleaned.contains("rubien-yt-player-shell"))
        XCTAssertFalse(cleaned.contains("rubien-yt-desc"))
        XCTAssertFalse(cleaned.contains("在浏览器中打开"))
        XCTAssertTrue(cleaned.contains("rubien-yt-transcript"))
    }
}
