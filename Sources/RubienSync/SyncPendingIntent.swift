#if canImport(CloudKit)
import Foundation
import GRDB
import RubienCore

public enum SyncPendingOperation: String, Codable, Sendable {
    case save
    case delete
}

public struct PendingSyncIdentity: Hashable, Sendable {
    public let type: SyncEntityType
    public let entityId: String
    public let operation: SyncPendingOperation

    public init(
        type: SyncEntityType,
        entityId: String,
        operation: SyncPendingOperation
    ) {
        self.type = type
        self.entityId = entityId
        self.operation = operation
    }

    fileprivate var key: Key { Key(type: type, entityId: entityId) }

    fileprivate struct Key: Hashable, Sendable {
        let type: SyncEntityType
        let entityId: String
    }
}

public struct SyncPendingChangePlan: Equatable, Sendable {
    public let additions: [PendingSyncIdentity]
    public let removals: [PendingSyncIdentity]
}

/// Pure set reconciliation for CKSyncEngine's derived pending cache.
/// Unknown future record types never enter these inputs and are therefore
/// preserved by the thin engine adapter.
public enum SyncPendingIntentPlanner {
    public static func plan(
        current: [PendingSyncIdentity],
        desired: [PendingSyncIdentity],
        refreshing: Set<PendingSyncIdentity> = []
    ) -> SyncPendingChangePlan {
        let currentSet = Set(current)
        let desiredSet = Set(desired)
        // A recovered save can keep the same record identity while its cached
        // server fields change from an update into a create. CKSyncEngine
        // deduplicates a plain add, so force that identity through a
        // remove-then-add cycle. Limit refreshes to still-desired intent so a
        // concurrent delete or cleanup wins normally.
        let refreshSet = refreshing.intersection(desiredSet)
        return SyncPendingChangePlan(
            additions: desiredSet
                .subtracting(currentSet)
                .union(refreshSet)
                .sorted(by: order),
            removals: currentSet
                .subtracting(desiredSet)
                .union(currentSet.intersection(refreshSet))
                .sorted(by: order)
        )
    }

    private static func order(
        _ lhs: PendingSyncIdentity,
        _ rhs: PendingSyncIdentity
    ) -> Bool {
        if lhs.type.rawValue != rhs.type.rawValue {
            return lhs.type.rawValue < rhs.type.rawValue
        }
        if lhs.entityId != rhs.entityId { return lhs.entityId < rhs.entityId }
        return lhs.operation.rawValue < rhs.operation.rawValue
    }
}

public struct BatchIntentResolution: Equatable, Sendable {
    public let intents: [PendingSyncIdentity]
    public let anomalyDetected: Bool
}

private struct DurableIntentSnapshot {
    let writerGate: Bool
    let live: Set<PendingSyncIdentity.Key>
    let dirty: Set<PendingSyncIdentity.Key>
    let activeDeletes: Set<PendingSyncIdentity.Key>
}

/// Final SQLite-authoritative batch decision. This intentionally has no
/// CloudKit inputs so XCTest can exercise it without constructing an
/// unentitled CKSyncEngine or the SDK-private SendChangesContext.
public extension SyncStateStore {
    func desiredPendingIntents(
        _ db: Database
    ) throws -> BatchIntentResolution {
        let dirtyRows = try dirtyEntities(db)
        let deleteRows = try tombstones(db)
        let saves = dirtyRows.map {
            PendingSyncIdentity(
                type: $0.0,
                entityId: $0.1,
                operation: .save
            )
        }
        let deletes = deleteRows.map {
            PendingSyncIdentity(
                type: $0.0,
                entityId: $0.1,
                operation: .delete
            )
        }
        let identities = saves + deletes
        let snapshot = try durableIntentSnapshot(
            db,
            pendingIdentities: identities,
            dirtyRows: dirtyRows,
            deleteRows: deleteRows
        )
        return resolveBatchIntents(
            identities,
            snapshot: snapshot,
            reportDiscardedRequestsAsAnomaly: false
        )
    }

    func resolveBatchIntents(
        _ db: Database,
        pendingIdentities: [PendingSyncIdentity]
    ) throws -> BatchIntentResolution {
        let snapshot = try durableIntentSnapshot(
            db,
            pendingIdentities: pendingIdentities
        )
        return resolveBatchIntents(
            pendingIdentities,
            snapshot: snapshot,
            reportDiscardedRequestsAsAnomaly: true
        )
    }

