#if os(Linux)
import Foundation
import CPoppler

/// RAII wrapper that owns a `GError*` and frees it on deinit.
final class GErrorWrapper: Error, @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<GError>
    let domain: GQuark
    let code: Int32
    let message: String

    init(takingOwnershipOf pointer: UnsafeMutablePointer<GError>) {
        self.pointer = pointer
        self.domain = pointer.pointee.domain
        self.code = pointer.pointee.code
        self.message = pointer.pointee.message.map { String(cString: $0) } ?? ""
    }

    deinit {
        g_error_free(pointer)
    }
}
#endif
