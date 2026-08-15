import Foundation
import GRDB

public struct Tag: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64?
    public var syncId: String
    public var name: String
    public var color: String
    public var dateModified: Date

    public static var colorPalette: [String] { ColorPalette.default }

    public init(
        id: Int64? = nil,
        syncId: String = SyncIdentifier.random(),
        name: String,
        color: String = "#007AFF",
        dateModified: Date = Date()
    ) {
        self.id = id
        self.syncId = syncId
        self.name = name
        self.color = color
        self.dateModified = dateModified
    }
}

extension Tag: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "tag"

    public static let referenceTagPivot = hasMany(ReferenceTag.self)
    public static let references = hasMany(Reference.self, through: referenceTagPivot, using: ReferenceTag.reference)

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns: String, ColumnExpression {
        case id, syncId, name, color, dateModified
    }
}

public struct ReferenceTag: Codable, Sendable {
    public var syncId: String
    public var referenceId: Int64
    public var tagId: Int64
    public var referenceSyncId: String
    public var tagSyncId: String
    public var dateModified: Date

    public init(
        syncId: String = "",
        referenceId: Int64,
        tagId: Int64,
        referenceSyncId: String = "",
        tagSyncId: String = "",
        dateModified: Date = Date()
    ) {
        self.syncId = syncId
        self.referenceId = referenceId
        self.tagId = tagId
        self.referenceSyncId = referenceSyncId
        self.tagSyncId = tagSyncId
        self.dateModified = dateModified
    }
}

extension ReferenceTag: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "referenceTag"

    public static let reference = belongsTo(Reference.self)
    public static let tag = belongsTo(Tag.self)

    public enum Columns: String, ColumnExpression {
        case syncId, referenceId, tagId, referenceSyncId, tagSyncId, dateModified
    }
}
