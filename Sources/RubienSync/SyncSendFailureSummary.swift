#if canImport(CloudKit)
import CloudKit

struct SyncSendFailureInput {
    let error: CKError
    let entityType: String
}

struct SyncSendFailureSummary {
    let error: CKError
    let count: Int
    let entityTypes: [String]
}

enum SyncSendFailureSummarizer {
    private struct Key: Hashable, Comparable {
        let domain: String
        let code: Int
        let description: String

        static func < (lhs: Key, rhs: Key) -> Bool {
            if lhs.domain != rhs.domain { return lhs.domain < rhs.domain }
            if lhs.code != rhs.code { return lhs.code < rhs.code }
            return lhs.description < rhs.description
        }
    }

    /// Collapse one engine callback's repeated failures without losing their
    /// scope. Pure and CKSyncEngine-free so XCTest needs no CloudKit entitlement.
    static func summarize(
        _ failures: [SyncSendFailureInput]
    ) -> [SyncSendFailureSummary] {
        var grouped: [Key: (error: CKError, count: Int, types: Set<String>)] = [:]
        for failure in failures {
            let key = Key(
                domain: failure.error._domain,
                code: failure.error.errorCode,
                description: failure.error.localizedDescription
            )
            var value = grouped[key]
                ?? (error: failure.error, count: 0, types: [])
            value.count += 1
            value.types.insert(failure.entityType)
            grouped[key] = value
        }
        return grouped.keys.sorted().compactMap { key in
            guard let value = grouped[key] else { return nil }
            return SyncSendFailureSummary(
                error: value.error,
                count: value.count,
                entityTypes: value.types.sorted()
            )
        }
    }
}
#endif
