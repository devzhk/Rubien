#if canImport(CloudKit)
import Foundation
import CloudKit
import RubienCore

/// `PDFAnnotationRecord` ↔ `CKRecord` mapping.
///
/// `referenceId` is stored as a plain Int64 (post A-pks it becomes a String
/// UUID) — not a `CKRecord.Reference`, because we manage cascade-on-delete via
/// SQLite FKs. `rectsData` already lives as JSON in the DB, so we ship it as a
/// single String field instead of exploding it into a CKRecord list.
extension PDFAnnotationRecord {

    public enum RecordField {
        public static let referenceId   = "referenceId"
        public static let type          = "type"
        public static let selectedText  = "selectedText"
        public static let noteText      = "noteText"
        public static let color         = "color"
        public static let pageIndex     = "pageIndex"
        public static let boundsX       = "boundsX"
        public static let boundsY       = "boundsY"
        public static let boundsWidth   = "boundsWidth"
        public static let boundsHeight  = "boundsHeight"
        public static let rectsData     = "rectsData"
        public static let dateCreated   = "dateCreated"
        public static let dateModified  = "dateModified"
    }

    /// Schema-invariant test (Phase E) reads this. Keep in lockstep with `RecordField`.
    public static let allFieldNames: [String] = [
        RecordField.referenceId,
        RecordField.type,
        RecordField.selectedText,
        RecordField.noteText,
        RecordField.color,
        RecordField.pageIndex,
        RecordField.boundsX,
        RecordField.boundsY,
        RecordField.boundsWidth,
        RecordField.boundsHeight,
        RecordField.rectsData,
        RecordField.dateCreated,
        RecordField.dateModified,
    ]

    public func populate(record: CKRecord) {
        record[RecordField.referenceId]   = referenceId
        record[RecordField.type]          = type.rawValue
        record[RecordField.selectedText]  = selectedText
        record[RecordField.noteText]      = noteText
        record[RecordField.color]         = color
        record[RecordField.pageIndex]     = Int64(pageIndex)
        record[RecordField.boundsX]       = boundsX
        record[RecordField.boundsY]       = boundsY
        record[RecordField.boundsWidth]   = boundsWidth
        record[RecordField.boundsHeight]  = boundsHeight
        record[RecordField.rectsData]     = rectsData
        record[RecordField.dateCreated]   = dateCreated
        record[RecordField.dateModified]  = dateModified
    }

    public static func makeRecord(
        recordName: String,
        annotation: PDFAnnotationRecord
    ) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(
            recordType: SyncConstants.RecordType.pdfAnnotation,
            recordID: id
        )
        annotation.populate(record: record)
        return record
    }

    /// Failable decode. `referenceId` is required — an orphan annotation is
    /// meaningless (FK would violate on insert) so we return nil and let the
    /// pull path log + skip rather than synthesising a zero FK. Unknown
    /// `type` rawValues fall back to `.highlight` per forward-compat guidance.
    /// Missing `dateModified` falls back to `Date()` for forward compat with
    /// peers that wrote the record before this field was added.
    public init?(record: CKRecord) {
        guard let referenceId = record[RecordField.referenceId] as? Int64 else {
            return nil
        }

        let pageIndex = Int((record[RecordField.pageIndex] as? Int64) ?? 0)
        let type = (record[RecordField.type] as? String)
            .flatMap(AnnotationType.init(rawValue:)) ?? .highlight

        self.init(
            referenceId: referenceId,
            type: type,
            selectedText: record[RecordField.selectedText] as? String,
            noteText: record[RecordField.noteText] as? String,
            color: (record[RecordField.color] as? String) ?? "#FFDE59",
            pageIndex: pageIndex,
            rects: [],
            dateCreated: (record[RecordField.dateCreated] as? Date) ?? Date(),
            dateModified: (record[RecordField.dateModified] as? Date) ?? Date()
        )

        // The `init(...)` above derives `rectsData` from the `rects:` param,
        // but we want the wire-format JSON verbatim (it carries rect detail
        // the peer already normalized). Overwrite after init rather than
        // double-decode + re-encode locally.
        if let json = record[RecordField.rectsData] as? String {
            self.rectsData = json
        }
        self.boundsX      = (record[RecordField.boundsX]      as? Double) ?? 0
        self.boundsY      = (record[RecordField.boundsY]      as? Double) ?? 0
        self.boundsWidth  = (record[RecordField.boundsWidth]  as? Double) ?? 0
        self.boundsHeight = (record[RecordField.boundsHeight] as? Double) ?? 0
    }
}
#endif
