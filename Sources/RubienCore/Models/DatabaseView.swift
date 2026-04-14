import Foundation
import GRDB

// MARK: - Column Configuration

public enum ColumnIdentifier: String, Codable, CaseIterable, Sendable {
    case title, authors, year, journal, referenceType, tags
    case readingStatus, priority, dateAdded, dateModified
    case doi, publisher, volume, issue, pages, pdfAttached

    public var header: String {
        switch self {
        case .title: return "Title"
        case .authors: return "Authors"
        case .year: return "Year"
        case .journal: return "Journal"
        case .referenceType: return "Type"
        case .tags: return "Tags"
        case .readingStatus: return "Status"
        case .priority: return "Priority"
        case .dateAdded: return "Added"
        case .dateModified: return "Modified"
        case .doi: return "DOI"
        case .publisher: return "Publisher"
        case .volume: return "Volume"
        case .issue: return "Issue"
        case .pages: return "Pages"
        case .pdfAttached: return "PDF"
        }
    }

    public var referenceColumnName: String? {
        switch self {
        case .title: return "title"
        case .authors: return "authors"
        case .year: return "year"
        case .journal: return "journal"
        case .referenceType: return "referenceType"
        case .readingStatus: return "readingStatus"
        case .priority: return "priority"
        case .dateAdded: return "dateAdded"
        case .dateModified: return "dateModified"
        case .doi: return "doi"
        case .publisher: return "publisher"
        case .volume: return "volume"
        case .issue: return "issue"
        case .pages: return "pages"
        case .pdfAttached: return "pdfPath"
        case .tags: return nil
        }
    }
}

public struct ColumnConfig: Codable, Hashable, Sendable {
    public var columnId: ColumnIdentifier
    public var width: Double?
    public var isVisible: Bool
    public var displayOrder: Int

    public init(columnId: ColumnIdentifier, width: Double? = nil, isVisible: Bool, displayOrder: Int) {
        self.columnId = columnId
        self.width = width
        self.isVisible = isVisible
        self.displayOrder = displayOrder
    }

    public static let defaultColumns: [ColumnConfig] = [
        .init(columnId: .title,         isVisible: true,  displayOrder: 0),
        .init(columnId: .authors,       isVisible: true,  displayOrder: 1),
        .init(columnId: .year,          isVisible: true,  displayOrder: 2),
        .init(columnId: .journal,       isVisible: true,  displayOrder: 3),
        .init(columnId: .referenceType, isVisible: true,  displayOrder: 4),
        .init(columnId: .tags,          isVisible: true,  displayOrder: 5),
        .init(columnId: .readingStatus, isVisible: true,  displayOrder: 6),
        .init(columnId: .priority,      isVisible: false, displayOrder: 7),
        .init(columnId: .dateAdded,     isVisible: true,  displayOrder: 8),
        .init(columnId: .dateModified,  isVisible: false, displayOrder: 9),
        .init(columnId: .doi,           isVisible: false, displayOrder: 10),
        .init(columnId: .publisher,     isVisible: false, displayOrder: 11),
        .init(columnId: .volume,        isVisible: false, displayOrder: 12),
        .init(columnId: .issue,         isVisible: false, displayOrder: 13),
        .init(columnId: .pages,         isVisible: false, displayOrder: 14),
        .init(columnId: .pdfAttached,   isVisible: false, displayOrder: 15),
    ]
}

// MARK: - Sort Configuration

public struct ViewSort: Codable, Hashable, Sendable {
    public var field: ColumnIdentifier
    public var ascending: Bool

    public init(field: ColumnIdentifier, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }

    public static let defaultSort = ViewSort(field: .dateAdded, ascending: false)
}

// MARK: - Filter Configuration

public enum FilterOperator: String, Codable, Hashable, Sendable {
    case equals, notEquals
    case contains, notContains
    case greaterThan, lessThan
    case greaterOrEqual, lessOrEqual
    case isEmpty, isNotEmpty
    case isAnyOf
}

public struct ViewFilter: Codable, Hashable, Sendable {
    public var field: ColumnIdentifier
    public var op: FilterOperator
    public var value: String

    public init(field: ColumnIdentifier, op: FilterOperator, value: String) {
        self.field = field
        self.op = op
        self.value = value
    }
}

// MARK: - View Scope

public enum ViewScope: Codable, Hashable, Sendable {
    case all
    case collection(Int64)
    case tag(Int64)
}

// MARK: - DatabaseView Model (Phase 2)

public struct DatabaseView: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64?
    public var name: String
    public var icon: String
    public var scopeJSON: String
    public var columnsJSON: String
    public var filtersJSON: String
    public var sortsJSON: String
    public var isDefault: Bool
    public var displayOrder: Int
    public var dateCreated: Date
    public var dateModified: Date

    public init(
        id: Int64? = nil,
        name: String,
        icon: String = "tablecells",
        scope: ViewScope = .all,
        columns: [ColumnConfig] = ColumnConfig.defaultColumns,
        filters: [ViewFilter] = [],
        sorts: [ViewSort] = [.defaultSort],
        isDefault: Bool = false,
        displayOrder: Int = 0,
        dateCreated: Date = Date(),
        dateModified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.scopeJSON = (try? String(data: JSONEncoder().encode(scope), encoding: .utf8)) ?? "{}"
        self.columnsJSON = (try? String(data: JSONEncoder().encode(columns), encoding: .utf8)) ?? "[]"
        self.filtersJSON = (try? String(data: JSONEncoder().encode(filters), encoding: .utf8)) ?? "[]"
        self.sortsJSON = (try? String(data: JSONEncoder().encode(sorts), encoding: .utf8)) ?? "[]"
        self.isDefault = isDefault
        self.displayOrder = displayOrder
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }

    // MARK: - JSON accessors

    public var parsedScope: ViewScope {
        get {
            guard let data = scopeJSON.data(using: .utf8),
                  let scope = try? JSONDecoder().decode(ViewScope.self, from: data) else {
                return .all
            }
            return scope
        }
        set {
            scopeJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}"
        }
    }

    public var parsedColumns: [ColumnConfig] {
        get {
            guard let data = columnsJSON.data(using: .utf8),
                  let cols = try? JSONDecoder().decode([ColumnConfig].self, from: data) else {
                return ColumnConfig.defaultColumns
            }
            return cols
        }
        set {
            columnsJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
        }
    }

    public var parsedFilters: [ViewFilter] {
        get {
            guard let data = filtersJSON.data(using: .utf8),
                  let filters = try? JSONDecoder().decode([ViewFilter].self, from: data) else {
                return []
            }
            return filters
        }
        set {
            filtersJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
        }
    }

    public var parsedSorts: [ViewSort] {
        get {
            guard let data = sortsJSON.data(using: .utf8),
                  let sorts = try? JSONDecoder().decode([ViewSort].self, from: data) else {
                return [.defaultSort]
            }
            return sorts
        }
        set {
            sortsJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
        }
    }

    public var visibleColumns: [ColumnConfig] {
        parsedColumns
            .filter(\.isVisible)
            .sorted { $0.displayOrder < $1.displayOrder }
    }
}

// MARK: - GRDB Record

extension DatabaseView: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "databaseView"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns: String, ColumnExpression {
        case id, name, icon, scopeJSON, columnsJSON, filtersJSON, sortsJSON
        case isDefault, displayOrder, dateCreated, dateModified
    }
}
