#if os(macOS)
import JavaScriptCore
import XCTest
@testable import Rubien

final class ReaderExtractionManagerTests: XCTestCase {
    func testCoverCaptureSkipsBrandAssetsButKeepsArticleImages() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(
            """
            var metadataURL = 'https://cdn.example.com/z-icon.png';
            var fallbackURL = 'https://cdn.example.com/glm-hero.png';

            function URL(value, _) {
              var stringValue = String(value || '');
              this.pathname = stringValue.replace(/^https?:\\/\\/[^/]+/, '').split(/[?#]/)[0];
              this.toString = function() { return stringValue; };
            }

            var document = {
              URL: 'https://z.ai/blog/glm-5.2',
              querySelector: function(_) {
                return metadataURL ? { content: metadataURL } : null;
              },
              querySelectorAll: function(_) {
                return [{
                  naturalWidth: 1200,
                  naturalHeight: 630,
                  currentSrc: fallbackURL,
                  src: fallbackURL,
                  getBoundingClientRect: function() { return { width: 1200, height: 630 }; },
                  getAttribute: function(_) { return ''; }
                }];
              }
            };
            """
        )

        let fallback = context.evaluateScript(ReaderExtractionManager.coverImageCaptureJS)
        XCTAssertNil(context.exception)
        XCTAssertEqual(fallback?.toString(), "https://cdn.example.com/glm-hero.png")

        context.evaluateScript("metadataURL = 'https://cdn.example.com/glm-social-card.png';")
        let metadata = context.evaluateScript(ReaderExtractionManager.coverImageCaptureJS)
        XCTAssertNil(context.exception)
        XCTAssertEqual(metadata?.toString(), "https://cdn.example.com/glm-social-card.png")

        context.evaluateScript("metadataURL = ''; fallbackURL = 'https://cdn.example.com/header-logo@2x.png';")
        let noCover = context.evaluateScript(ReaderExtractionManager.coverImageCaptureJS)
        XCTAssertNil(context.exception)
        XCTAssertEqual(noCover?.toString(), "")
    }

    func testAugmentationRejectsBrandCoverURL() {
        let article = "<body><p>Article body</p></body>"

        XCTAssertEqual(
            ReaderExtractionManager.augmentContentWithCoverImageIfMissing(
                article,
                coverImageURL: "https://cdn.example.com/z-icon.png"
            ),
            article
        )
        XCTAssertTrue(
            ReaderExtractionManager.augmentContentWithCoverImageIfMissing(
                article,
                coverImageURL: "https://cdn.example.com/glm-social-card.png"
            ).hasPrefix("<figure class=\"rubien-cover-image\">")
        )
    }

    func testLegacyBrandCoverCleanupOnlyRemovesRubienInjectedBrandAsset() {
        let article = "<body><p>Article body</p></body>"
        let brandCover = "<figure class=\"rubien-cover-image\"><img src=\"https://cdn.example.com/z-icon.png\" alt=\"\"></figure>\n\(article)"
        let realCover = "<figure class=\"rubien-cover-image\"><img src=\"https://cdn.example.com/glm-hero.png\" alt=\"\"></figure>\n\(article)"
        let ordinaryLogo = "<figure><img src=\"https://cdn.example.com/z-icon.png\" alt=\"\"></figure>\n\(article)"

        XCTAssertEqual(
            ReaderExtractionManager.removingInjectedBrandCoverIfNeeded(from: brandCover),
            article
        )
        XCTAssertEqual(
            ReaderExtractionManager.removingInjectedBrandCoverIfNeeded(from: realCover),
            realCover
        )
        XCTAssertEqual(
            ReaderExtractionManager.removingInjectedBrandCoverIfNeeded(from: ordinaryLogo),
            ordinaryLogo
        )
    }
}
#endif
