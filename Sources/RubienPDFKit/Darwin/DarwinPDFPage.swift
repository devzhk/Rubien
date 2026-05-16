#if canImport(PDFKit)
import Foundation
import PDFKit
#if canImport(AppKit)
import AppKit
#endif

final class DarwinPDFPage: PDFPageProtocol, @unchecked Sendable {
    private let page: PDFPage

    init(page: PDFPage) {
        self.page = page
    }

    var label: String? { page.label }

    var mediaBox: PDFPageBox {
        let r = page.bounds(for: .mediaBox)
        return PDFPageBox(
            width: Double(r.width),
            height: Double(r.height),
            originX: Double(r.origin.x),
            originY: Double(r.origin.y)
        )
    }

    func extractedText() -> String? {
        page.string
    }

    func render(scale: Double, format: PDFRenderFormat, maxBytes: Int) throws -> PDFRenderResult {
        let pageBounds = page.bounds(for: .mediaBox)
        let widthPx = max(1, Int((pageBounds.width * CGFloat(scale)).rounded()))
        let heightPx = max(1, Int((pageBounds.height * CGFloat(scale)).rounded()))

        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = widthPx * 4
        guard let ctx = CGContext(
            data: nil,
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PDFRenderError.renderFailed }

        // Opaque white background so the alpha channel never carries content —
        // matches the Linux cairo path which uses CAIRO_FORMAT_RGB24 (no alpha).
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        page.draw(with: .mediaBox, to: ctx)

        guard let cgImage = ctx.makeImage() else { throw PDFRenderError.renderFailed }
        let rep = NSBitmapImageRep(cgImage: cgImage)

        switch format {
        case .jpeg:
            for q in [0.9, 0.75, 0.6, 0.45] {
                let props: [NSBitmapImageRep.PropertyKey: Any] = [
                    .compressionFactor: NSNumber(value: q)
                ]
                guard let data = rep.representation(using: .jpeg, properties: props) else {
                    throw PDFRenderError.renderFailed
                }
                if data.count <= maxBytes {
                    return PDFRenderResult(
                        data: data,
                        widthPx: widthPx,
                        heightPx: heightPx,
                        mimeType: "image/jpeg",
                        qualityUsed: q
                    )
                }
            }
            throw PDFRenderError.maxBytesExceeded(maxBytes)

        case .png:
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw PDFRenderError.renderFailed
            }
            if data.count > maxBytes { throw PDFRenderError.maxBytesExceeded(maxBytes) }
            return PDFRenderResult(
                data: data,
                widthPx: widthPx,
                heightPx: heightPx,
                mimeType: "image/png",
                qualityUsed: nil
            )
        }
    }
}
#endif
