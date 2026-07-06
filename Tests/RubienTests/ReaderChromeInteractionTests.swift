#if os(macOS)
import XCTest
@testable import Rubien

final class ReaderChromeInteractionTests: XCTestCase {
    func testReaderResizeHitTargetsShareOneComfortableWidthWithoutVisualHandle() {
        XCTAssertGreaterThanOrEqual(ReaderResizeMetrics.hitTargetWidth, 18)
        XCTAssertFalse(ReaderResizeMetrics.showsVisualHandle)
        XCTAssertTrue(ReaderResizeMetrics.usesExplicitResizeCursor)
        XCTAssertTrue(ReaderResizeMetrics.usesNativeResizeCursorTracking)
        XCTAssertEqual(FloatingPanelMetrics.resizeHitTargetWidth, ReaderResizeMetrics.hitTargetWidth)
        XCTAssertEqual(PDFReaderMetrics.sidebarResizeHitTargetWidth, ReaderResizeMetrics.hitTargetWidth)
    }

    func testFloatingPanelWidthClampsLeadingEdgeDragToRange() {
        XCTAssertEqual(
            FloatingPanelMetrics.width(afterLeadingEdgeTranslation: -500, from: 320, in: 300...640),
            640
        )
        XCTAssertEqual(
            FloatingPanelMetrics.width(afterLeadingEdgeTranslation: 500, from: 320, in: 300...640),
            300
        )
        XCTAssertEqual(
            FloatingPanelMetrics.width(afterLeadingEdgeTranslation: -80, from: 320, in: 300...640),
            400
        )
    }

    func testPDFSidebarWidthClampsTrailingEdgeDragToRange() {
        XCTAssertEqual(
            PDFReaderMetrics.sidebarWidth(afterTrailingEdgeTranslation: -500, from: 240, in: 200...400),
            200
        )
        XCTAssertEqual(
            PDFReaderMetrics.sidebarWidth(afterTrailingEdgeTranslation: 500, from: 240, in: 200...400),
            400
        )
        XCTAssertEqual(
            PDFReaderMetrics.sidebarWidth(afterTrailingEdgeTranslation: 60, from: 240, in: 200...400),
            300
        )
    }

    func testSegmentedControlHoverDoesNotOverrideActiveSegmentHighlight() {
        XCTAssertEqual(
            ReaderSegmentedControlMetrics.highlightOpacity(isActive: true, isHovered: true),
            ReaderSegmentedControlMetrics.activeHighlightOpacity
        )
        XCTAssertEqual(
            ReaderSegmentedControlMetrics.highlightOpacity(isActive: false, isHovered: true),
            ReaderSegmentedControlMetrics.hoverHighlightOpacity
        )
        XCTAssertEqual(
            ReaderSegmentedControlMetrics.highlightOpacity(isActive: false, isHovered: false),
            0
        )
    }
}
#endif
