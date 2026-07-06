#if os(macOS)
import PDFKit
import XCTest
@testable import Rubien

final class PDFLinkPreviewResolverTests: XCTestCase {
    func testActionGoToLinkResolvesInternalTarget() throws {
        let document = try makeDocument(pageCount: 2)
        let sourcePage = try XCTUnwrap(document.page(at: 0))
        let targetPage = try XCTUnwrap(document.page(at: 1))
        let destination = PDFDestination(page: targetPage, at: CGPoint(x: 120, y: 640))
        let annotation = linkAnnotation(destination: destination)
        sourcePage.addAnnotation(annotation)

        let target = PDFLinkPreviewResolver.target(for: annotation, in: document)

        XCTAssertEqual(target?.sourcePageIndex, 0)
        XCTAssertEqual(target?.destinationPageIndex, 1)
        XCTAssertEqual(target?.sourceBounds, annotation.bounds)
        XCTAssertEqual(target?.destinationPoint.x ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(target?.destinationPoint.y ?? 0, 640, accuracy: 0.01)
    }

    func testAnnotationDestinationFallbackResolvesInternalTarget() throws {
        let document = try makeDocument(pageCount: 2)
        let sourcePage = try XCTUnwrap(document.page(at: 0))
        let targetPage = try XCTUnwrap(document.page(at: 1))
        let annotation = PDFAnnotation(bounds: CGRect(x: 80, y: 80, width: 120, height: 20), forType: .link, withProperties: nil)
        annotation.destination = PDFDestination(page: targetPage, at: CGPoint(x: 180, y: 500))
        sourcePage.addAnnotation(annotation)

        let target = PDFLinkPreviewResolver.target(for: annotation, in: document)

        XCTAssertEqual(target?.destinationPageIndex, 1)
        XCTAssertEqual(target?.destinationPoint.x ?? 0, 180, accuracy: 0.01)
        XCTAssertEqual(target?.destinationPoint.y ?? 0, 500, accuracy: 0.01)
    }

    func testURLOnlyLinkDoesNotPreview() throws {
        let document = try makeDocument(pageCount: 1)
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 80, y: 80, width: 120, height: 20), forType: .link, withProperties: nil)
        annotation.url = URL(string: "https://example.com")
        page.addAnnotation(annotation)

