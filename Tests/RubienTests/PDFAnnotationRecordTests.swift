#if os(macOS)
import CoreGraphics
import Foundation
import GRDB
import PDFKit
import XCTest
@testable import Rubien
@testable import RubienCore

final class PDFAnnotationRecordTests: XCTestCase {
    @MainActor
    func testNoteIndicatorsMoveDuringContinuousScrolling() async throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pdfView = CommitAwarePDFView(frame: window.contentView!.bounds)
        window.contentView = pdfView
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        let image = NSImage(size: NSSize(width: 600, height: 2000), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: image))
        let document = PDFDocument()
        document.insert(page, at: 0)
        pdfView.document = document
        pdfView.scaleFactor = 1
        pdfView.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(pdfView.internalScrollView)
        let visiblePageBounds = pdfView.convert(pdfView.bounds, to: page)
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))
        let model = PDFReaderViewModel(reference: Reference(title: "Scroll test"),
                                       pdfURL: URL(fileURLWithPath: "/unused-scroll-test.pdf"), db: database)
        model.annotations = [ReaderPDFAnnotation(PDFAnnotationRecord(
            id: 1, referenceId: 1, type: .note, noteText: "A note", pageIndex: 0,
            rects: [CGRect(x: visiblePageBounds.midX, y: visiblePageBounds.midY, width: 80, height: 20)]
        ))]
        let coordinator = AnnotatablePDFView.Coordinator(viewModel: model)
        coordinator.pdfView = pdfView
        coordinator.ensureObservers(for: pdfView)
        defer { coordinator.teardownObservers() }
        coordinator.updateNoteIndicators()
        let button = try XCTUnwrap(pdfView.subviews.compactMap { $0 as? PDFNoteIndicatorButton }.first)
        let initialFrame = button.frame
        let initialScrollOrigin = scroll.contentView.bounds.origin
        var movedDuringScrolling = false

        // Each event arrives before the old trailing 16 ms debounce would fire.
        for step in 1...12 {
            scroll.contentView.scroll(to: CGPoint(x: initialScrollOrigin.x,
                                                  y: initialScrollOrigin.y + CGFloat(step * 3)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(nanoseconds: 8_000_000)
            movedDuringScrolling = movedDuringScrolling || button.frame != initialFrame
        }
        XCTAssertTrue(movedDuringScrolling, "Badges must follow the page before scrolling stops")
    }

    func testNoteIndicatorAppearsOnlyForNonemptyNotes() {
        var record = ReaderPDFAnnotation(PDFAnnotationRecord(
            referenceId: 1,
            type: .highlight,
            pageIndex: 0,
            rects: [CGRect(x: 10, y: 20, width: 100, height: 15)]
        ))
        for note in [nil, "", " \n\t", "Hard to parse."] as [String?] {
            record.noteText = note
            let anchor = AnnotatablePDFView.noteIndicatorAnchor(for: record)
            if note == "Hard to parse." {
                XCTAssertEqual(anchor, record.rects.first)
            } else {
                XCTAssertNil(anchor)
            }
        }
    }

    func testNoteIndicatorAnchorsToFirstLineAndStaysInsidePageEdges() throws {
        let record = ReaderPDFAnnotation(PDFAnnotationRecord(
            referenceId: 1,
            type: .note,
            noteText: "A note",
            pageIndex: 0,
            rects: [
                CGRect(x: 100, y: 780, width: 500, height: 20),
                CGRect(x: 100, y: 750, width: 50, height: 20),
            ]
        ))
        let pageBounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let anchor = try XCTUnwrap(AnnotatablePDFView.noteIndicatorAnchor(for: record))
        XCTAssertEqual(anchor, record.rects.first)
        let frame = try XCTUnwrap(AnnotatablePDFView.noteIndicatorFrame(anchor: anchor, pageBounds: pageBounds))
        XCTAssertEqual(frame, CGRect(x: 574, y: 774, width: 24, height: 24))
        XCTAssertTrue(pageBounds.contains(frame))
    }

    func testNoteIndicatorSizeRemainsConstantAcrossZoomFactors() throws {
        for zoom: CGFloat in [0.5, 1, 1.75, 4] {
            let frame = try XCTUnwrap(AnnotatablePDFView.noteIndicatorFrame(
                anchor: CGRect(x: 10 * zoom, y: 20 * zoom, width: 100 * zoom, height: 15 * zoom),
                pageBounds: CGRect(x: 0, y: 0, width: 600 * zoom, height: 800 * zoom)
            ))
            XCTAssertEqual(frame.size, CGSize(width: 24, height: 24))
            XCTAssertEqual(frame.minX, frame.minX.rounded())
            XCTAssertEqual(frame.minY, frame.minY.rounded())
        }
    }

    @MainActor
    func testPDFViewMouseMovementPreservesNoteButtonCursor() throws {
        let pdfView = CommitAwarePDFView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let button = PDFNoteIndicatorButton {}
        button.frame = CGRect(x: 20, y: 20, width: 24, height: 24)
        pdfView.addSubview(button)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: CGPoint(x: 30, y: 30), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        let previousCursor = NSCursor.current
        defer { previousCursor.set() }

        NSCursor.arrow.set()
        pdfView.cursorUpdate(with: event)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
        NSCursor.arrow.set()
        pdfView.mouseMoved(with: event)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
    }

    @MainActor
    func testNoteIndicatorUsesNativeSymbolButtonAndOpensNote() throws {
        var opened = false
        let button = PDFNoteIndicatorButton { opened = true }
        XCTAssertNotNil(button.image?.symbolConfiguration)
        XCTAssertEqual(button.accessibilityLabel(), "Open note")
        XCTAssertEqual(button.toolTip, "Open note")
        button.performClick(nil)
        XCTAssertTrue(opened)
    }

    func testReaderMarkupKeepsNotesInRubienInsteadOfNativePDFKitPopups() {
        for type: AnnotationType in [.highlight, .underline, .note] {
            let record = ReaderPDFAnnotation(PDFAnnotationRecord(
                id: 10,
                referenceId: 1,
                type: type,
                noteText: "**Hard** to parse.",
                pageIndex: 0,
                rects: [CGRect(x: 10, y: 20, width: 100, height: 15)]
            ))
            let markup = AnnotatablePDFView.createPDFAnnotation(from: record)

            XCTAssertNil(markup.contents)
            XCTAssertNil(markup.popup)
            XCTAssertEqual(markup.bounds, record.unionBounds)
            XCTAssertEqual(markup.quadrilateralPoints?.count, 4)
            XCTAssertEqual(record.noteText, "**Hard** to parse.")
        }
    }

    func testInitializerNormalizesRectsAndComputesUnionBounds() {
        let record = PDFAnnotationRecord(
            referenceId: 1,
            type: .highlight,
            pageIndex: 0,
            rects: [
                CGRect(x: 10, y: 20, width: 30, height: 40),
                CGRect(x: 25, y: 15, width: 10, height: 10),
                CGRect(x: 0, y: 0, width: 0, height: 0),
            ]
        )

        XCTAssertEqual(record.rects.count, 2)
        XCTAssertEqual(record.unionBounds, CGRect(x: 10, y: 15, width: 30, height: 45))
        XCTAssertEqual(record.boundsX, 10)
        XCTAssertEqual(record.boundsY, 15)
        XCTAssertEqual(record.boundsWidth, 30)
        XCTAssertEqual(record.boundsHeight, 45)
    }

    func testRectsFallBackToUnionBoundsWhenStoredJSONIsInvalid() {
        var record = PDFAnnotationRecord(
            referenceId: 1,
            type: .note,
            pageIndex: 1,
            rects: [CGRect(x: 5, y: 6, width: 7, height: 8)]
        )
        record.rectsData = "not json"

        XCTAssertEqual(record.rects, [record.unionBounds])
    }

    func testRenderHashChangesWhenVisibleStateChanges() {
        let base = PDFAnnotationRecord(
            id: 10,
            referenceId: 1,
            type: .highlight,
            noteText: "A",
            pageIndex: 1,
            rects: [CGRect(x: 1, y: 2, width: 3, height: 4)]
        )
        var changed = base
        changed.noteText = "B"

        XCTAssertNotEqual(base.renderHash, changed.renderHash)
    }
}
#endif
