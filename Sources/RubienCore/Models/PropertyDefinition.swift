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

    public static var colorPalette: [String] { ColorPalette.default }
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
    public var dateModified: Date

    public init(
        id: Int64? = nil,
        name: String,
        type: PropertyType,
        options: [SelectOption] = [],
        sortOrder: Int = 0,
        isDefault: Bool = false,
        defaultFieldKey: String? = nil,
        isVisible: Bool = true,
        dateModified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.optionsJSON = Self.encodeOptions(options)
        self.sortOrder = sortOrder
        self.isDefault = isDefault
        self.defaultFieldKey = defaultFieldKey
        self.isVisible = isVisible
        self.dateModified = dateModified
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

    public var customizationID: String {
        if isDefault {
            return defaultFieldKey.map { "default_\($0)" } ?? "prop_\(id ?? 0)"
        }
        return "custom_\(id ?? 0)"
    }

    /// `defaultFieldKey` value for the built-in Tags property (routes writes through the Tag table).
    public static let tagsFieldKey = "tags"
    /// `defaultFieldKey` value for the built-in Status property (`Reference.readingStatus` column).
    public static let readingStatusFieldKey = "readingStatus"
    /// `defaultFieldKey` value for the built-in Type property (`Reference.referenceType` column).
    public static let referenceTypeFieldKey = "referenceType"
    /// Display name of the built-in Tags property.
    public static let tagsPropertyName = "Tags"

    /// True if this is the seeded built-in Tags property — its value/option
    /// mutations route through `Tag` + `ReferenceTag` instead of
    /// `propertyValue` / `optionsJSON`. Single source of truth for the
    /// "Tags is just a property" surface in the CLI / MCP / DTOs.
    public var isTags: Bool {
        defaultFieldKey == Self.tagsFieldKey
    }

    /// Append `value` as a new option with an auto-picked color if it isn't already listed.
    /// Returns `true` when the definition was mutated (caller should persist), `false` otherwise.
    @discardableResult
    public mutating func addOptionIfMissing(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var current = options
        if current.contains(where: { $0.value == trimmed }) { return false }
        let used = Set(current.map(\.color))
        current.append(SelectOption(value: trimmed, color: ColorPalette.nextUnused(excluding: used)))
        options = current
        return true
    }
}

extension Sequence where Element == PropertyDefinition {
    /// Find the seeded built-in PropertyDefinition for a given Reference column.
    /// Pair with `PropertyDefinition.*FieldKey` constants to avoid scattering
    /// the `defaultFieldKey == "..."` predicate across views.
    public func first(forFieldKey key: String) -> PropertyDefinition? {
        first { $0.defaultFieldKey == key }
    }
}

// MARK: - GRDB Record

extension PropertyDefinition: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "propertyDefinition"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns: String, ColumnExpression {
        case id, name, type, optionsJSON, sortOrder, isDefault, defaultFieldKey, isVisible, dateModified
    }
}

// MARK: - Option mutation errors

/// Surfaced by `AppDatabase.renamePropertyOption` and `deletePropertyOption`
/// when the requested mutation can't be performed safely. Callers decide
/// whether to abort, prompt the user for a replacement, or log + skip.
public enum PropertyOptionError: Error, Equatable {
    /// No PropertyDefinition with the given id.
    case propertyNotFound
    /// The target option value isn't present in the property's `options` list.
    case optionNotFound
    /// The option being deleted is in active use by `count` rows and the
    /// caller didn't supply a `replaceWith` value to migrate them to.
    case optionInUse(count: Int)
    /// `replaceWith` was supplied but doesn't match any other existing option.
    case replacementNotFound(String)
    /// The rename target is already an existing option on the same property.
    /// Renaming would create two options with the same value and break the
    /// single-select identity assumption used by pickers and lookups.
    case duplicateValue(String)
    /// Option mutations only apply to singleSelect properties. multiSelect
    /// values are JSON-encoded arrays in `propertyValue.value` so a scalar
    /// equality bulk-update would silently miss in-use values; full multi-
    /// select rename support is intentionally deferred.
    case unsupportedPropertyType
}
