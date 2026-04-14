import Foundation
import GRDB

// MARK: - Property Type

public enum PropertyType: String, Codable, CaseIterable, Sendable {
    case string
    case url
    case number
    case singleSelect
    case multiSelect
    case date
    case checkbox

    public var label: String {
        switch self {
        case .string: return "Text"
        case .url: return "URL"
        case .number: return "Number"
        case .singleSelect: return "Select"
        case .multiSelect: return "Multi-select"
        case .date: return "Date"
        case .checkbox: return "Checkbox"
        }
    }

    public var icon: String {
        switch self {
        case .string: return "text.alignleft"
        case .url: return "link"
        case .number: return "number"
        case .singleSelect: return "chevron.down.circle"
        case .multiSelect: return "tag"
        case .date: return "calendar"
        case .checkbox: return "checkmark.square"
        }
    }
}

// MARK: - Select Option

public struct SelectOption: Codable, Hashable, Sendable {
    public var value: String
    public var color: String

    public init(value: String, color: String) {
        self.value = value
        self.color = color
    }

    public static let colorPalette: [String] = [
        "#007AFF", "#34C759", "#FF9500", "#FF3B30", "#AF52DE",
        "#5AC8FA", "#FF2D55", "#FFCC00", "#00C7BE", "#8E8E93",
        "#30B0C7", "#A2845E", "#FF6482", "#64D2FF", "#BF5AF2",
    ]
}

// MARK: - Property Definition

public struct PropertyDefinition: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64?
    public var name: String
    public var type: PropertyType
    public var optionsJSON: String
    public var sortOrder: Int
    public var isDefault: Bool
    public var defaultFieldKey: String?
    public var isVisible: Bool

    public init(
        id: Int64? = nil,
        name: String,
        type: PropertyType,
        options: [SelectOption] = [],
        sortOrder: Int = 0,
        isDefault: Bool = false,
        defaultFieldKey: String? = nil,
        isVisible: Bool = true
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.optionsJSON = Self.encodeOptions(options)
        self.sortOrder = sortOrder
        self.isDefault = isDefault
        self.defaultFieldKey = defaultFieldKey
        self.isVisible = isVisible
    }

    // MARK: - Options accessors

    public var options: [SelectOption] {
        get {
            guard let data = optionsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([SelectOption].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            optionsJSON = Self.encodeOptions(newValue)
        }
    }

    private static func encodeOptions(_ options: [SelectOption]) -> String {
        guard let data = try? JSONEncoder().encode(options),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

// MARK: - GRDB Record

extension PropertyDefinition: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "propertyDefinition"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns: String, ColumnExpression {
        case id, name, type, optionsJSON, sortOrder, isDefault, defaultFieldKey, isVisible
    }
}
