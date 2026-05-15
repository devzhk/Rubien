#if os(Linux)
import CPoppler

/// RAII wrapper around a GObject reference. The closure-based borrow API
/// prevents callers from storing the raw pointer past the wrapper's lifetime
/// without re-`ref`'ing — see `GObjectBox.withPointer` below.
///
/// Stores `OpaquePointer` rather than a typed pointer because poppler-glib's
/// public types (`PopplerDocument`, `PopplerPage`, …) are opaque struct
/// typedefs in C and Swift's C importer surfaces them as `OpaquePointer`.
/// A typed `UnsafeMutablePointer<T>` wrapper would force a cast at every
/// poppler call site, which is the opposite of the readability win.
final class GObjectBox: @unchecked Sendable {
    private let pointer: OpaquePointer

    /// Takes ownership of an already-`ref`'d pointer. Most poppler factories
    /// (`poppler_document_new_from_file`, `poppler_document_get_page`) return
    /// a `+1` ref, so the caller does NOT pre-`g_object_ref`.
    init(takingOwnershipOf pointer: OpaquePointer) {
        self.pointer = pointer
    }

    /// Borrow the pointer for the closure's lifetime only. Do NOT store the
    /// raw pointer, pass it to another thread without re-`ref`'ing, or let it
    /// escape this call — `deinit` may run as soon as the closure returns.
    /// Synchronous C callbacks (poppler iter callbacks, `poppler_page_render`)
    /// are safe escapes because the C function returns before `withPointer`'s
    /// scope ends.
    func withPointer<R>(_ body: (OpaquePointer) throws -> R) rethrows -> R {
        try body(pointer)
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(pointer))
    }
}
#endif
