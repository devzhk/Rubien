#if os(Linux)
import CPoppler

/// RAII wrapper around a GObject reference. Closure-scoped borrow prevents
/// the pointer from outliving the wrapper without an explicit re-ref.
/// See `Docs/Linux-PDF-Backend.md` for the Swift opaque-pointer rule and
/// why this is `OpaquePointer` rather than a typed generic.
final class GObjectBox: @unchecked Sendable {
    private let pointer: OpaquePointer

    /// Takes a `+1` ref from the caller (no pre-`g_object_ref`).
    init(takingOwnershipOf pointer: OpaquePointer) {
        self.pointer = pointer
    }

    /// Borrow the pointer for the closure's lifetime only. Synchronous C
    /// callbacks invoked from inside the closure are safe escapes; storing
    /// the pointer for later use is not.
    func withPointer<R>(_ body: (OpaquePointer) throws -> R) rethrows -> R {
        try body(pointer)
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(pointer))
    }
}

/// Consume a `g_malloc`'d UTF-8 string from poppler: copy into a Swift
/// `String`, free the C buffer. `collapseEmpty` returns `nil` for ""; pass
/// false when the empty string is semantically meaningful (e.g.
/// `poppler_page_get_text` on a page with no text layer).
func takeOwnedString(_ ptr: UnsafeMutablePointer<gchar>?, collapseEmpty: Bool = true) -> String? {
    guard let p = ptr else { return nil }
    let s = String(cString: p)
    g_free(UnsafeMutableRawPointer(p))
    return collapseEmpty && s.isEmpty ? nil : s
}
#endif
