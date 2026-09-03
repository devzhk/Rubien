#if canImport(CloudKit)
import Foundation
import GRDB
import RubienCore

/// Runtime-only classification of numeric `referencePDF` sync-state keys.
/// The frozen v14 migration intentionally owns a separate implementation.
struct PDFSyncStateIdentityClassification: Equatable, Sendable {
    let isStale: Bool
    let isAmbiguous: Bool
    let repairTargetEntityId: String?
}

enum PDFSyncStateIdentityClassifier {
    static func classify(
        entityId: String,
        systemFields: Data?,
        lastPushedAt: Date?,
        db: Database
    ) throws -> PDFSyncStateIdentityClassification? {
        guard SyncIdentifier.isCanonicalDecimal(entityId),
              let localId = Int64(entityId)
        else { return nil }

        let owners = try Row.fetchAll(db, sql: """
            SELECT r.id, r.syncId
            FROM reference r
            JOIN pdfCache pc ON pc.referenceId = r.id
            WHERE r.id = ?
            """, arguments: [localId])
        let localOwnerSyncId: String? = owners.first?["syncId"]
        let alreadyCanonical = try SyncLocalEntityCatalog.contains(
            entityType: SyncEntityType.referencePDF.rawValue,
            entityId: entityId,
            in: db
        )
        if alreadyCanonical {
            let ambiguous = localOwnerSyncId.map { $0 != entityId } ?? false
            return .init(
                isStale: ambiguous,
                isAmbiguous: ambiguous,
                repairTargetEntityId: nil
            )
        }

        guard systemFields == nil, lastPushedAt == nil,
              owners.count == 1,
              let owner = owners.first,
              let ownerId: Int64 = owner["id"],
              let newId: String = owner["syncId"],
              newId != entityId
        else {
            return .init(
                isStale: true,
                isAmbiguous: true,
                repairTargetEntityId: nil
            )
        }

        let collision = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM reference
                WHERE syncId = ? AND id <> ?
            )
            """, arguments: [entityId, ownerId]) ?? true
        return .init(
            isStale: true,
            isAmbiguous: collision,
            repairTargetEntityId: collision ? nil : newId
        )
    }
}
#endif
