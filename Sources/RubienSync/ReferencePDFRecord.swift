#if canImport(CloudKit)
import Foundation
import CloudKit
import RubienCore

/// CKRecord ↔ payload mapping for `CDReferencePDF` — the sibling record that
/// carries a Reference's attached PDF as a `CKAsset`.
///
/// The local "where is this file on disk" state lives in `pdfCache` (a
/// device-local table); this struct is the wire-format only. The dispatch
/// layer (`SyncEntityDispatch`) is responsible for moving `pdfCache` rows
/// onto/off of CKRecord-shaped payloads.
public struct ReferencePDFRecord: Sendable {
    public let referenceId: Int64
    public let assetURL: URL?
    public let assetVersion: Int64
    public let contentHash: String
    public let originalFilename: String
    public let dateModified: Date

    public init(
        referenceId: Int64,
        assetURL: URL?,
        assetVersion: Int64,
        contentHash: String,
        originalFilename: String,
        dateModified: Date
    ) {
        self.referenceId = referenceId
        self.assetURL = assetURL
        self.assetVersion = assetVersion
        self.contentHash = contentHash
        self.originalFilename = originalFilename
        self.dateModified = dateModified
    }
}

extension ReferencePDFRecord {

    public enum RecordField {
        public static let referenceId      = "referenceId"
        public static let asset            = "asset"
        public static let assetVersion     = "assetVersion"
        public static let contentHash      = "contentHash"
        public static let originalFilename = "originalFilename"
        public static let dateModified     = "dateModified"
    }

    /// Schema-invariant test (Phase E) reads this. Keep in lockstep with `RecordField`.
    public static let allFieldNames: [String] = [
        RecordField.referenceId,
        RecordField.asset,
        RecordField.assetVersion,
        RecordField.contentHash,
        RecordField.originalFilename,
        RecordField.dateModified,
    ]

    public func populate(record: CKRecord) {
        record[RecordField.referenceId]      = referenceId
        if let assetURL { record[RecordField.asset] = CKAsset(fileURL: assetURL) }
        record[RecordField.assetVersion]     = assetVersion
        record[RecordField.contentHash]      = contentHash
        record[RecordField.originalFilename] = originalFilename
        record[RecordField.dateModified]     = dateModified
    }

    public static func makeRecord(recordName: String, payload: ReferencePDFRecord) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(recordType: SyncConstants.RecordType.referencePDF, recordID: id)
        payload.populate(record: record)
        return record
    }

    /// Failable: a record without `referenceId` is meaningless (no FK target).
    public init?(record: CKRecord) {
        guard let referenceId = record[RecordField.referenceId] as? Int64 else {
            return nil
        }
        self.referenceId = referenceId
        self.assetURL = (record[RecordField.asset] as? CKAsset)?.fileURL
        self.assetVersion = (record[RecordField.assetVersion] as? Int64) ?? 1
        self.contentHash = (record[RecordField.contentHash] as? String) ?? ""
        self.originalFilename = (record[RecordField.originalFilename] as? String) ?? "asset.pdf"
        self.dateModified = (record[RecordField.dateModified] as? Date) ?? Date()
    }
}
#endif
