import Foundation
import GRDB

public struct WebAnnotationRecord: Identifiable, Codable, Hashable {
    public var id: Int64?
    public var referenceId: Int64
    public var type: AnnotationType
    public var noteText: String?
    public var color: String
    public var anchorText: String
    public var prefixText: String?
    public var suffixText: String?
    public var dateCreated: Date
    public var dateModified: Date

    public init(
        id: Int64? = nil,
        referenceId: Int64,
        type: AnnotationType,
        noteText: String? = nil,
        color: String = "#FFDE59",
        anchorText: String,
        prefixText: String? = nil,
        suffixText: String? = nil,
        dateCreated: Date = Date(),
        dateModified: Date = Date()
    ) {
        self.id = id
        self.referenceId = referenceId
        self.type = type
        self.noteText = noteText
        self.color = color
        self.anchorText = anchorText
        self.prefixText = prefixText
        self.suffixText = suffixText
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }
}

extension WebAnnotationRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "webAnnotation"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns: String, ColumnExpression {
        case id, referenceId, type, selectedText, noteText, color
        case anchorText, prefixText, suffixText, dateCreated, dateModified
    }

    // v1's `selectedText TEXT NOT NULL` column predates the model unification.
    // Writes mirror `anchorText` so the constraint holds; reads ignore it.
    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.referenceId] = referenceId
        container[Columns.type] = type.rawValue
        container[Columns.selectedText] = anchorText
        container[Columns.noteText] = noteText
        container[Columns.color] = color
        container[Columns.anchorText] = anchorText
        container[Columns.prefixText] = prefixText
        container[Columns.suffixText] = suffixText
        container[Columns.dateCreated] = dateCreated
        container[Columns.dateModified] = dateModified
    }
}
