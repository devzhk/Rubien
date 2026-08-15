#if canImport(CloudKit)
import Foundation
import CloudKit
import RubienCore

/// `ReferenceTag` (the reference↔tag pivot) ↔ `CKRecord` mapping.
///
/// Unlike other synced entities, the pivot has a composite local primary key
/// (`referenceId`, `tagId`) and no surrogate rowID. Its CloudKit record name is
/// `"<referenceSyncId>/<tagSyncId>"`, derived from stable endpoint identities;
/// the dirty-tracking triggers emit the same value from the shadow FK columns.
///
/// FKs are stored as plain values rather than `CKRecord.Reference`: SQLite
/// keeps integer FKs for local joins and cascades, while the wire format uses
/// the matching global shadow identities.
extension ReferenceTag {

    public enum RecordField {
        public static let syncId      = SyncRecordIdentity.syncIdField
        public static let referenceId  = "referenceId"
        public static let tagId        = "tagId"
        public static let referenceSyncId = "referenceSyncId"
        public static let tagSyncId       = "tagSyncId"
        public static let dateModified = "dateModified"
    }

    /// Schema-invariant test (Phase E) reads this. Keep in lockstep with `RecordField`.
    /// The pivot encodes both FKs into the recordName too, but we still ship
    /// them as record fields so a cold decode without the recordName context
    /// is sufficient. `dateModified` is shipped to keep the schema-invariant
    /// allow-list empty even though the apply path is insert-if-absent.
    public static let allFieldNames: [String] = [
        RecordField.syncId,
        RecordField.referenceId,
        RecordField.tagId,
        RecordField.referenceSyncId,
        RecordField.tagSyncId,
        RecordField.dateModified,
    ]

    /// Build the canonical CloudKit recordName for this pivot row. Matches
    /// the expression emitted by the `referenceTag_ai` / `_au` / `_ad`
    /// triggers in `AppDatabase.swift`, so a dirty-queue entry's entityId
    /// and the CKRecord's recordName are always the same string.
    public static func recordName(referenceId: Int64, tagId: Int64) -> String {
        "\(referenceId)\(SyncConstants.pivotSeparator)\(tagId)"
    }

    public var recordName: String {
        syncId.isEmpty
            ? Self.recordName(referenceId: referenceId, tagId: tagId)
            : syncId
    }

    public func populate(record: CKRecord) {
        let wireReferenceSyncId = referenceSyncId.isEmpty
            ? String(referenceId)
            : referenceSyncId
        let wireTagSyncId = tagSyncId.isEmpty ? String(tagId) : tagSyncId
        let wireSyncId = syncId.isEmpty
            ? "\(wireReferenceSyncId)/\(wireTagSyncId)"
            : syncId
        SyncRecordIdentity.write(wireSyncId, to: record)
        record[RecordField.referenceSyncId] = wireReferenceSyncId
        record[RecordField.tagSyncId] = wireTagSyncId
        record[RecordField.referenceId] = SyncRecordIdentity.legacyInteger(
            for: wireReferenceSyncId
        )
        record[RecordField.tagId] = SyncRecordIdentity.legacyInteger(for: wireTagSyncId)
        record[RecordField.dateModified] = dateModified
    }

    public static func makeRecord(referenceTag: ReferenceTag) -> CKRecord {
        let id = CKRecord.ID(
            recordName: referenceTag.recordName,
            zoneID: SyncConstants.libraryZoneID
        )
        let record = CKRecord(
            recordType: SyncConstants.RecordType.referenceTag,
            recordID: id
        )
        referenceTag.populate(record: record)
        return record
    }

    /// Failable decode. The FK pair is required — a pivot row without both
    /// sides is meaningless and must not be persisted, so we return nil and
    /// let the pull handler log + skip rather than synthesising zero values
    /// that would pollute the local DB with bad joins. Missing `dateModified`
    /// falls back to `Date()` for forward compat with peers that wrote the
    /// record before this field was added.
    public init?(record: CKRecord) {
        guard let referenceSyncId = SyncRecordIdentity.decodedForeignKey(
            from: record,
            globalField: RecordField.referenceSyncId,
            legacyField: RecordField.referenceId
        ), let tagSyncId = SyncRecordIdentity.decodedForeignKey(
            from: record,
            globalField: RecordField.tagSyncId,
            legacyField: RecordField.tagId
        )
        else {
            return nil
        }
        self.init(
            syncId: SyncRecordIdentity.decodedSyncId(
                from: record,
                expectedType: .referenceTag
            ),
            referenceId: (record[RecordField.referenceId] as? Int64) ?? 0,
            tagId: (record[RecordField.tagId] as? Int64) ?? 0,
            referenceSyncId: referenceSyncId,
            tagSyncId: tagSyncId,
            dateModified: (record[RecordField.dateModified] as? Date) ?? Date()
        )
    }
}
#endif
