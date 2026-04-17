import Foundation

public enum FieldValueKind: String, Hashable, Sendable {
    case text
    case number
    case date
    case singleSelect
    case multiSelect
    case checkbox
}

extension ColumnIdentifier {
    public var valueKind: FieldValueKind {
        switch self {
        case .title, .authors, .journal, .doi, .publisher, .volume, .issue, .pages:
            return .text
        case .year:
            return .number
        case .dateAdded, .dateModified:
            return .date
        case .referenceType, .readingStatus:
            return .singleSelect
        case .tags:
            return .multiSelect
        case .pdfAttached:
            return .checkbox
        }
    }
}

extension PropertyType {
    public var valueKind: FieldValueKind {
        switch self {
        case .string, .url:   return .text
        case .number:         return .number
        case .date:           return .date
        case .singleSelect:   return .singleSelect
        case .multiSelect:    return .multiSelect
        case .checkbox:       return .checkbox
        }
    }
}

extension FieldTarget {
    public func valueKind(propertyDefs: [PropertyDefinition]) -> FieldValueKind {
        switch self {
        case .builtin(let column): return column.valueKind
        case .custom(let id):      return propertyDefs.first(where: { $0.id == id })?.type.valueKind ?? .text
        }
    }
}
