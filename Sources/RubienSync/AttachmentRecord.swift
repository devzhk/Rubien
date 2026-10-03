#if canImport(CloudKit)
import CloudKit
import Foundation
import CoreFoundation
import RubienCore

/// Attachment wire names match the durable local intent written by v15.
enum AttachmentRecordKind: String, CaseIterable {
    case referenceAttachment, attachmentAsset, attachmentAnnotation

    var entityType: SyncEntityType {
        switch self {
        case .referenceAttachment: .referenceAttachment
        case .attachmentAsset: .attachmentAsset
        case .attachmentAnnotation: .attachmentAnnotation
        }
    }

    var recordType: String {
        switch self {
        case .referenceAttachment: "CDReferenceAttachment"
        case .attachmentAsset: "CDAttachmentAsset"
        case .attachmentAnnotation: "CDAttachmentAnnotation"
        }
    }

    func recordName(_ syncId: String) -> String { "\(rawValue):\(syncId)" }

    func identity(in record: CKRecord) -> String? {
        guard record.recordType == recordType, record.recordID.zoneID == SyncConstants.libraryZoneID,
              let syncId = record["syncId"] as? String,
              Self.isUUID(syncId), record.recordID.recordName == recordName(syncId)
        else { return nil }
        return syncId
    }

    static func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func integer(_ value: CKRecordValue?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.decimalValue == Decimal(number.int64Value) else { return nil }
        return number.int64Value
    }

    func makeRecord(_ syncId: String) -> CKRecord {
        CKRecord(recordType: recordType, recordID: .init(recordName: recordName(syncId), zoneID: SyncConstants.libraryZoneID))
    }
}

extension ReferenceAttachment {
    public static let allFieldNames = [
        "syncId", "referenceSyncId", "kind", "originalFilename", "displayName", "byteCount",
        "contentHash", "dateCreated", "dateModified", "deletedAt",
    ]

    public func populate(record: CKRecord) {
        record["syncId"] = syncId
        record["referenceSyncId"] = referenceSyncId
        record["kind"] = kind
        record["originalFilename"] = originalFilename
        record["displayName"] = displayName
        record["byteCount"] = byteCount
        record["contentHash"] = contentHash
        record["dateCreated"] = dateCreated
        record["dateModified"] = dateModified
        record["deletedAt"] = deletedAt
    }

    public func makeRecord() -> CKRecord {
        let record = AttachmentRecordKind.referenceAttachment.makeRecord(syncId)
        populate(record: record)
        return record
    }

    public init?(record: CKRecord) {
        guard let syncId = AttachmentRecordKind.referenceAttachment.identity(in: record),
              let parent = record["referenceSyncId"] as? String, !parent.isEmpty,
              let kind = record["kind"] as? String, !kind.isEmpty,
              let filename = record["originalFilename"] as? String,
              let name = record["displayName"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let count = AttachmentRecordKind.integer(record["byteCount"]), count >= 0,
              let hash = record["contentHash"] as? String, AttachmentRecordKind.validHash(hash),
              let created = record["dateCreated"] as? Date,
              let modified = record["dateModified"] as? Date,
              record["deletedAt"] == nil || record["deletedAt"] is Date
        else { return nil }
        self.init(syncId: syncId, referenceId: nil, referenceSyncId: parent, kind: kind,
                  originalFilename: filename, displayName: name, byteCount: count, contentHash: hash,
                  dateCreated: created, dateModified: modified, deletedAt: record["deletedAt"] as? Date)
    }
}

public struct AttachmentAssetRecord: Sendable {
    public let attachmentSyncId: String
    public let contentHash: String
    public let byteCount: Int64
    public let assetURL: URL?

    public static let allFieldNames = ["syncId", "attachmentSyncId", "contentHash", "byteCount", "asset"]

    public init(attachmentSyncId: String, contentHash: String, byteCount: Int64, assetURL: URL?) {
        self.attachmentSyncId = attachmentSyncId
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.assetURL = assetURL
    }

    public func populate(record: CKRecord) {
        record["syncId"] = attachmentSyncId
        record["attachmentSyncId"] = attachmentSyncId
        record["contentHash"] = contentHash
        record["byteCount"] = byteCount
        // An omitted asset in a projected inventory is not a file deletion.
        if let assetURL { record["asset"] = CKAsset(fileURL: assetURL) }
    }

    public func makeRecord() -> CKRecord {
        let record = AttachmentRecordKind.attachmentAsset.makeRecord(attachmentSyncId)
        populate(record: record)
        return record
    }

