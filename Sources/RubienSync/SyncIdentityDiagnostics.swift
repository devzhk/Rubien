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
    public let writerUpgradeAcknowledgedAt: String?
    public let writerUpgradeAcknowledgedSchemaVersion: String?

    public static func read(from db: Database) throws -> Self {
        var counts: [String: ShapeCounts] = [:]
        for type in SyncEntityType.allCases {
            let ids: [String]
            switch type {
            case .assistantActivity:
                ids = try String.fetchAll(db, sql: "SELECT id FROM assistantActivity")
            case .activityEpoch:
                ids = try String.fetchAll(db, sql: "SELECT kind FROM activityEpoch")
            case .referencePDF:
                ids = try String.fetchAll(db, sql: """
                    SELECT r.syncId FROM pdfCache pc
                    JOIN reference r ON r.id = pc.referenceId
                    """)
            default:
                ids = try String.fetchAll(
                    db,
                    sql: "SELECT syncId FROM \(type.rawValue)"
                )
            }
            var shapeCounts = ShapeCounts()
            for id in ids { shapeCounts.add(id) }
            counts[type.rawValue] = shapeCounts
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
