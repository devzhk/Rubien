#if canImport(CloudKit)
import Foundation
import GRDB
import RubienCore

public struct SyncIdentityDiagnostics: Codable, Equatable, Sendable {
    public struct ShapeCounts: Codable, Equatable, Sendable {
        public var uuid: Int = 0
        public var legacy: Int = 0
        public var compoundOrNatural: Int = 0

        mutating func add(_ identity: String) {
            if SyncIdentifier.isCanonicalDecimal(identity) {
                legacy += 1
            } else if UUID(uuidString: identity) != nil {
                uuid += 1
            } else {
                compoundOrNatural += 1
            }
        }
    }

    public static let identitySchemaVersion = 13

    public let identitySchemaVersion: Int
    public let identityCountsByEntityType: [String: ShapeCounts]
    public let quarantinedRecordCount: Int
    public let unresolvedGlobalForeignKeyCount: Int
    public let invalidRemoteRecordCount: Int
    public let ineligibleLegacyTombstoneCount: Int
    public let fullHistoryReplayPending: Bool
    public let writerUpgradeRequired: Bool
    public let blockedSaveCount: Int
    public let blockedDeleteCount: Int
    public let contradictoryIntentCount: Int
    public let pushInFlightCount: Int
    public let removableOrphanSyncStateCount: Int
    public let preservedOrphanSyncStateCount: Int
    public let unpublishedLiveEntityCount: Int
    public let missingPDFCacheUploadCount: Int
    public let stalePDFIdentityCount: Int
    public let ambiguousPDFIdentityCount: Int
    public let writerUpgradeAcknowledgedAt: String?
    public let writerUpgradeAcknowledgedSchemaVersion: String?

