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
        pageBox.withPointer { ptr in
            guard let cstr = poppler_page_get_label(ptr) else { return nil }
            let s = String(cString: cstr)
            g_free(UnsafeMutableRawPointer(cstr))
            return s.isEmpty ? nil : s
        }
    }

    var mediaBox: PDFPageBox {
        pageBox.withPointer { ptr in
            var w: Double = 0
            var h: Double = 0
            poppler_page_get_size(ptr, &w, &h)
            return PDFPageBox(width: w, height: h, originX: 0, originY: 0)
        }
    }

    func extractedText() -> String? {
        pageBox.withPointer { ptr in
            guard let cstr = poppler_page_get_text(ptr) else { return nil }
            let s = String(cString: cstr)
            g_free(UnsafeMutableRawPointer(cstr))
            return s
        }
    }

    func render(scale: Double, format: PDFRenderFormat, maxBytes: Int) throws -> PDFRenderResult {
        // Rendering semantics (pinned by Phase 3 §3.3):
        //   - media box, scale-to-pixels: max(1, round(box × scale))
        //   - CAIRO_FORMAT_RGB24 (no alpha; opaque white background)
        //   - JPEG quality ladder [0.9, 0.75, 0.6, 0.45], first under maxBytes wins
        //   - PNG: single shot, throw maxBytesExceeded if over
        //   - mime type strings match Darwin: "image/jpeg" / "image/png"
        let (wPts, hPts) = pageBox.withPointer { ptr -> (Double, Double) in
            var w: Double = 0
            var h: Double = 0
            poppler_page_get_size(ptr, &w, &h)
            return (w, h)
        }
        let widthPx = max(1, Int((wPts * scale).rounded()))
        let heightPx = max(1, Int((hPts * scale).rounded()))

        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_RGB24, Int32(widthPx), Int32(heightPx)) else {
            throw PDFRenderError.renderFailed
        }
        defer { cairo_surface_destroy(surface) }

        guard let cr = cairo_create(surface) else {
            throw PDFRenderError.renderFailed
        }

        cairo_set_source_rgb(cr, 1, 1, 1)
        cairo_paint(cr)
        cairo_scale(cr, scale, scale)

        pageBox.withPointer { ptr in
            poppler_page_render(ptr, cr)
        }
        cairo_destroy(cr)
        cairo_surface_flush(surface)

        switch format {
        case .jpeg:
            for q in [0.9, 0.75, 0.6, 0.45] {
                let qInt = Int(q * 100)
                let data = try encodeCairoSurface(surface, widthPx: widthPx, heightPx: heightPx, type: "jpeg", optionKey: "quality", optionValue: String(qInt))
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
            let data = try encodeCairoSurface(surface, widthPx: widthPx, heightPx: heightPx, type: "png", optionKey: nil, optionValue: nil)
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

    /// Convert a CAIRO_FORMAT_RGB24 image surface to a GdkPixbuf and encode
    /// to JPEG/PNG bytes via gdk-pixbuf's save_to_bufferv.
    ///
    /// Why not `gdk_pixbuf_get_from_surface`? It was moved into GTK proper
    /// in gdk-pixbuf 2.42 and is no longer in the standalone gdk-pixbuf
    /// distribution. We replicate the conversion ourselves: cairo RGB24
    /// stores pixels as 32-bit `BGRX` (little-endian) per pixel, and gdk
    /// wants 24-bit `RGB` packed. Per-pixel byte rearrange.
    private func encodeCairoSurface(
        _ surface: OpaquePointer,
        widthPx: Int,
        heightPx: Int,
        type: String,
        optionKey: String?,
        optionValue: String?
    ) throws -> Data {
        let srcStride = Int(cairo_image_surface_get_stride(surface))
        guard let srcData = cairo_image_surface_get_data(surface) else {
            throw PDFRenderError.renderFailed
        }

        let dstStride = widthPx * 3
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: dstStride * heightPx)

        for y in 0..<heightPx {
            let srcRow = srcData.advanced(by: y * srcStride)
            let dstRow = dstBuf.advanced(by: y * dstStride)
            for x in 0..<widthPx {
                let srcPx = srcRow.advanced(by: x * 4)
                dstRow[x * 3 + 0] = srcPx[2]  // R (cairo BGRX byte 2)
                dstRow[x * 3 + 1] = srcPx[1]  // G (cairo BGRX byte 1)
                dstRow[x * 3 + 2] = srcPx[0]  // B (cairo BGRX byte 0)
            }
        }

        // No destroy callback — we manage `dstBuf` lifetime ourselves. Passing
        // a Swift closure as GdkPixbufDestroyNotify caused inter-test hangs on
        // Linux corelibs-xctest (reproduced via `RepeatRenderProbe`): the
        // closure's bridged C function pointer apparently holds a Swift
        // runtime resource that doesn't release cleanly across test method
        // boundaries.
        //
        // `gdk_pixbuf_save_to_bufferv` reads from the pixbuf synchronously
        // and returns before any caller-visible release, so `dstBuf` is safe
        // to deallocate after both `save_to_bufferv` and `g_object_unref`
        // have returned.
        defer { dstBuf.deallocate() }

        guard let pixbufRaw = gdk_pixbuf_new_from_data(
            dstBuf,
            GDK_COLORSPACE_RGB,
            0,
            8,
            Int32(widthPx),
            Int32(heightPx),
            Int32(dstStride),
            nil,   // destroy_fn: NULL → we own dstBuf
            nil    // destroy_fn_data
        ) else {
            throw PDFRenderError.renderFailed
        }
        let pixbuf = pixbufRaw
        defer { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }

        return try saveBufferv(pixbuf: pixbuf, type: type, optionKey: optionKey, optionValue: optionValue)
    }

    private func saveBufferv(
        pixbuf: OpaquePointer,
        type: String,
        optionKey: String?,
        optionValue: String?
    ) throws -> Data {
        var buffer: UnsafeMutablePointer<gchar>? = nil
        var size: gsize = 0
        var gerror: UnsafeMutablePointer<GError>? = nil

        let ok: gboolean
        if let key = optionKey, let value = optionValue {
            ok = key.withCString { keyCStr in
                value.withCString { valueCStr in
                    type.withCString { typeCStr in
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
        } else {
            ok = type.withCString { typeCStr in
                gdk_pixbuf_save_to_bufferv(pixbuf, &buffer, &size, typeCStr, nil, nil, &gerror)
            }
        }

        if ok == 0 {
            if let err = gerror { _ = GErrorWrapper(takingOwnershipOf: err) }
            throw PDFRenderError.renderFailed
        }
        guard let buf = buffer, size > 0 else {
            throw PDFRenderError.renderFailed
        }

        // Copy the gdk-pixbuf buffer into a Swift-owned `Data`, then free
        // the gdk-pixbuf buffer immediately. The closure-based custom
        // `.deallocator` is intentionally avoided — its captured-closure
        // lifecycle across XCTest method boundaries on Linux corelibs-xctest
        // hangs the next test method (reproduced via `RepeatRenderProbe`).
        // The extra memcpy is bounded by the JPEG/PNG output size (~100-500
        // KB for typical pages) and negligible vs. the encode itself.
        let copy = Data(UnsafeRawBufferPointer(start: buf, count: Int(size)))
        g_free(UnsafeMutableRawPointer(buf))
        return copy
    }
}
#endif