    public init?(record: CKRecord) {
        guard let syncId = AttachmentRecordKind.attachmentAsset.identity(in: record),
              record["attachmentSyncId"] as? String == syncId,
              let hash = record["contentHash"] as? String, AttachmentRecordKind.validHash(hash),
              let count = AttachmentRecordKind.integer(record["byteCount"]), count >= 0,
              record["asset"] == nil || record["asset"] is CKAsset
        else { return nil }
        self.init(attachmentSyncId: syncId, contentHash: hash, byteCount: count,
                  assetURL: (record["asset"] as? CKAsset)?.fileURL)
    }
}

extension ReferenceAttachmentAnnotation {
    public static let allFieldNames = [
        "syncId", "attachmentSyncId", "contentHash", "type", "color", "selectedText", "noteText",
        "anchorKind", "anchorVersion", "anchorJSON", "dateCreated", "dateModified", "deletedAt",
    ]

    public func populate(record: CKRecord) {
        record["syncId"] = syncId
        record["attachmentSyncId"] = attachmentSyncId
        record["contentHash"] = contentHash
        record["dateCreated"] = dateCreated
        record["dateModified"] = dateModified
        record["deletedAt"] = deletedAt
        // Explicit nil assignments clear payload left in a cached active record.
        record["type"] = deletedAt == nil ? type : nil
        record["color"] = deletedAt == nil ? color : nil
        record["selectedText"] = deletedAt == nil ? selectedText : nil
        record["noteText"] = deletedAt == nil ? noteText : nil
        record["anchorKind"] = deletedAt == nil ? anchorKind : nil
        record["anchorVersion"] = deletedAt == nil ? anchorVersion : nil
        record["anchorJSON"] = deletedAt == nil ? anchorJSON : nil
    }

    public func makeRecord() -> CKRecord {
        let record = AttachmentRecordKind.attachmentAnnotation.makeRecord(syncId)
        populate(record: record)
        return record
    }

    public init?(record: CKRecord) {
        let strings = ["type", "color", "selectedText", "noteText", "anchorKind", "anchorJSON"]
        guard let syncId = AttachmentRecordKind.attachmentAnnotation.identity(in: record),
              let parent = record["attachmentSyncId"] as? String, AttachmentRecordKind.isUUID(parent),
              let hash = record["contentHash"] as? String, AttachmentRecordKind.validHash(hash),
              let created = record["dateCreated"] as? Date,
              let modified = record["dateModified"] as? Date,
              record["deletedAt"] == nil || record["deletedAt"] is Date,
              strings.allSatisfy({ record[$0] == nil || record[$0] is String }),
              record["anchorVersion"] == nil || AttachmentRecordKind.integer(record["anchorVersion"]) != nil
        else { return nil }
        let deleted = record["deletedAt"] as? Date
        let version = AttachmentRecordKind.integer(record["anchorVersion"]).flatMap(Int.init(exactly:))
        if deleted == nil {
            guard record["type"] is String, record["color"] is String,
                  record["anchorKind"] is String, let version, version > 0,
                  record["anchorJSON"] is String else { return nil }
        }
        self.init(syncId: syncId, attachmentId: nil, attachmentSyncId: parent, contentHash: hash,
                  type: deleted == nil ? record["type"] as? String : nil,
                  color: deleted == nil ? record["color"] as? String : nil,
                  selectedText: deleted == nil ? record["selectedText"] as? String : nil,
                  noteText: deleted == nil ? record["noteText"] as? String : nil,
                  anchorKind: deleted == nil ? record["anchorKind"] as? String : nil,
                  anchorVersion: deleted == nil ? version : nil,
                  anchorJSON: deleted == nil ? record["anchorJSON"] as? String : nil,
                  dateCreated: created, dateModified: modified, deletedAt: deleted)
        // Unknown versions are retained. A known anchor must be usable on its document kind.
        if deleted == nil, version == 1, ["pdf", "markdown"].contains(anchorKind ?? ""), anchor == nil {
            return nil
        }
    }
}

/// desiredKeys is applied to the whole zone, including matching primary scalar fields.
enum AttachmentInventoryProjection {
    static let desiredKeys = Array(Set(ReferenceAttachment.allFieldNames
        + AttachmentAssetRecord.allFieldNames + ReferenceAttachmentAnnotation.allFieldNames)
        .subtracting(["asset"])).sorted()
}
#endif
