import Foundation
import CloudKit
import RubienCore

/// `MetadataEvidence` ↔ `CKRecord` mapping.
///
/// Evidence rows are append-only artifacts from the resolver pipeline. Both
/// FKs (`intakeId`, `referenceId`) are nullable — an evidence row may exist
/// before a reference is persisted (intake stage) or after the intake row has
/// been deleted (reference stage). `bundleHash` is required; it's the dedup
/// key the verifier uses to recognize "same evidence".
extension MetadataEvidence {

    public enum RecordField {
        public static let intakeId     = "intakeId"
        public static let referenceId  = "referenceId"
        public static let bundleHash   = "bundleHash"
        public static let source       = "source"
        public static let recordKey    = "recordKey"
        public static let sourceURL    = "sourceURL"
        public static let fetchMode    = "fetchMode"
        public static let payloadJSON  = "payloadJSON"
        public static let createdAt    = "createdAt"
    }

    public func populate(record: CKRecord) {
        record[RecordField.intakeId]    = intakeId
        record[RecordField.referenceId] = referenceId
        record[RecordField.bundleHash]  = bundleHash
        record[RecordField.source]      = source.rawValue
        record[RecordField.recordKey]   = recordKey
        record[RecordField.sourceURL]   = sourceURL
        record[RecordField.fetchMode]   = fetchMode.rawValue
        record[RecordField.payloadJSON] = payloadJSON
        record[RecordField.createdAt]   = createdAt
    }

    public static func makeRecord(
        recordName: String,
        evidence: MetadataEvidence
    ) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(
            recordType: SyncConstants.RecordType.metadataEvidence,
            recordID: id
        )
        evidence.populate(record: record)
        return record
    }

    /// Failable decode. `bundleHash` and `payloadJSON` are required — an
    /// evidence row missing either is useless (the hash is the dedup key and
    /// the payload is the whole point of the row). Unknown `source` /
    /// `fetchMode` rawValues fall back to `.translationServer` / `.manual`
    /// per forward-compat guidance.
    public init?(record: CKRecord) {
        guard
            let bundleHash = record[RecordField.bundleHash] as? String,
            let payload    = record[RecordField.payloadJSON] as? String
        else {
            return nil
        }

        let source = (record[RecordField.source] as? String)
            .flatMap(MetadataSource.init(rawValue:)) ?? .translationServer
        let fetchMode = (record[RecordField.fetchMode] as? String)
            .flatMap(FetchMode.init(rawValue:)) ?? .manual

        self.init(
            intakeId: record[RecordField.intakeId] as? Int64,
            referenceId: record[RecordField.referenceId] as? Int64,
            bundleHash: bundleHash,
            source: source,
            recordKey: record[RecordField.recordKey] as? String,
            sourceURL: record[RecordField.sourceURL] as? String,
            fetchMode: fetchMode,
            payloadJSON: payload,
            createdAt: (record[RecordField.createdAt] as? Date) ?? Date()
        )
    }
}
