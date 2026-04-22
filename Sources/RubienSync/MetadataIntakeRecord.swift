import Foundation
import CloudKit
import RubienCore

/// `MetadataIntake` ↔ `CKRecord` mapping.
///
/// Intake rows carry the full candidate-selection state the resolver needs to
/// resume. The JSON blobs (seed, fallback reference, current reference,
/// candidates) ship verbatim as String fields so shape additions survive.
/// `linkedReferenceId` is a plain Int64 FK (nullable — intake may not yet be
/// linked to a persisted reference).
extension MetadataIntake {

    public enum RecordField {
        public static let sourceKind            = "sourceKind"
        public static let verificationStatus    = "verificationStatus"
        public static let title                 = "title"
        public static let originalInput         = "originalInput"
        public static let sourceURL             = "sourceURL"
        public static let pdfPath               = "pdfPath"
        public static let seedJSON              = "seedJSON"
        public static let fallbackReferenceJSON = "fallbackReferenceJSON"
        public static let currentReferenceJSON  = "currentReferenceJSON"
        public static let candidatesJSON        = "candidatesJSON"
        public static let statusMessage         = "statusMessage"
        public static let linkedReferenceId     = "linkedReferenceId"
        public static let evidenceBundleHash    = "evidenceBundleHash"
        public static let createdAt             = "createdAt"
        public static let updatedAt             = "updatedAt"
    }

    public func populate(record: CKRecord) {
        record[RecordField.sourceKind]            = sourceKind.rawValue
        record[RecordField.verificationStatus]    = verificationStatus.rawValue
        record[RecordField.title]                 = title
        record[RecordField.originalInput]         = originalInput
        record[RecordField.sourceURL]             = sourceURL
        record[RecordField.pdfPath]               = pdfPath
        record[RecordField.seedJSON]              = seedJSON
        record[RecordField.fallbackReferenceJSON] = fallbackReferenceJSON
        record[RecordField.currentReferenceJSON]  = currentReferenceJSON
        record[RecordField.candidatesJSON]        = candidatesJSON
        record[RecordField.statusMessage]         = statusMessage
        record[RecordField.linkedReferenceId]     = linkedReferenceId
        record[RecordField.evidenceBundleHash]    = evidenceBundleHash
        record[RecordField.createdAt]             = createdAt
        record[RecordField.updatedAt]             = updatedAt
    }

    public static func makeRecord(
        recordName: String,
        intake: MetadataIntake
    ) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(
            recordType: SyncConstants.RecordType.metadataIntake,
            recordID: id
        )
        intake.populate(record: record)
        return record
    }

    /// Non-failable decode. Missing title → "" (schema requires NOT NULL;
    /// caller logs + skips blank-title rows). Unknown `sourceKind` /
    /// `verificationStatus` rawValues fall back to safe defaults
    /// (`.manualEntry`, `.legacy`) per forward-compat guidance.
    public init(record: CKRecord) {
        let sourceKind = (record[RecordField.sourceKind] as? String)
            .flatMap(MetadataIntakeSourceKind.init(rawValue:)) ?? .manualEntry
        let verificationStatus = (record[RecordField.verificationStatus] as? String)
            .flatMap(VerificationStatus.init(rawValue:)) ?? .legacy

        self.init(
            sourceKind: sourceKind,
            verificationStatus: verificationStatus,
            title: (record[RecordField.title] as? String) ?? "",
            originalInput: record[RecordField.originalInput] as? String,
            sourceURL: record[RecordField.sourceURL] as? String,
            pdfPath: record[RecordField.pdfPath] as? String,
            seedJSON: record[RecordField.seedJSON] as? String,
            fallbackReferenceJSON: record[RecordField.fallbackReferenceJSON] as? String,
            currentReferenceJSON: record[RecordField.currentReferenceJSON] as? String,
            candidatesJSON: record[RecordField.candidatesJSON] as? String,
            statusMessage: record[RecordField.statusMessage] as? String,
            linkedReferenceId: record[RecordField.linkedReferenceId] as? Int64,
            evidenceBundleHash: record[RecordField.evidenceBundleHash] as? String,
            createdAt: (record[RecordField.createdAt] as? Date) ?? Date(),
            updatedAt: (record[RecordField.updatedAt] as? Date) ?? Date()
        )
    }
}
