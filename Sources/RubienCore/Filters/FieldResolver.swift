import Foundation

public enum ResolvedValue: Hashable, Sendable {
    case text(String?)
    case number(Double?)
    case date(Date?)
    /// Canonical key: enum rawValue for built-ins, option value for custom selects.
    case singleSelect(String?)
    /// Empty set means unset, not "empty string member".
    case multiSelect(Set<String>)
    case checkbox(Bool)
}

extension ResolvedValue {
    public var isEmpty: Bool {
        switch self {
        case .text(let s):         return (s?.isEmpty ?? true)
        case .number(let n):       return n == nil
        case .date(let d):         return d == nil
        case .singleSelect(let s): return (s?.isEmpty ?? true)
        case .multiSelect(let set): return set.isEmpty
        case .checkbox:            return false
        }
    }
}

public enum FieldResolver {
    public static func resolve(
        target: FieldTarget,
        row: Reference,
        tagMap: [Int64: [Tag]],
        propertyValueMap: [Int64: [Int64: String]],
        propertyDefs: [PropertyDefinition]
    ) -> ResolvedValue {
        switch target {
        case .builtin(let column):
            return resolveBuiltin(column, row: row, tagMap: tagMap)
        case .custom(let propertyId):
            return resolveCustom(
                propertyId: propertyId,
                row: row,
                propertyValueMap: propertyValueMap,
                propertyDefs: propertyDefs
            )
        }
    }

    private static func resolveBuiltin(_ column: ColumnIdentifier, row: Reference, tagMap: [Int64: [Tag]]) -> ResolvedValue {
        switch column {
        case .title:         return .text(row.title)
        case .authors:       return .text(row.authorsNormalized.isEmpty ? nil : row.authorsNormalized)
        case .journal:       return .text(row.journal)
        case .doi:           return .text(row.doi)
        case .publisher:     return .text(row.publisher)
        case .volume:        return .text(row.volume)
        case .issue:         return .text(row.issue)
        case .pages:         return .text(row.pages)
        case .year:          return .number(row.year.map(Double.init))
        case .dateAdded:     return .date(row.dateAdded)
        case .dateModified:  return .date(row.dateModified)
        case .referenceType: return .singleSelect(row.referenceType.rawValue)
        case .readingStatus: return .singleSelect(row.readingStatus.rawValue)
        case .priority:      return .singleSelect(String(row.priority.rawValue))
        case .tags:
            guard let rid = row.id else { return .multiSelect([]) }
            let ids = tagMap[rid]?.compactMap { $0.id.map(String.init) } ?? []
            return .multiSelect(Set(ids))
        case .pdfAttached:
            return .checkbox(!(row.pdfPath?.isEmpty ?? true))
        }
    }

    private static func resolveCustom(
        propertyId: Int64,
        row: Reference,
        propertyValueMap: [Int64: [Int64: String]],
        propertyDefs: [PropertyDefinition]
    ) -> ResolvedValue {
        guard let def = propertyDefs.first(where: { $0.id == propertyId }) else {
            return .text(nil)
        }
        guard let rid = row.id else { return emptyValue(for: def.type) }
        let raw = propertyValueMap[rid]?[propertyId]
        switch def.type {
        case .string, .url:
            return .text(raw?.isEmpty == true ? nil : raw)
        case .number:
            return .number(raw.flatMap(Double.init))
        case .date:
            return .date(raw.flatMap(parseDate))
        case .singleSelect:
            return .singleSelect(raw?.isEmpty == true ? nil : raw)
        case .multiSelect:
            let keys = raw
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
                ?? []
            return .multiSelect(Set(keys))
        case .checkbox:
            return .checkbox(raw == "true" || raw == "1")
        }
    }

    private static func emptyValue(for type: PropertyType) -> ResolvedValue {
        switch type {
        case .string, .url:   return .text(nil)
        case .number:         return .number(nil)
        case .date:           return .date(nil)
        case .singleSelect:   return .singleSelect(nil)
        case .multiSelect:    return .multiSelect([])
        case .checkbox:       return .checkbox(false)
        }
    }

    /// Tries ISO-8601 with fractional seconds first, then without.
    private static let isoFormatters: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()

    private static func parseDate(_ raw: String) -> Date? {
        for formatter in isoFormatters {
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