        XCTAssertNil(PDFLinkPreviewResolver.target(for: annotation, in: document))
    }

    func testURLActionWithFallbackDestinationDoesNotPreview() throws {
        let document = try makeDocument(pageCount: 2)
        let sourcePage = try XCTUnwrap(document.page(at: 0))
        let targetPage = try XCTUnwrap(document.page(at: 1))
        let annotation = PDFAnnotation(bounds: CGRect(x: 80, y: 80, width: 120, height: 20), forType: .link, withProperties: nil)
        annotation.destination = PDFDestination(page: targetPage, at: CGPoint(x: 180, y: 500))
        annotation.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com")))
        sourcePage.addAnnotation(annotation)

        XCTAssertNil(PDFLinkPreviewResolver.target(for: annotation, in: document))
    }

    func testNonLinkAnnotationDoesNotPreview() throws {
        let document = try makeDocument(pageCount: 2)
        let sourcePage = try XCTUnwrap(document.page(at: 0))
        let targetPage = try XCTUnwrap(document.page(at: 1))
        let annotation = PDFAnnotation(bounds: CGRect(x: 80, y: 80, width: 120, height: 20), forType: .highlight, withProperties: nil)
        annotation.action = PDFActionGoTo(destination: PDFDestination(page: targetPage, at: CGPoint(x: 120, y: 500)))
        sourcePage.addAnnotation(annotation)

        XCTAssertNil(PDFLinkPreviewResolver.target(for: annotation, in: document))
    }

    func testLinkSubtypeMatchingAcceptsPDFKitLinkAnnotations() throws {
        let document = try makeDocument(pageCount: 2)
        let sourcePage = try XCTUnwrap(document.page(at: 0))
        let targetPage = try XCTUnwrap(document.page(at: 1))
        let annotation = linkAnnotation(destination: PDFDestination(page: targetPage, at: CGPoint(x: 100, y: 400)))
        sourcePage.addAnnotation(annotation)

        XCTAssertTrue(PDFLinkPreviewResolver.isPreviewableLink(annotation))
        XCTAssertNotNil(PDFLinkPreviewResolver.target(for: annotation, in: document))
    }

    func testCropRectClampsToPageBounds() {
        let pageBounds = CGRect(x: 0, y: 0, width: 200, height: 120)
        let crop = PDFLinkPreviewResolver.cropRect(
            around: CGPoint(x: 195, y: 5),
            pageBounds: pageBounds,
            preferredSize: CGSize(width: 100, height: 80)
        )

        XCTAssertEqual(crop, CGRect(x: 100, y: 0, width: 100, height: 80))
    }

    func testUnspecifiedDestinationCoordinatesFallBackToTopOfPage() throws {
        let document = try makeDocument(pageCount: 2)
        let sourcePage = try XCTUnwrap(document.page(at: 0))
        let targetPage = try XCTUnwrap(document.page(at: 1))
        let destination = PDFDestination(
            page: targetPage,
            at: CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue)
        )
        let annotation = linkAnnotation(destination: destination)
        sourcePage.addAnnotation(annotation)

        let target = try XCTUnwrap(PDFLinkPreviewResolver.target(for: annotation, in: document))
        let bounds = targetPage.bounds(for: .mediaBox)

        XCTAssertEqual(target.destinationPoint.x, bounds.midX, accuracy: 0.01)
        XCTAssertEqual(target.destinationPoint.y, bounds.maxY, accuracy: 0.01)
        XCTAssertTrue(bounds.contains(target.cropRect))
    }

    func testTargetUsesRequestedDisplayBoxBounds() throws {
        let document = try makeDocument(pageCount: 2)
        let sourcePage = try XCTUnwrap(document.page(at: 0))
        let targetPage = try XCTUnwrap(document.page(at: 1))
        let cropBox = CGRect(x: 54, y: 72, width: 360, height: 500)
        targetPage.setBounds(cropBox, for: .cropBox)
        let destination = PDFDestination(
            page: targetPage,
            at: CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue)
        )
        let annotation = linkAnnotation(destination: destination)
        sourcePage.addAnnotation(annotation)

        let target = try XCTUnwrap(PDFLinkPreviewResolver.target(for: annotation, in: document, displayBox: .cropBox))

        XCTAssertEqual(target.destinationPoint.x, cropBox.midX, accuracy: 0.01)
        XCTAssertEqual(target.destinationPoint.y, cropBox.maxY, accuracy: 0.01)
        XCTAssertTrue(cropBox.contains(target.cropRect))
        XCTAssertLessThanOrEqual(target.cropRect.width, cropBox.width)
        XCTAssertLessThanOrEqual(target.cropRect.height, cropBox.height)
    }

    func testRotatedPageTargetUsesRequestedDisplayBoxBounds() throws {
        let document = try makeDocument(pageCount: 2)
        let sourcePage = try XCTUnwrap(document.page(at: 0))
        let targetPage = try XCTUnwrap(document.page(at: 1))
        let cropBox = CGRect(x: 40, y: 60, width: 320, height: 460)
        targetPage.rotation = 90
        targetPage.setBounds(cropBox, for: .cropBox)
        let destination = PDFDestination(page: targetPage, at: CGPoint(x: 90, y: 420))
        let annotation = linkAnnotation(destination: destination)
        sourcePage.addAnnotation(annotation)

        let target = try XCTUnwrap(PDFLinkPreviewResolver.target(for: annotation, in: document, displayBox: .cropBox))

        XCTAssertEqual(target.displayBox, .cropBox)
        XCTAssertTrue(cropBox.contains(target.cropRect))
    }

    func testDefaultCropCoversTypicalFullPageWidthForWideLinkedContent() throws {
        let document = try makeDocument(pageCount: 2)
        let sourcePage = try XCTUnwrap(document.page(at: 0))
        let targetPage = try XCTUnwrap(document.page(at: 1))
        let destination = PDFDestination(page: targetPage, at: CGPoint(x: 72, y: 520))
        let annotation = linkAnnotation(destination: destination)
        sourcePage.addAnnotation(annotation)

        let target = try XCTUnwrap(PDFLinkPreviewResolver.target(for: annotation, in: document))
        let bounds = targetPage.bounds(for: .mediaBox)

        XCTAssertEqual(target.cropRect.minX, bounds.minX, accuracy: 0.01)
        XCTAssertEqual(target.cropRect.maxX, bounds.maxX, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(target.cropRect.height, 340)
    }

    func testRenderPreviewUsesBackingScaleForBitmapPixels() throws {
        let document = try makeDocument(pageCount: 1)
        let page = try XCTUnwrap(document.page(at: 0))
        let image = try XCTUnwrap(PDFLinkPreviewResolver.renderPreview(
            page: page,
            cropRect: CGRect(x: 0, y: 0, width: 120, height: 80),
            backingScale: 2
        ))
        let representation = try XCTUnwrap(image.representations.first)

        XCTAssertEqual(image.size, CGSize(width: 120, height: 80))
        XCTAssertEqual(representation.pixelsWide, 240)
        XCTAssertEqual(representation.pixelsHigh, 160)
    }

    private func makeDocument(pageCount: Int) throws -> PDFDocument {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: CGSize(width: 612, height: 792))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 612, height: 792).fill()
            let text = "Page \(index + 1)" as NSString
            text.draw(
                at: CGPoint(x: 72, y: 720),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 18),
                    .foregroundColor: NSColor.black
                ]
            )
            image.unlockFocus()
            let page = try XCTUnwrap(PDFPage(image: image))
            document.insert(page, at: index)
        }
        return document
    }

    private func linkAnnotation(destination: PDFDestination) -> PDFAnnotation {
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 80, y: 80, width: 120, height: 20),
            forType: .link,
            withProperties: nil
        )
        annotation.action = PDFActionGoTo(destination: destination)
        return annotation
    }
}
#endif
