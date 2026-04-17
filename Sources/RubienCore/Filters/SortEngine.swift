import Foundation

public enum SortEngine {
    /// Multi-column stable sort: first sort is primary, subsequent sorts break
    /// ties. Nulls sort last regardless of direction. When all user-specified
    /// sorts are equal, `reference.id` is the final deterministic tiebreaker.
    /// Sorts targeting `.multiSelect` kinds are silently dropped before sorting
    /// (per spec — disallowed in UI, defensive here). If all sorts are dropped,
    /// input order is preserved.
    public static func apply(
        _ rows: [Reference],
        sorts: [ViewSort],
        context: PipelineContext
    ) -> [Reference] {
        let effectiveSorts = sorts.filter { $0.target.valueKind(propertyDefs: context.propertyDefs) != .multiSelect }
        guard !effectiveSorts.isEmpty else { return rows }
        return rows.sorted { a, b in
            for sort in effectiveSorts {
                switch compare(a, b, sort: sort, context: context) {
                case .orderedAscending:  return sort.ascending
                case .orderedDescending: return !sort.ascending
                case .orderedSame:       continue
                }
            }
            return (a.id ?? 0) < (b.id ?? 0)
        }
    }

    private static func compare(
        _ a: Reference,
        _ b: Reference,
        sort: ViewSort,
        context: PipelineContext
    ) -> ComparisonResult {
        let va = FieldResolver.resolve(
            target: sort.target, row: a,
            tagMap: context.tagMap, propertyValueMap: context.propertyValueMap, propertyDefs: context.propertyDefs
        )
        let vb = FieldResolver.resolve(
            target: sort.target, row: b,
            tagMap: context.tagMap, propertyValueMap: context.propertyValueMap, propertyDefs: context.propertyDefs
        )
        return compareResolved(va, vb, ascending: sort.ascending)
    }

    private static func compareResolved(_ a: ResolvedValue, _ b: ResolvedValue, ascending: Bool) -> ComparisonResult {
        switch (a, b) {
        case (.text(let x), .text(let y)):
            return nullsLast(x, y, ascending: ascending) { $0.localizedStandardCompare($1) }
        case (.number(let x), .number(let y)):
            return nullsLast(x, y, ascending: ascending, comparator: threeWay)
        case (.date(let x), .date(let y)):
            return nullsLast(x, y, ascending: ascending, comparator: threeWay)
        case (.singleSelect(let x), .singleSelect(let y)):
            return nullsLast(x, y, ascending: ascending) { $0.localizedStandardCompare($1) }
        case (.checkbox(let x), .checkbox(let y)):
            if x == y { return .orderedSame }
            return x ? .orderedDescending : .orderedAscending  // false < true
        case (.multiSelect, .multiSelect):
            return .orderedSame  // multi-select sorting disallowed
        default:
            return .orderedSame
        }
    }

    /// Runs `comparator` when both values are non-nil. When only one is nil,
    /// pre-flips the result so the null lands at the end *after* the caller's
    /// ascending/descending flip.
    private static func nullsLast<T>(
        _ a: T?,
        _ b: T?,
        ascending: Bool,
        comparator: (T, T) -> ComparisonResult
    ) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _):   return ascending ? .orderedDescending : .orderedAscending
        case (_, nil):   return ascending ? .orderedAscending : .orderedDescending
        case (let x?, let y?): return comparator(x, y)
        default: return .orderedSame
        }
    }

    private static func threeWay<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        if a < b { return .orderedAscending }
        if a > b { return .orderedDescending }
        return .orderedSame
    }
}
