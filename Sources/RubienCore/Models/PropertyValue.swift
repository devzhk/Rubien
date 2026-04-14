import Foundation
import GRDB

public struct PropertyValue: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64?
    public var referenceId: Int64
    public var propertyId: Int64
    public var value: String?

    public init(
        id: Int64? = nil,
        referenceId: Int64,
        propertyId: Int64,
        value: String? = nil
    ) {
        self.id = id
        self.referenceId = referenceId
        self.propertyId = propertyId
        self.value = value
    }
}

// MARK: - GRDB Record

extension PropertyValue: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "propertyValue"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns: String, ColumnExpression {
        case id, referenceId, propertyId, value
    }
}
