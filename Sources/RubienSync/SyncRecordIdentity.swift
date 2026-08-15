#if canImport(CloudKit)
import CloudKit
import Foundation
import RubienCore

/// Shared v13 wire-identity rules. The record name is authoritative; the
/// additive `syncId` field is a consistency check for records written by v13
/// and later. Legacy records omit the field and derive their identity from
/// the opaque entity portion of the record name.
enum SyncRecordIdentity {
    static let syncIdField = "syncId"

    static func validatedSyncId(
        in record: CKRecord,
        expectedType: SyncEntityType
    ) -> String? {
        guard record.recordType == expectedType.recordType,
              let (recordType, entityId) = SyncEntityType.parseRecordName(
                record.recordID.recordName
              ),
              recordType == expectedType,
              !entityId.isEmpty
        else { return nil }

        if let payloadSyncId = record[syncIdField] as? String {
            guard !payloadSyncId.isEmpty, payloadSyncId == entityId else {
                return nil
            }
        }
        return entityId
    }

    static func write(_ syncId: String, to record: CKRecord) {
        record[syncIdField] = syncId
    }

    /// Mapping initializers are also used in isolated codec tests where the
    /// caller supplies an arbitrary record name. Dispatch performs the strict
    /// record-name check before persistence; the codec itself preserves an
    /// explicit payload identity and otherwise derives a qualified one.
    static func decodedSyncId(
        from record: CKRecord,
        expectedType: SyncEntityType
    ) -> String {
        if let payload = record[syncIdField] as? String, !payload.isEmpty {
            return payload
        }
        guard let (type, entityId) = SyncEntityType.parseRecordName(
            record.recordID.recordName
        ), type == expectedType else { return "" }
        return entityId
    }

    /// Write a v12 numeric FK only when the global identity is exactly a
    /// canonical decimal Int64. UUID and other opaque identities deliberately
    /// leave the legacy field absent so an older peer cannot treat them as a
    /// device-local row address.
    static func legacyInteger(for syncId: String) -> Int64? {
        guard SyncIdentifier.isCanonicalDecimal(syncId) else { return nil }
        return Int64(syncId)
    }

    static func decodedForeignKey(
        from record: CKRecord,
        globalField: String,
        legacyField: String
    ) -> String? {
        if let global = record[globalField] as? String, !global.isEmpty {
            return global
        }
        if let legacy = record[legacyField] as? Int64 {
            return String(legacy)
        }
        return nil
    }

    static func archive(_ record: CKRecord) throws -> Data {
        try NSKeyedArchiver.archivedData(
            withRootObject: record,
            requiringSecureCoding: true
        )
    }

    static func unarchive(_ data: Data) throws -> CKRecord? {
        try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
    }
}
#endif
