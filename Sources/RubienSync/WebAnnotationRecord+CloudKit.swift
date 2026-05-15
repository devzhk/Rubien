#if canImport(CloudKit)
import Foundation
import CloudKit
import RubienCore

/// `WebAnnotationRecord` ↔ `CKRecord` mapping.
///
/// Web annotations anchor to the extracted page text via
/// (anchorText, prefixText?, suffixText?) rather than to pixel bounds; they
/// port between devices without re-layout concerns. `referenceId` is a plain
/// Int64 (post A-pks: String UUID), not a `CKRecord.Reference`.
extension WebAnnotationRecord {

    public enum RecordField {
        public static let referenceId  = "referenceId"
        public static let type         = "type"
        public static let selectedText = "selectedText"
        public static let noteText     = "noteText"
        public static let color        = "color"
        public static let anchorText   = "anchorText"
        public static let prefixText   = "prefixText"
        public static let suffixText   = "suffixText"
        public static let dateCreated  = "dateCreated"
        public static let dateModified = "dateModified"
    }

    /// Schema-invariant test (Phase E) reads this. Keep in lockstep with `RecordField`.
    public static let allFieldNames: [String] = [
        RecordField.referenceId,
        RecordField.type,
        RecordField.selectedText,
        RecordField.noteText,
        RecordField.color,
        RecordField.anchorText,
        RecordField.prefixText,
        RecordField.suffixText,
        RecordField.dateCreated,
        RecordField.dateModified,
    ]

    public func populate(record: CKRecord) {
        record[RecordField.referenceId]  = referenceId
        record[RecordField.type]         = type.rawValue
        // Older peers still read selectedText; write it as a mirror of anchorText
        // so they keep rendering until they upgrade.
        record[RecordField.selectedText] = anchorText
        record[RecordField.noteText]     = noteText
        record[RecordField.color]        = color
        record[RecordField.anchorText]   = anchorText
        record[RecordField.prefixText]   = prefixText
        record[RecordField.suffixText]   = suffixText
        record[RecordField.dateCreated]  = dateCreated
        record[RecordField.dateModified] = dateModified
    }

    public static func makeRecord(
        recordName: String,
        annotation: WebAnnotationRecord
    ) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(
            recordType: SyncConstants.RecordType.webAnnotation,
            recordID: id
        )
        annotation.populate(record: record)
        return record
    }

    /// Failable decode. `referenceId` is required; `anchorText` is required
    /// but for forward-compat we fall back to `selectedText` when peers wrote
    /// records before the model unified the two. Unknown `type` rawValues
    /// fall back to `.highlight`. Missing `dateModified` falls back to
    /// `Date()` for forward compat with peers that predate the field.
    public init?(record: CKRecord) {
        guard let referenceId = record[RecordField.referenceId] as? Int64 else {
            return nil
        }
        let anchor = (record[RecordField.anchorText] as? String)
            ?? (record[RecordField.selectedText] as? String)
        guard let anchorText = anchor else { return nil }

        let type = (record[RecordField.type] as? String)
            .flatMap(AnnotationType.init(rawValue:)) ?? .highlight

        self.init(
            referenceId: referenceId,
            type: type,
            noteText: record[RecordField.noteText] as? String,
            color: (record[RecordField.color] as? String) ?? "#FFDE59",
            anchorText: anchorText,
            prefixText: record[RecordField.prefixText] as? String,
            suffixText: record[RecordField.suffixText] as? String,
            dateCreated: (record[RecordField.dateCreated] as? Date) ?? Date(),
            dateModified: (record[RecordField.dateModified] as? Date) ?? Date()
        )
    }
}
#endif
