#if os(macOS)
import PDFKit
import SwiftUI

struct PDFLinkPreviewTarget: Equatable {
    let sourcePageIndex: Int
    let destinationPageIndex: Int
    let sourceBounds: CGRect
    let destinationPoint: CGPoint
    let cropRect: CGRect
    let displayBox: PDFDisplayBox

    var cacheKey: String {
        [
            sourcePageIndex.description,
            destinationPageIndex.description,
            sourceBounds.integral.debugDescription,
            String(format: "%.1f,%.1f", destinationPoint.x, destinationPoint.y),
            cropRect.integral.debugDescription,
            String(describing: displayBox)
        ].joined(separator: "|")
    }

    var pageLabel: String {
        "Page \(destinationPageIndex + 1)"
    }
}

enum PDFLinkPreviewResolver {
    static let defaultCropSize = CGSize(width: 640, height: 360)

    static func isPreviewableLink(_ annotation: PDFAnnotation) -> Bool {
        normalizedAnnotationType(annotation.type) == "Link"
    }

    static func target(
        for annotation: PDFAnnotation,
        in document: PDFDocument,
        displayBox: PDFDisplayBox = .cropBox,
        preferredCropSize: CGSize = defaultCropSize
    ) -> PDFLinkPreviewTarget? {
        guard isPreviewableLink(annotation) else { return nil }
        guard annotation.url == nil else { return nil }

        let destination: PDFDestination?
        if let action = annotation.action {
            guard let goToAction = action as? PDFActionGoTo else {
                return nil
            }
            destination = goToAction.destination
        } else {
            destination = annotation.destination
        }

        guard let destination,
              let destinationPage = destination.page else { return nil }

        let destinationPageIndex = document.index(for: destinationPage)
        guard destinationPageIndex >= 0, destinationPageIndex < document.pageCount else { return nil }

        guard let sourcePage = annotation.page else { return nil }
        let sourcePageIndex = document.index(for: sourcePage)
        guard sourcePageIndex >= 0, sourcePageIndex < document.pageCount else { return nil }

        let pageBounds = destinationPage.bounds(for: displayBox).standardized
        guard !pageBounds.isNull, !pageBounds.isEmpty else { return nil }

        let destinationPoint = normalizedDestinationPoint(destination.point, pageBounds: pageBounds)
        return PDFLinkPreviewTarget(
            sourcePageIndex: sourcePageIndex,
            destinationPageIndex: destinationPageIndex,
            sourceBounds: annotation.bounds.standardized,
            destinationPoint: destinationPoint,
            cropRect: cropRect(
                around: destinationPoint,
                pageBounds: pageBounds,
                preferredSize: preferredCropSize
            ),
            displayBox: displayBox
        )
    }

    static func cropRect(around point: CGPoint, pageBounds: CGRect, preferredSize: CGSize) -> CGRect {
        let bounds = pageBounds.standardized
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let width = min(max(preferredSize.width, 1), bounds.width)
        let height = min(max(preferredSize.height, 1), bounds.height)
        let originX = clamped(point.x - width / 2, min: bounds.minX, max: bounds.maxX - width)

        // Keep the destination near the upper third of the preview so the
        // surrounding paragraph or figure caption remains visible below it.
        let originY = clamped(point.y - height * 0.72, min: bounds.minY, max: bounds.maxY - height)

        return CGRect(x: originX, y: originY, width: width, height: height).integral
    }

    static func renderPreview(
        page: PDFPage,
        cropRect: CGRect,
        backingScale: CGFloat,
        displayBox: PDFDisplayBox = .cropBox
    ) -> NSImage? {
        let crop = cropRect.standardized
        guard crop.width > 0, crop.height > 0 else { return nil }

        let scale = max(backingScale, 1)
        let pixelsWide = max(1, Int((crop.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((crop.height * scale).rounded(.up)))

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 32
        ),
            let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
            return nil
        }

        representation.size = crop.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        let context = graphicsContext.cgContext
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        NSColor.textBackgroundColor.setFill()
        CGRect(origin: .zero, size: crop.size).fill()
        context.translateBy(x: -crop.minX, y: -crop.minY)
        page.draw(with: displayBox, to: context)
        context.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: crop.size)
        image.addRepresentation(representation)
        return image
    }

    private static func normalizedAnnotationType(_ type: String?) -> String? {
        type?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedDestinationPoint(_ point: CGPoint, pageBounds: CGRect) -> CGPoint {
        CGPoint(
            x: normalizedDestinationCoordinate(point.x, fallback: pageBounds.midX),
            y: normalizedDestinationCoordinate(point.y, fallback: pageBounds.maxY)
        )
    }

    private static func normalizedDestinationCoordinate(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite, value != kPDFDestinationUnspecifiedValue else {
            return fallback
        }
        return value
    }

    private static func clamped(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

final class PDFLinkPreviewPopoverController {
    private var popover: NSPopover?
    private var representedKey: String?

    func show(image: NSImage, target: PDFLinkPreviewTarget, relativeTo sourceRect: CGRect, of view: NSView) {
        guard !sourceRect.isNull, !sourceRect.isEmpty else { return }

        if representedKey == target.cacheKey, popover?.isShown == true {
            return
        }

        close()

        let content = PDFLinkPreviewContent(image: image, pageLabel: target.pageLabel)
        let hostingController = NSHostingController(rootView: content)
        hostingController.view.frame = CGRect(origin: .zero, size: content.preferredSize)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = content.preferredSize
        popover.contentViewController = hostingController
        popover.show(relativeTo: sourceRect, of: view, preferredEdge: .maxY)

        self.popover = popover
        representedKey = target.cacheKey
    }

    func close() {
        representedKey = nil
        popover?.close()
        popover = nil
    }
}

private struct PDFLinkPreviewContent: View {
    let image: NSImage
    let pageLabel: String

    var preferredSize: CGSize {
        CGSize(width: max(image.size.width, 180), height: image.size.height + 24)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: image.size.width, height: image.size.height)
                .background(Color(nsColor: .textBackgroundColor))

            Text(pageLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(.regularMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
#endif