    private func durableIntentSnapshot(
        _ db: Database,
        pendingIdentities: [PendingSyncIdentity],
        dirtyRows: [(SyncEntityType, String)]? = nil,
        deleteRows: [(SyncEntityType, String)]? = nil
    ) throws -> DurableIntentSnapshot {
        let requestedKeys = Set(pendingIdentities.map(\.key))
        let requestedByType = Dictionary(
            grouping: requestedKeys,
            by: \.type
        )
        var live: Set<PendingSyncIdentity.Key> = []
        for (type, keys) in requestedByType {
            guard let source = SyncLocalEntityCatalog.source(
                for: type.rawValue
            ) else { continue }
            let requestedIds = Set(keys.map(\.entityId))
            for entityId in try source.matchingIdentities(
                requestedIds,
                in: db
            ) {
                live.insert(.init(type: type, entityId: entityId))
            }
        }
        let dirty: Set<PendingSyncIdentity.Key>
        if let dirtyRows {
            dirty = Set(dirtyRows.map {
                .init(type: $0.0, entityId: $0.1)
            }).intersection(requestedKeys)
        } else {
            dirty = try scopedIntentKeys(
                db,
                requestedByType: requestedByType,
                table: "syncState",
                predicate: "isDirty = 1"
            )
        }
        let activeDeletes: Set<PendingSyncIdentity.Key>
        if let deleteRows {
            activeDeletes = Set(deleteRows.map {
                .init(type: $0.0, entityId: $0.1)
            }).intersection(requestedKeys)
        } else {
            activeDeletes = try scopedIntentKeys(
                db,
                requestedByType: requestedByType,
                table: "tombstone",
                predicate: "confirmedByServer = 0 AND isPushEligible = 1"
            )
        }
        return DurableIntentSnapshot(
            writerGate: try writerUpgradeRequired(db),
            live: live,
            dirty: dirty,
            activeDeletes: activeDeletes
        )
    }

    private func scopedIntentKeys(
        _ db: Database,
        requestedByType: [SyncEntityType: [PendingSyncIdentity.Key]],
        table: String,
        predicate: String
    ) throws -> Set<PendingSyncIdentity.Key> {
        var result: Set<PendingSyncIdentity.Key> = []
        for (type, keys) in requestedByType {
            let ids = Array(Set(keys.map(\.entityId))).sorted()
            for start in stride(from: 0, to: ids.count, by: 400) {
                let end = min(start + 400, ids.count)
                let chunk = Array(ids[start..<end])
                let placeholders = Array(
                    repeating: "?",
                    count: chunk.count
                ).joined(separator: ",")
                var arguments: [DatabaseValueConvertible] = [type.rawValue]
                arguments.append(contentsOf: chunk.map {
                    $0 as DatabaseValueConvertible
                })
                let matches = try String.fetchAll(
                    db,
                    sql: """
                        SELECT entityId FROM \(table)
                        WHERE entityType = ? AND \(predicate)
                          AND entityId IN (\(placeholders))
                        """,
                    arguments: StatementArguments(arguments)
                )
                result.formUnion(matches.map {
                    .init(type: type, entityId: $0)
                })
            }
        }
        return result
    }

    private func resolveBatchIntents(
        _ pendingIdentities: [PendingSyncIdentity],
        snapshot: DurableIntentSnapshot,
        reportDiscardedRequestsAsAnomaly: Bool
    ) -> BatchIntentResolution {
        let groups = Dictionary(grouping: pendingIdentities, by: \.key)
        var resolved: [PendingSyncIdentity] = []
        var anomalyDetected = false

        for (key, requests) in groups {
            let requestedOperations = Set(requests.map(\.operation))
            if requestedOperations.count > 1 { anomalyDetected = true }

            if snapshot.writerGate,
               key.type.isUnsafeForV12(entityId: key.entityId)
            {
                continue
            }

            let isLive = snapshot.live.contains(key)
            let isDirty = snapshot.dirty.contains(key)
            let hasActiveDelete = snapshot.activeDeletes.contains(key)

            let desiredOperation: SyncPendingOperation?
            if isLive && hasActiveDelete && isDirty {
                // A dirty live row is an explicit local recreation, so its
                // save wins over an older retained delete marker.
                desiredOperation = .save
                anomalyDetected = true
            } else if hasActiveDelete {
                // A fetched server modification can temporarily materialize
                // a row after a local delete. With no newer dirty state, the
                // exact tombstone remains authoritative even while live data
                // is present.
                desiredOperation = .delete
            } else if isLive && isDirty {
                desiredOperation = .save
            } else {
                desiredOperation = nil
            }

            guard let desiredOperation else {
                if reportDiscardedRequestsAsAnomaly,
                   !requestedOperations.isEmpty
                {
                    anomalyDetected = true
                }
                continue
            }
            guard requestedOperations.contains(desiredOperation) else {
                // The scoped engine cache contains only the opposite stale
                // operation. Do not manufacture a new pending change inside
                // this callback; deferred canonicalization will add it.
                anomalyDetected = true
                continue
            }
            resolved.append(PendingSyncIdentity(
                type: key.type,
                entityId: key.entityId,
                operation: desiredOperation
            ))
        }

        resolved.sort {
            if $0.type.rawValue != $1.type.rawValue {
                return $0.type.rawValue < $1.type.rawValue
            }
            return $0.entityId < $1.entityId
        }
        return BatchIntentResolution(
            intents: resolved,
            anomalyDetected: anomalyDetected
        )
    }
}
#endif
