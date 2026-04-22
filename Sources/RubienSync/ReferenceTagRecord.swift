import Foundation
import CloudKit
import RubienCore

/// `ReferenceTag` (the reference↔tag pivot) ↔ `CKRecord` mapping.
///
/// Unlike other synced entities, the pivot has a composite primary key
/// (`referenceId`, `tagId`) and no surrogate rowID. The CloudKit record name
/// is `"<referenceId>/<tagId>"` — same synthetic format produced by the
/// dirty-tracking triggers, so the two layers agree on identity without a
/// translation step.
///
/// FKs are stored as plain values (Int64 today, String UUID post-A-pks), not
/// `CKRecord.Reference` — we manage cascading deletes via SQLite FKs locally
/// and don't want CloudKit's referential-integrity semantics fighting ours.
extension ReferenceTag {

    public enum RecordField {
        public static let referenceId = "referenceId"
        public static let tagId       = "tagId"
    }

    /// Build the canonical CloudKit recordName for this pivot row. Matches
    /// the expression emitted by the `referenceTag_ai` / `_au` / `_ad`
    /// triggers in `AppDatabase.swift`, so a dirty-queue entry's entityId
    /// and the CKRecord's recordName are always the same string.
    public static func recordName(referenceId: Int64, tagId: Int64) -> String {
        "\(referenceId)/\(tagId)"
    }

    public var recordName: String {
        Self.recordName(referenceId: referenceId, tagId: tagId)
    }

    public func populate(record: CKRecord) {
        record[RecordField.referenceId] = referenceId
        record[RecordField.tagId]       = tagId
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
    /// that would pollute the local DB with bad joins.
    public init?(record: CKRecord) {
        guard
            let referenceId = record[RecordField.referenceId] as? Int64,
            let tagId = record[RecordField.tagId] as? Int64
        else {
            return nil
        }
        self.init(referenceId: referenceId, tagId: tagId)
    }
}
