#if canImport(CloudKit)
import Foundation
import CloudKit
import RubienCore

/// `Tag` ↔ `CKRecord` mapping. Follows the same conventions as
/// `ReferenceRecord`: identity lives in `CKRecord.ID.recordName`, the local
/// rowID is never encoded, and `populate(record:)` mutates a caller-supplied
/// record so cached server system fields survive across pushes.
extension Tag {

    public enum RecordField {
        public static let name         = "name"
        public static let color        = "color"
        public static let dateModified = "dateModified"
    }

    /// Schema-invariant test (Phase E) reads this. Keep in lockstep with `RecordField`.
    public static let allFieldNames: [String] = [
        RecordField.name,
        RecordField.color,
        RecordField.dateModified,
    ]

    public func populate(record: CKRecord) {
        record[RecordField.name]         = name
        record[RecordField.color]        = color
        record[RecordField.dateModified] = dateModified
    }

    public static func makeRecord(recordName: String, tag: Tag) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(recordType: SyncConstants.RecordType.tag, recordID: id)
        tag.populate(record: record)
        return record
    }

    /// Build a Tag from a CKRecord. Local `id` is always nil — the caller
    /// resolves the local rowID via the record's `recordName`. Missing `name`
    /// falls back to "" rather than crashing (forward/backward compat), but
    /// the SQLite schema's UNIQUE constraint on name means the caller should
    /// treat empty-name decodes as a malformed record and skip persistence.
    /// Missing `dateModified` falls back to `Date()` for forward compat with
    /// peers that wrote the record before this field was added.
    public init(record: CKRecord) {
        self.init(
            name: (record[RecordField.name] as? String) ?? "",
            color: (record[RecordField.color] as? String) ?? "#007AFF",
            dateModified: (record[RecordField.dateModified] as? Date) ?? Date()
        )
    }
}
#endif
