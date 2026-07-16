#if canImport(CloudKit)
import Foundation
import CloudKit
import RubienCore

extension ReadingActivity {
    public enum RecordField {
        public static let installationId = "installationId"
        public static let referenceId = "referenceId"
        public static let localDay = "localDay"
        public static let epochRevision = "epochRevision"
        public static let generation = "generation"
        public static let activeSeconds = "activeSeconds"
        public static let lastActiveAt = "lastActiveAt"
        public static let dateModified = "dateModified"
    }

    public static let allFieldNames = [
        RecordField.installationId,
        RecordField.referenceId,
        RecordField.localDay,
        RecordField.epochRevision,
        RecordField.generation,
        RecordField.activeSeconds,
        RecordField.lastActiveAt,
        RecordField.dateModified,
    ]

    public func populate(record: CKRecord) {
        record[RecordField.installationId] = installationId
        record[RecordField.referenceId] = referenceId
        record[RecordField.localDay] = localDay.rawValue
        record[RecordField.epochRevision] = Int64(epochRevision)
        record[RecordField.generation] = generation
        record[RecordField.activeSeconds] = activeSeconds
        record[RecordField.lastActiveAt] = lastActiveAt
        record[RecordField.dateModified] = dateModified
    }

    public static func makeRecord(recordName: String, activity: ReadingActivity) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(recordType: SyncConstants.RecordType.readingActivity, recordID: id)
        activity.populate(record: record)
        return record
    }

    public init?(record: CKRecord) {
        guard let installationId = record[RecordField.installationId] as? String,
              !installationId.contains("/"),
              let referenceId = record[RecordField.referenceId] as? Int64,
              let rawDay = record[RecordField.localDay] as? String,
              let localDay = LocalDay(rawValue: rawDay),
              let epochRevision = record[RecordField.epochRevision] as? Int64,
              epochRevision >= 0,
              let generation = record[RecordField.generation] as? String,
              !generation.contains("/"),
              let activeSeconds = record[RecordField.activeSeconds] as? Int64,
              activeSeconds >= 0,
              let lastActiveAt = record[RecordField.lastActiveAt] as? Date
        else { return nil }

        self.init(
            installationId: installationId,
            referenceId: referenceId,
            localDay: localDay,
            epochRevision: Int(epochRevision),
            generation: generation,
            activeSeconds: activeSeconds,
            lastActiveAt: lastActiveAt,
            dateModified: (record[RecordField.dateModified] as? Date) ?? lastActiveAt
        )
    }
}

extension AssistantActivity {
    public enum RecordField {
        public static let provider = "provider"
        public static let epochRevision = "epochRevision"
        public static let generation = "generation"
        public static let startedAt = "startedAt"
        public static let localDay = "localDay"
        public static let dateModified = "dateModified"
    }

    public static let allFieldNames = [
        RecordField.provider,
        RecordField.epochRevision,
        RecordField.generation,
        RecordField.startedAt,
        RecordField.localDay,
        RecordField.dateModified,
    ]

    public func populate(record: CKRecord) {
        record[RecordField.provider] = provider
        record[RecordField.epochRevision] = Int64(epochRevision)
        record[RecordField.generation] = generation
        record[RecordField.startedAt] = startedAt
        record[RecordField.localDay] = localDay.rawValue
        record[RecordField.dateModified] = dateModified
    }

    public static func makeRecord(recordName: String, activity: AssistantActivity) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(recordType: SyncConstants.RecordType.assistantActivity, recordID: id)
        activity.populate(record: record)
        return record
    }

    public init?(record: CKRecord, id: String) {
        guard let provider = record[RecordField.provider] as? String,
              let epochRevision = record[RecordField.epochRevision] as? Int64,
              epochRevision >= 0,
              let generation = record[RecordField.generation] as? String,
              !generation.contains("/"),
              let startedAt = record[RecordField.startedAt] as? Date,
              let rawDay = record[RecordField.localDay] as? String,
              let localDay = LocalDay(rawValue: rawDay)
        else { return nil }

        self.init(
            id: id,
            provider: provider,
            epochRevision: Int(epochRevision),
            generation: generation,
            startedAt: startedAt,
            localDay: localDay,
            dateModified: (record[RecordField.dateModified] as? Date) ?? startedAt
        )
    }
}

extension ActivityEpoch {
    public enum RecordField {
        public static let kind = "kind"
        public static let revision = "revision"
        public static let generation = "generation"
        public static let resetAt = "resetAt"
        public static let dateModified = "dateModified"
    }

    public static let allFieldNames = [
        RecordField.kind,
        RecordField.revision,
        RecordField.generation,
        RecordField.resetAt,
        RecordField.dateModified,
    ]

    public func populate(record: CKRecord) {
        record[RecordField.kind] = kind.rawValue
        record[RecordField.revision] = Int64(revision)
        record[RecordField.generation] = generation
        record[RecordField.resetAt] = resetAt
        record[RecordField.dateModified] = dateModified
    }

    public static func makeRecord(recordName: String, epoch: ActivityEpoch) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(recordType: SyncConstants.RecordType.activityEpoch, recordID: id)
        epoch.populate(record: record)
        return record
    }

    public init?(record: CKRecord) {
        guard let rawKind = record[RecordField.kind] as? String,
              let kind = ActivityKind(rawValue: rawKind),
              let revision = record[RecordField.revision] as? Int64,
              revision >= 0,
              let generation = record[RecordField.generation] as? String,
              !generation.contains("/")
        else { return nil }

        self.init(
            kind: kind,
            revision: Int(revision),
            generation: generation,
            resetAt: record[RecordField.resetAt] as? Date,
            dateModified: (record[RecordField.dateModified] as? Date) ?? Date()
        )
    }
}
#endif
