import Foundation
import CloudKit

/// Observable state the sync stack reports to SwiftUI and the CLI.
///
/// `.error` wraps raw `CKError` so the error table's per-code UX
/// decisions (see spec) can switch on `.code`. Equality requires
/// manual == because `CKError` is a struct wrapping `NSError` which
/// doesn't conform to Equatable by default.
public enum SyncStatus: Sendable {
    case disabled
    case unavailable(reason: String)
    case signedOut
    case idle
    case syncing
    case error(CKError)
}

extension SyncStatus: Equatable {
    public static func == (lhs: SyncStatus, rhs: SyncStatus) -> Bool {
        switch (lhs, rhs) {
        case (.disabled, .disabled), (.signedOut, .signedOut),
             (.idle, .idle), (.syncing, .syncing):
            return true
        case (.unavailable(let l), .unavailable(let r)):
            return l == r
        case (.error(let l), .error(let r)):
            // NSError equality compares domain + code + userInfo;
            // SyncStatus callers only care about code for routing, so
            // we match on (domain, code) to keep tests stable.
            return l._domain == r._domain && l.errorCode == r.errorCode
        default:
            return false
        }
    }
}
