import Foundation
import GRDB

public struct PropertyValue: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64?
    public var referenceId: Int64
    public var propertyId: Int64
    public var value: String?
    public var dateModified: Date

    public init(
        id: Int64? = nil,
        referenceId: Int64,
        propertyId: Int64,
        value: String? = nil,
        dateModified: Date = Date()
    ) {
        self.id = id
        self.referenceId = referenceId
        self.propertyId = propertyId
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
        case id, referenceId, propertyId, value, dateModified
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
