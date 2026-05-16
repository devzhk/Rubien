#if os(Linux)
import Foundation
import CPoppler
import CGdkPixbuf

final class LinuxPDFPage: PDFPageProtocol, @unchecked Sendable {
    private let pageBox: GObjectBox

    init(takingOwnershipOf pagePtr: OpaquePointer) {
        self.pageBox = GObjectBox(takingOwnershipOf: pagePtr)
    }

    var label: String? {
        pageBox.withPointer { takeOwnedString(poppler_page_get_label($0)) }
    }

    var mediaBox: PDFPageBox {
        pageBox.withPointer { ptr in
            var w: Double = 0
            var h: Double = 0
            poppler_page_get_size(ptr, &w, &h)
            return PDFPageBox(width: w, height: h)
        }
    }

    func extractedText() -> String? {
        // collapseEmpty: false — empty text on a no-text-layer page is
        // significant for `hasTextLayer` sampling.
        pageBox.withPointer {
            takeOwnedString(poppler_page_get_text($0), collapseEmpty: false)
        }
    }

    func render(scale: Double, format: PDFRenderFormat, maxBytes: Int) throws -> PDFRenderResult {
        // Pinned rendering semantics (must match Darwin's
        // `DarwinPDFPage.render` — `Docs/Linux-PDF-Backend.md` §3 has the
        // full table):
        //   media box · max(1, round(box × scale)) · CAIRO_FORMAT_RGB24
        //   opaque white background · JPEG ladder [0.9, 0.75, 0.6, 0.45]
        //   mime "image/jpeg" / "image/png"
        let (surface, widthPx, heightPx) = try pageBox.withPointer { ptr throws -> (OpaquePointer, Int, Int) in
            var w: Double = 0
            var h: Double = 0
            poppler_page_get_size(ptr, &w, &h)
            let wPx = max(1, Int((w * scale).rounded()))
            let hPx = max(1, Int((h * scale).rounded()))
            guard let surface = cairo_image_surface_create(CAIRO_FORMAT_RGB24, Int32(wPx), Int32(hPx)) else {
                throw PDFRenderError.renderFailed
            }
            guard let cr = cairo_create(surface) else {
                cairo_surface_destroy(surface)
                throw PDFRenderError.renderFailed
            }
            defer { cairo_destroy(cr) }
            cairo_set_source_rgb(cr, 1, 1, 1)
            cairo_paint(cr)
            cairo_scale(cr, scale, scale)
            poppler_page_render(ptr, cr)
            cairo_surface_flush(surface)
            return (surface, wPx, hPx)
        }
        defer { cairo_surface_destroy(surface) }

        switch format {
        case .jpeg:
            for q in PixbufEncoder.jpegQualityLadder {
                let data = try PixbufEncoder.encode(surface: surface, widthPx: widthPx, heightPx: heightPx, format: .jpeg, quality: q)
                if data.count <= maxBytes {
                    return PDFRenderResult(data: data, widthPx: widthPx, heightPx: heightPx, mimeType: "image/jpeg", qualityUsed: q)
                }
            }
            throw PDFRenderError.maxBytesExceeded(maxBytes)

        case .png:
            let data = try PixbufEncoder.encode(surface: surface, widthPx: widthPx, heightPx: heightPx, format: .png, quality: nil)
            if data.count > maxBytes { throw PDFRenderError.maxBytesExceeded(maxBytes) }
            return PDFRenderResult(data: data, widthPx: widthPx, heightPx: heightPx, mimeType: "image/png", qualityUsed: nil)
        }
    }
}

/// Convert a CAIRO_FORMAT_RGB24 cairo surface to a `GdkPixbuf` and encode it
/// to JPEG/PNG bytes via `gdk_pixbuf_save_to_bufferv`. `gdk_pixbuf_get_from_surface`
/// was moved into GTK proper in gdk-pixbuf 2.42+ and is no longer in the
/// standalone distribution — we hand-roll the BGRX→RGB rearrange instead.
private enum PixbufEncoder {
    static let jpegQualityLadder: [Double] = [0.9, 0.75, 0.6, 0.45]

    static func encode(surface: OpaquePointer, widthPx: Int, heightPx: Int, format: PDFRenderFormat, quality: Double?) throws -> Data {
        let srcStride = Int(cairo_image_surface_get_stride(surface))
        guard let srcData = cairo_image_surface_get_data(surface) else {
            throw PDFRenderError.renderFailed
        }

        let dstStride = widthPx * 3
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: dstStride * heightPx)
        // We own dstBuf; gdk_pixbuf_new_from_data with nil destroy callback
        // means the pixbuf borrows for the encode call only. Free after the
        // pixbuf is unref'd. (Swift-closure-based destroy callbacks cause
        // corelibs-xctest hangs — see Docs/Linux-PDF-Backend.md.)
        defer { dstBuf.deallocate() }

        for y in 0..<heightPx {
            let srcRow = srcData.advanced(by: y * srcStride)
            let dstRow = dstBuf.advanced(by: y * dstStride)
            for x in 0..<widthPx {
                let srcPx = srcRow.advanced(by: x * 4)
                dstRow[x * 3 + 0] = srcPx[2]  // R (cairo BGRX byte 2 on little-endian)
                dstRow[x * 3 + 1] = srcPx[1]  // G
                dstRow[x * 3 + 2] = srcPx[0]  // B
            }
        }

        guard let pixbuf = gdk_pixbuf_new_from_data(
            dstBuf,
            GDK_COLORSPACE_RGB,
            0,
            8,
            Int32(widthPx),
            Int32(heightPx),
            Int32(dstStride),
            nil,
            nil
        ) else {
            throw PDFRenderError.renderFailed
        }
        defer { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }

        return try saveToBuffer(pixbuf: pixbuf, format: format, quality: quality)
    }

    private static func saveToBuffer(pixbuf: OpaquePointer, format: PDFRenderFormat, quality: Double?) throws -> Data {
        var buffer: UnsafeMutablePointer<gchar>? = nil
        var size: gsize = 0
        var gerror: UnsafeMutablePointer<GError>? = nil
        let type = format.rawValue  // "jpeg" / "png" — matches gdk-pixbuf type strings

        let ok: gboolean = type.withCString { typeCStr in
            if let q = quality {
                let qStr = String(Int(q * 100))
                return "quality".withCString { keyCStr in
                    qStr.withCString { valueCStr in
                        var keys: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: keyCStr), nil]
                        var values: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: valueCStr), nil]
                        return keys.withUnsafeMutableBufferPointer { kBuf in
                            values.withUnsafeMutableBufferPointer { vBuf in
                                gdk_pixbuf_save_to_bufferv(pixbuf, &buffer, &size, typeCStr, kBuf.baseAddress, vBuf.baseAddress, &gerror)
                            }
                        }
                    }
                }
            }
            return gdk_pixbuf_save_to_bufferv(pixbuf, &buffer, &size, typeCStr, nil, nil, &gerror)
        }

        if ok == 0 {
            if let err = gerror { _ = GErrorWrapper(takingOwnershipOf: err) }
            throw PDFRenderError.renderFailed
        }
        guard let buf = buffer, size > 0 else {
            throw PDFRenderError.renderFailed
        }
        // Copy into Swift-owned Data, free gdk buffer immediately.
        let copy = Data(UnsafeRawBufferPointer(start: buf, count: Int(size)))
        g_free(UnsafeMutableRawPointer(buf))
        return copy
    }
}
#endif
