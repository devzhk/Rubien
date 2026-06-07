import Foundation
import GRDB

// MARK: - Column Configuration

public enum ColumnIdentifier: String, Codable, CaseIterable, Sendable {
    case title, authors, year, journal, referenceType, tags
    case readingStatus, dateAdded, dateModified
    case doi, publisher, volume, issue, pages, pdfAttached
    case lastReadAt, readCount

    public var header: String {
        switch self {
        case .title: return "Title"
        case .authors: return "Authors"
        case .year: return "Year"
        case .journal: return "Journal"
        case .referenceType: return "Type"
        case .tags: return "Tags"
        case .readingStatus: return "Status"
        case .dateAdded: return "Added"
        case .dateModified: return "Modified"
        case .doi: return "DOI"
        case .publisher: return "Publisher"
        case .volume: return "Volume"
        case .issue: return "Issue"
        case .pages: return "Pages"
        case .pdfAttached: return "PDF"
        case .lastReadAt: return "Last Read"
        case .readCount: return "Read Count"
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
        case .dateAdded: return "dateAdded"
        case .dateModified: return "dateModified"
        case .doi: return "doi"
        case .publisher: return "publisher"
        case .volume: return "volume"
        case .issue: return "issue"
        case .pages: return "pages"
        case .pdfAttached: return "pdfPath"
        case .lastReadAt: return "lastReadAt"
        case .readCount: return "readCount"
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
        .init(columnId: .dateAdded,     isVisible: true,  displayOrder: 7),
        .init(columnId: .dateModified,  isVisible: false, displayOrder: 8),
        .init(columnId: .doi,           isVisible: false, displayOrder: 9),
        .init(columnId: .publisher,     isVisible: false, displayOrder: 10),
        .init(columnId: .volume,        isVisible: false, displayOrder: 11),
        .init(columnId: .issue,         isVisible: false, displayOrder: 12),
        .init(columnId: .pages,         isVisible: false, displayOrder: 13),
        .init(columnId: .pdfAttached,   isVisible: false, displayOrder: 14),
        .init(columnId: .lastReadAt,    isVisible: false, displayOrder: 15),
        .init(columnId: .readCount,     isVisible: false, displayOrder: 16),
    ]
}

// MARK: - Sort Configuration

public struct ViewSort: Codable, Hashable, Sendable {
    public var target: FieldTarget
    public var ascending: Bool

    public init(target: FieldTarget, ascending: Bool) {
        self.target = target
        self.ascending = ascending
    }

    public static let defaultSort = ViewSort(target: .builtin(.dateAdded), ascending: false)
}

// MARK: - Filter Configuration

public enum FilterOperator: String, Codable, Hashable, Sendable, CaseIterable {
    case equals, notEquals
    case contains, notContains
    case startsWith, endsWith
    case greaterThan, lessThan
    case greaterOrEqual, lessOrEqual
    case isWithin
    case isAnyOf, isNoneOf
    case containsAnyOf, containsNoneOf, containsAllOf
    case isChecked, isUnchecked
    case isEmpty, isNotEmpty
}

public struct ViewFilter: Codable, Hashable, Sendable {
    public var target: FieldTarget
    public var op: FilterOperator
    public var value: FilterValue

    public init(target: FieldTarget, op: FilterOperator, value: FilterValue) {
        self.target = target
        self.op = op
        self.value = value
    }
}

// MARK: - View Scope

public enum ViewScope: Codable, Hashable, Sendable {
    case all
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
    public var groupByJSON: String?
    /// JSON array of `customizationID` strings whose columns should render
    /// wrapped (multi-line) instead of truncated. Per-view, uniform across
    /// built-ins and custom props — mirrors the filter/sort pattern.
    /// Presence ≡ wrapped; absent ≡ unwrapped.
    public var columnWrapsJSON: String
    public var isDefault: Bool
    public var displayOrder: Int
    public var dateCreated: Date
    public var dateModified: Date

    public init(
        id: Int64? = nil,
        name: String,
        icon: String = ViewIconCatalog.defaultIcon,
        scope: ViewScope = .all,
        columns: [ColumnConfig] = ColumnConfig.defaultColumns,
        filters: [ViewFilter] = [],
        sorts: [ViewSort] = [.defaultSort],
        groupBy: GroupConfig? = nil,
        columnWraps: Set<String> = [],
        isDefault: Bool = false,
        displayOrder: Int = 0,
        dateCreated: Date = Date(),
        dateModified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.scopeJSON = Self.encodeJSON(scope) ?? "{}"
        self.columnsJSON = Self.encodeJSON(columns) ?? "[]"
        self.filtersJSON = Self.encodeJSON(filters) ?? "[]"
        self.sortsJSON = Self.encodeJSON(sorts) ?? "[]"
        self.groupByJSON = groupBy.flatMap(Self.encodeJSON)
        self.columnWrapsJSON = Self.encodeJSON(columnWraps.sorted()) ?? "[]"
        self.isDefault = isDefault
        self.displayOrder = displayOrder
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }

    // MARK: - JSON accessors

    public var parsedScope: ViewScope {
        get { Self.decodeJSON(scopeJSON, as: ViewScope.self) ?? .all }
        set { scopeJSON = Self.encodeJSON(newValue) ?? "{}" }
    }

    public var parsedColumns: [ColumnConfig] {
        get { Self.decodeJSON(columnsJSON, as: [ColumnConfig].self) ?? ColumnConfig.defaultColumns }
        set { columnsJSON = Self.encodeJSON(newValue) ?? "[]" }
    }

    public var parsedFilters: [ViewFilter] {
        get { Self.decodeJSON(filtersJSON, as: [ViewFilter].self) ?? [] }
        set { filtersJSON = Self.encodeJSON(newValue) ?? "[]" }
    }

    public var parsedSorts: [ViewSort] {
        get { Self.decodeJSON(sortsJSON, as: [ViewSort].self) ?? [.defaultSort] }
        set { sortsJSON = Self.encodeJSON(newValue) ?? "[]" }
    }

    public var parsedGroupBy: GroupConfig? {
        get { groupByJSON.flatMap { Self.decodeJSON($0, as: GroupConfig.self) } }
        set { groupByJSON = newValue.flatMap(Self.encodeJSON) }
    }

    public var parsedColumnWraps: Set<String> {
        // Setter encodes a sorted array so the on-wire shape is deterministic
        // — two devices toggling the same set produce identical JSON, which
        // keeps CloudKit's change-tag and our local dirty-compare honest.
        get { Set(Self.decodeJSON(columnWrapsJSON, as: [String].self) ?? []) }
        set { columnWrapsJSON = Self.encodeJSON(newValue.sorted()) ?? "[]" }
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decodeJSON<T: Decodable>(_ json: String, as type: T.Type) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
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
        case id, name, icon, scopeJSON, columnsJSON, filtersJSON, sortsJSON, groupByJSON
        case columnWrapsJSON
        case isDefault, displayOrder, dateCreated, dateModified
    }
}
