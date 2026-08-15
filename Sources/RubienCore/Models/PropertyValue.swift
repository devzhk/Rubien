import Foundation
import GRDB

public struct PropertyValue: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64?
    public var syncId: String
    public var referenceId: Int64
    public var referenceSyncId: String
    public var propertyId: Int64
    public var propertySyncId: String
    public var value: String?
    public var dateModified: Date

    public init(
        id: Int64? = nil,
        syncId: String = "",
        referenceId: Int64,
        referenceSyncId: String = "",
        propertyId: Int64,
        propertySyncId: String = "",
        value: String? = nil,
        dateModified: Date = Date()
    ) {
        self.id = id
        self.syncId = syncId
        self.referenceId = referenceId
        self.referenceSyncId = referenceSyncId
        self.propertyId = propertyId
        self.propertySyncId = propertySyncId
        self.value = value
        self.dateModified = dateModified
    }
}

// MARK: - GRDB Record

extension PropertyValue: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "propertyValue"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns: String, ColumnExpression {
        case id, syncId, referenceId, referenceSyncId, propertyId, propertySyncId
        case value, dateModified
    }
}

// MARK: - multiSelect codec
//
// multiSelect `value` is stored as a JSON-encoded `[String]`. Empty-array state
// is represented by a nil row in `propertyValue`, not by `"[]"`, so `encode`
// returns an empty string on an empty input — callers write nil to delete the
// row when they receive an empty result.

extension PropertyValue {
    private static let multiSelectDecoder = JSONDecoder()
    private static let multiSelectEncoder = JSONEncoder()

    public static func decodeMultiSelect(_ raw: String) -> [String] {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? multiSelectDecoder.decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    public static func encodeMultiSelect(_ values: [String]) -> String {
        guard !values.isEmpty,
              let data = try? multiSelectEncoder.encode(values),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }
}
