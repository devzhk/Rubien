import Foundation

/// Shared inputs for the filter/sort/group engines. `now` is injectable so
/// relative date presets are deterministic in tests and stable across a
/// single render pass.
///
/// `pdfAttachedRefIds` carries which Reference rows have a `pdfCache` row on
/// this device — populated by the caller (typically with one query) and read
/// by `FieldResolver.resolveBuiltin(.pdfAttached, …)`. Post-B8 PDF presence
/// is per-device, so it can't live on the Reference value type.
public struct PipelineContext: Sendable {
    public let tagMap: [Int64: [Tag]]
    public let propertyValueMap: [Int64: [Int64: String]]
    public let propertyDefs: [PropertyDefinition]
    public let pdfAttachedRefIds: Set<Int64>
    public let now: Date

    public init(
        tagMap: [Int64: [Tag]] = [:],
        propertyValueMap: [Int64: [Int64: String]] = [:],
        propertyDefs: [PropertyDefinition] = [],
        pdfAttachedRefIds: Set<Int64> = [],
        now: Date = Date()
    ) {
        self.tagMap = tagMap
        self.propertyValueMap = propertyValueMap
        self.propertyDefs = propertyDefs
        self.pdfAttachedRefIds = pdfAttachedRefIds
        self.now = now
    }
}

public enum FilterEngine {
    public static func apply(
        _ rows: [Reference],
        filters: [ViewFilter],
        context: PipelineContext
    ) -> [Reference] {
        guard !filters.isEmpty else { return rows }
        return rows.filter { row in
            filters.allSatisfy { evaluate($0, row: row, context: context) }
        }
    }

    public static func evaluate(
        _ filter: ViewFilter,
        row: Reference,
        context: PipelineContext
    ) -> Bool {
        let resolved = FieldResolver.resolve(
            target: filter.target,
            row: row,
            tagMap: context.tagMap,
            propertyValueMap: context.propertyValueMap,
            propertyDefs: context.propertyDefs,
            pdfAttachedRefIds: context.pdfAttachedRefIds
        )

        switch filter.op {
        case .isEmpty:     return resolved.isEmpty
        case .isNotEmpty:  return !resolved.isEmpty
        default: break
        }

        switch resolved {
        case .text(let value):            return evaluateText(value, op: filter.op, filterValue: filter.value)
        case .number(let value):          return evaluateNumber(value, op: filter.op, filterValue: filter.value)
        case .date(let value):            return evaluateDate(value, op: filter.op, filterValue: filter.value, now: context.now)
        case .singleSelect(let value):    return evaluateSingleSelect(value, op: filter.op, filterValue: filter.value)
        case .multiSelect(let values):    return evaluateMultiSelect(values, op: filter.op, filterValue: filter.value)
        case .checkbox(let value):        return evaluateCheckbox(value, op: filter.op)
        }
    }


    private static func evaluateText(_ value: String?, op: FilterOperator, filterValue: FilterValue) -> Bool {
        guard let value else { return false }
        guard case .text(let query) = filterValue else { return false }
        switch op {
        case .equals:        return value.localizedCaseInsensitiveCompare(query) == .orderedSame
        case .notEquals:     return value.localizedCaseInsensitiveCompare(query) != .orderedSame
        case .contains:      return value.localizedCaseInsensitiveContains(query)
        case .notContains:   return !value.localizedCaseInsensitiveContains(query)
        case .startsWith:    return value.lowercased().hasPrefix(query.lowercased())
        case .endsWith:      return value.lowercased().hasSuffix(query.lowercased())
        default:             return false
        }
    }

    private static func evaluateNumber(_ value: Double?, op: FilterOperator, filterValue: FilterValue) -> Bool {
        guard let value else { return false }
        guard case .number(let query) = filterValue else { return false }
        switch op {
        case .equals:          return value == query
        case .notEquals:       return value != query
        case .greaterThan:     return value > query
        case .lessThan:        return value < query
        case .greaterOrEqual:  return value >= query
        case .lessOrEqual:     return value <= query
        default:               return false
        }
    }

    private static func evaluateDate(_ value: Date?, op: FilterOperator, filterValue: FilterValue, now: Date) -> Bool {
        guard let value else { return false }
        if op == .isWithin {
            guard case .datePreset(let preset) = filterValue else { return false }
            let interval = DatePresetResolver.interval(for: preset, reference: now)
            return interval.contains(value)
        }
        guard case .date(let query) = filterValue else { return false }
        switch op {
        case .equals:          return Calendar.current.isDate(value, inSameDayAs: query)
        case .notEquals:       return !Calendar.current.isDate(value, inSameDayAs: query)
        case .greaterThan:     return value > query
        case .lessThan:        return value < query
        case .greaterOrEqual:  return value >= query
        case .lessOrEqual:     return value <= query
        default:               return false
        }
    }

    private static func evaluateSingleSelect(_ value: String?, op: FilterOperator, filterValue: FilterValue) -> Bool {
        guard let value else { return false }
        switch op {
        case .equals, .notEquals:
            guard case .selectKeys(let keys) = filterValue, let query = keys.first else { return false }
            let matches = value == query
            return op == .equals ? matches : !matches
        case .isAnyOf, .isNoneOf:
            guard case .selectKeys(let keys) = filterValue else { return false }
            let matches = keys.contains(value)
            return op == .isAnyOf ? matches : !matches
        default:
            return false
        }
    }

    private static func evaluateMultiSelect(_ values: Set<String>, op: FilterOperator, filterValue: FilterValue) -> Bool {
        guard case .selectKeys(let keys) = filterValue else { return false }
        let query = Set(keys)
        switch op {
        case .contains:
            guard let needle = keys.first else { return false }
            return values.contains(needle)
        case .notContains:
            guard let needle = keys.first else { return false }
            return !values.contains(needle)
        case .containsAnyOf:   return !query.isEmpty && !values.isDisjoint(with: query)
        case .containsNoneOf:  return values.isDisjoint(with: query)
        case .containsAllOf:   return !query.isEmpty && query.isSubset(of: values)
        default:               return false
        }
    }

    private static func evaluateCheckbox(_ value: Bool, op: FilterOperator) -> Bool {
        switch op {
        case .isChecked:   return value
        case .isUnchecked: return !value
        default:           return false
        }
    }
}
