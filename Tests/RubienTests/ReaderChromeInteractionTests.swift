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

    func testWebReaderNotesAndAssistantFitDefaultReaderWidth() {
        XCTAssertLessThanOrEqual(
            WebReaderMetrics.minimumReadableWidth(
                chatVisible: true,
                annotationSidebarVisible: true,
                chatPanelWidth: WebReaderMetrics.defaultChatPanelWidth
            ),
            ReaderWindowMetrics.defaultPreferredWidth
        )
    }

    func testWebReaderMinimumWindowWidthCoversDefaultNotesAndAssistantLayout() {
        XCTAssertGreaterThanOrEqual(
            WebReaderMetrics.minimumWindowWidth,
            WebReaderMetrics.minimumReadableWidth(
                chatVisible: true,
                annotationSidebarVisible: true,
                chatPanelWidth: WebReaderMetrics.defaultChatPanelWidth
            )
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

    func testReaderPreferredSizeUsesDesiredClampedToMinimumAndScreen() {
        let large = NSRect(x: 0, y: 0, width: 3000, height: 2000)
        let minSize = NSSize(width: 800, height: 600)

        // nil desired → the default preferred size on a roomy screen.
        XCTAssertEqual(
            ReaderWindowMetrics.preferredWindowSize(minSize: minSize, desired: nil, visibleFrame: large),
            NSSize(width: ReaderWindowMetrics.defaultPreferredWidth,
                   height: ReaderWindowMetrics.defaultPreferredHeight))

        // A remembered size within range is used verbatim.
        XCTAssertEqual(
            ReaderWindowMetrics.preferredWindowSize(
                minSize: minSize, desired: NSSize(width: 1400, height: 900), visibleFrame: large),
            NSSize(width: 1400, height: 900))

        // Smaller than the window minimum → clamped up to the minimum.
        XCTAssertEqual(
            ReaderWindowMetrics.preferredWindowSize(
                minSize: minSize, desired: NSSize(width: 500, height: 400), visibleFrame: large),
            minSize)

        // Larger than the screen → clamped to the visible frame minus the inset.
        let small = NSRect(x: 0, y: 0, width: 1100, height: 900)
        let clamped = ReaderWindowMetrics.preferredWindowSize(
            minSize: minSize, desired: NSSize(width: 5000, height: 5000), visibleFrame: small)
        XCTAssertEqual(clamped.width, small.width - ReaderWindowMetrics.visibleFrameInset)
        XCTAssertEqual(clamped.height, small.height - ReaderWindowMetrics.visibleFrameInset)

        // Screen cap below the minimum (tiny display) → the minimum still wins,
        // matching what AppKit enforces via window.minSize.
        let tiny = NSRect(x: 0, y: 0, width: 700, height: 500)
        XCTAssertEqual(
            ReaderWindowMetrics.preferredWindowSize(minSize: minSize, desired: nil, visibleFrame: tiny),
            minSize)
    }
}
#endif
