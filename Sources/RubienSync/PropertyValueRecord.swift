import Foundation
import CloudKit
import RubienCore

/// `PropertyValue` ↔ `CKRecord` mapping.
///
/// Both FKs are required — a propertyValue without either referenceId or
/// propertyId is meaningless (schema enforces UNIQUE(referenceId, propertyId)
/// and NOT NULL on both). `value` stays nullable; that's how deletion is
/// represented for multi-select (empty array serializes to nil, not "[]").
extension PropertyValue {

    public enum RecordField {
        public static let referenceId  = "referenceId"
        public static let propertyId   = "propertyId"
        public static let value        = "value"
        public static let dateModified = "dateModified"
    }

    /// Schema-invariant test (Phase E) reads this. Keep in lockstep with `RecordField`.
    public static let allFieldNames: [String] = [
        RecordField.referenceId,
        RecordField.propertyId,
        RecordField.value,
        RecordField.dateModified,
    ]

    public func populate(record: CKRecord) {
        record[RecordField.referenceId]  = referenceId
        record[RecordField.propertyId]   = propertyId
        record[RecordField.value]        = value
        record[RecordField.dateModified] = dateModified
    }

    public static func makeRecord(
        recordName: String,
        propertyValue: PropertyValue
    ) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(
            recordType: SyncConstants.RecordType.propertyValue,
            recordID: id
        )
        propertyValue.populate(record: record)
        return record
    }

    /// Failable decode. The FK pair is required — a value without either side
    /// can't be persisted. Missing `dateModified` falls back to `Date()` for
    /// forward compat with peers that wrote the record before this field was
    /// added.
    public init?(record: CKRecord) {
        guard
            let referenceId = record[RecordField.referenceId] as? Int64,
            let propertyId  = record[RecordField.propertyId]  as? Int64
        else {
            return nil
        }
        self.init(
            referenceId: referenceId,
            propertyId: propertyId,
            value: record[RecordField.value] as? String,
            dateModified: (record[RecordField.dateModified] as? Date) ?? Date()
        )
    }
}