    public static func read(from db: Database) throws -> Self {
        var counts: [String: ShapeCounts] = [:]
        var liveIdentitiesByType: [String: Set<String>] = [:]
        for source in SyncLocalEntityCatalog.current {
            let ids = try source.identities(db)
            liveIdentitiesByType[source.entityType] = Set(ids)
            var shapeCounts = ShapeCounts()
            for id in ids { shapeCounts.add(id) }
            counts[source.entityType] = shapeCounts
        }

        let writerUpgradeRequired = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM syncSession
                WHERE key = 'writerUpgradeRequired' AND value = '1'
            )
            """) ?? true
        let dirtyRows = try Row.fetchAll(db, sql: """
            SELECT entityType, entityId FROM syncState WHERE isDirty = 1
            """)
        let deleteRows = try Row.fetchAll(db, sql: """
            SELECT entityType, entityId FROM tombstone
            WHERE confirmedByServer = 0 AND isPushEligible = 1
            """)
        let blockedSaves = writerUpgradeRequired ? dirtyRows.reduce(into: 0) {
            count, row in
            guard let type = SyncEntityType(rawValue: row["entityType"] as String)
            else { count += 1; return }
            let id: String = row["entityId"]
            if type.isUnsafeForV12(entityId: id) { count += 1 }
        } : 0
        let blockedDeletes = writerUpgradeRequired ? deleteRows.reduce(into: 0) {
            count, row in
            guard let type = SyncEntityType(rawValue: row["entityType"] as String)
            else { count += 1; return }
            let id: String = row["entityId"]
            if type.isUnsafeForV12(entityId: id) { count += 1 }
        } : 0

        var activeTombstonesByType: [String: Set<String>] = [:]
        for row in deleteRows {
            let type: String = row["entityType"]
            let id: String = row["entityId"]
            activeTombstonesByType[type, default: []].insert(id)
        }
        let contradictoryIntentCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*)
            FROM syncState s
            JOIN tombstone t
              ON t.entityType = s.entityType AND t.entityId = s.entityId
            """) ?? 0
        let pushInFlightCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM syncState WHERE pushInFlight = 1"
        ) ?? 0
        let baselineComplete = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM syncSession
                WHERE key='baselineState' AND value='complete'
            )
            """) ?? false

        var removableOrphanSyncStateCount = 0
        var preservedOrphanSyncStateCount = 0
        var unpublishedLiveEntityCount = 0
        var missingPDFCacheUploadCount = 0
        for source in SyncLocalEntityCatalog.current {
            let type = source.entityType
            let live = liveIdentitiesByType[type, default: []]
            let activeDeletes = activeTombstonesByType[type, default: []]
            let states = try Row.fetchAll(db, sql: """
                SELECT entityId, systemFields, lastPushedAt, isDirty
                FROM syncState WHERE entityType = ?
                """, arguments: [type])
            var statesByIdentity: [String: Row] = [:]
            for state in states {
                let id: String = state["entityId"]
                statesByIdentity[id] = state
                guard !live.contains(id), !activeDeletes.contains(id) else {
                    continue
                }
                let isDirty: Int = state["isDirty"]
                let systemFields: Data? = state["systemFields"]
                let lastPushedAt: Date? = state["lastPushedAt"]
                if isDirty == 0 && systemFields == nil && lastPushedAt == nil {
                    removableOrphanSyncStateCount += 1
                } else {
                    preservedOrphanSyncStateCount += 1
                }
                if type == SyncEntityType.referencePDF.rawValue,
                   isDirty == 1
                {
                    missingPDFCacheUploadCount += 1
                }
            }

            guard baselineComplete else { continue }
            for id in live {
                // A fetched modification may temporarily rematerialize a row
                // after a local delete. The active tombstone is complete
                // durable intent for that identity, not an unpublished save.
                guard !activeDeletes.contains(id) else { continue }
                guard let state = statesByIdentity[id] else {
                    unpublishedLiveEntityCount += 1
                    continue
                }
                let isDirty: Int = state["isDirty"]
                let systemFields: Data? = state["systemFields"]
                if isDirty == 0 && systemFields == nil {
                    unpublishedLiveEntityCount += 1
                }
            }
        }

        var stalePDFIdentityCount = 0
        var ambiguousPDFIdentityCount = 0
        let pdfStates = try Row.fetchAll(db, sql: """
            SELECT entityId, systemFields, lastPushedAt
            FROM syncState WHERE entityType='referencePDF'
            """)
        for state in pdfStates {
            let systemFields: Data? = state["systemFields"]
            let lastPushedAt: Date? = state["lastPushedAt"]
            guard let classification = try PDFSyncStateIdentityClassifier
                .classify(
                    entityId: state["entityId"],
                    systemFields: systemFields,
                    lastPushedAt: lastPushedAt,
                    db: db
                )
            else { continue }
            if classification.isStale { stalePDFIdentityCount += 1 }
            if classification.isAmbiguous { ambiguousPDFIdentityCount += 1 }
        }
        let orphanRows = try Row.fetchAll(
            db,
            sql: "SELECT recordType, recordData FROM syncOrphan"
        )
        var unresolvedGlobalForeignKeyCount = 0
        var invalidRemoteRecordCount = 0
        for orphan in orphanRows {
            let archivedType: String = orphan["recordType"]
            let data: Data = orphan["recordData"]
            guard let record = try? SyncRecordIdentity.unarchive(data),
                  record.recordType == archivedType,
                  let type = SyncEntityType.forRecordType(record.recordType),
                  let parsed = SyncEntityType.parseRecordName(
                    record.recordID.recordName
                  ), parsed.0 == type else {
                invalidRemoteRecordCount += 1
                continue
            }
            switch try type.remoteDependencyStatus(
                for: record,
                entityId: parsed.1,
                db: db
            ) {
            case .ready:
                break
            case .unresolved:
                unresolvedGlobalForeignKeyCount += 1
            case .invalid:
                invalidRemoteRecordCount += 1
            }
        }

        return .init(
            identitySchemaVersion: identitySchemaVersion,
            identityCountsByEntityType: counts,
            quarantinedRecordCount: orphanRows.count,
            unresolvedGlobalForeignKeyCount: unresolvedGlobalForeignKeyCount,
            invalidRemoteRecordCount: invalidRemoteRecordCount,
            ineligibleLegacyTombstoneCount: try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE confirmedByServer = 0 AND isPushEligible = 0
                """) ?? 0,
            fullHistoryReplayPending: try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM syncSession
                    WHERE key = 'fullHistoryReplayPending'
                )
                """) ?? true,
            writerUpgradeRequired: writerUpgradeRequired,
            blockedSaveCount: blockedSaves,
            blockedDeleteCount: blockedDeletes,
            contradictoryIntentCount: contradictoryIntentCount,
            pushInFlightCount: pushInFlightCount,
            removableOrphanSyncStateCount: removableOrphanSyncStateCount,
            preservedOrphanSyncStateCount: preservedOrphanSyncStateCount,
            unpublishedLiveEntityCount: unpublishedLiveEntityCount,
            missingPDFCacheUploadCount: missingPDFCacheUploadCount,
            stalePDFIdentityCount: stalePDFIdentityCount,
            ambiguousPDFIdentityCount: ambiguousPDFIdentityCount,
            writerUpgradeAcknowledgedAt: try String.fetchOne(db, sql: """
                SELECT value FROM syncSession
                WHERE key = 'writerUpgradeAcknowledgedAt'
                """),
            writerUpgradeAcknowledgedSchemaVersion: try String.fetchOne(db, sql: """
                SELECT value FROM syncSession
                WHERE key = 'writerUpgradeAcknowledgedSchemaVersion'
                """)
        )
    }
}
#endif
