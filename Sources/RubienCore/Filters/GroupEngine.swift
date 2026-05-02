import Foundation

public struct GroupBucket: Hashable, Sendable {
    public let key: String
    public let label: String
    public let references: [Reference]

    public init(key: String, label: String, references: [Reference]) {
        self.key = key
        self.label = label
        self.references = references
    }
}

public enum GroupEngine {
    /// Groups an already-filtered-and-sorted row set by the configured target.
    /// Row order *within* each bucket matches input order — the sort engine
    /// should run first. Multi-select grouping places a ref in every bucket it
    /// has a key for.
    public static func apply(
        _ rows: [Reference],
        config: GroupConfig,
        context: PipelineContext
    ) -> [GroupBucket] {
        var orderedKeys: [String] = []
        var labels: [String: String] = [:]
        var buckets: [String: [Reference]] = [:]

        for row in rows {
            let resolved = FieldResolver.resolve(
                target: config.target, row: row,
                tagMap: context.tagMap, propertyValueMap: context.propertyValueMap, propertyDefs: context.propertyDefs,
                pdfAttachedRefIds: context.pdfAttachedRefIds
            )
            for (key, label) in keyLabelPairs(for: resolved, config: config) {
                if buckets[key] == nil {
                    orderedKeys.append(key)
                    labels[key] = label
                }
                buckets[key, default: []].append(row)
            }
        }

        // Optionally seed empty buckets for every known single-select option
        // so users see all categories, not just the ones that happen to have
        // members. Only meaningful when the target has a finite option set.
        if config.showEmpty, let knownKeys = config.target.knownSingleSelectKeys(propertyDefs: context.propertyDefs) {
            for key in knownKeys where buckets[key] == nil {
                orderedKeys.append(key)
                labels[key] = readableLabel(forKey: key, target: config.target)
                buckets[key] = []
            }
        }

        let sortedKeys = reorder(orderedKeys, customOrder: config.customOrder)
        return sortedKeys.map { key in
            GroupBucket(key: key, label: labels[key] ?? key, references: buckets[key] ?? [])
        }
    }

    private static func keyLabelPairs(for value: ResolvedValue, config: GroupConfig) -> [(key: String, label: String)] {
        switch value {
        case .text(let s):
            return s.map { [($0, $0)] } ?? [emptyPair]
        case .singleSelect(let s):
            guard let key = s else { return [emptyPair] }
            return [(key, readableLabel(forKey: key, target: config.target))]
        case .number(let n):
            guard let n else { return [emptyPair] }
            let formatted = n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
            return [(formatted, formatted)]
        case .date(let d):
            guard let d else { return [emptyPair] }
            return [dateKeyLabel(d, bin: config.dateBin ?? .month)]
        case .multiSelect(let set):
            if set.isEmpty { return [emptyPair] }
            return set.map { key in (key, readableLabel(forKey: key, target: config.target)) }
                .sorted { $0.0 < $1.0 }
        case .checkbox(let b):
            return [(b ? "true" : "false", b ? "Checked" : "Unchecked")]
        }
    }

    /// Maps a raw resolver key to a human-readable label for group headers.
    /// Post-Phase-2 the `readingStatus` value IS its own label (no enum
    /// indirection), so most targets just pass the key through; only `tags`
    /// has a special note.
    private static func readableLabel(forKey key: String, target: FieldTarget) -> String {
        switch target {
        case .builtin(.tags):
            // Tag keys are stringified ids; caller should resolve via tagMap
            // for display. Fall back to the key itself (bucket will show an
            // id number, which is legible enough if the tagMap lookup fails).
            return key
        default:
            return key
        }
    }

    private static let emptyPair: (key: String, label: String) = ("__empty__", "(Empty)")

    private static let weekFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        return f
    }()

    private static let monthKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static let monthLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f
    }()

    private static func dateKeyLabel(_ date: Date, bin: DateBin) -> (key: String, label: String) {
        switch bin {
        case .week:
            let comps = Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            let year = comps.yearForWeekOfYear ?? 0
            let week = comps.weekOfYear ?? 0
            let key = String(format: "%04d-W%02d", year, week)
            return (key, key)
        case .month:
            return (monthKeyFormatter.string(from: date), monthLabelFormatter.string(from: date))
        case .year:
            let key = yearFormatter.string(from: date)
            return (key, key)
        }
    }

    /// Applies `customOrder` if present: keys listed in `customOrder` come
    /// first (in the saved order), unknown keys follow in alphabetical order.
    private static func reorder(_ keys: [String], customOrder: [String]?) -> [String] {
        guard let customOrder, !customOrder.isEmpty else {
            return keys.sorted()
        }
        let known = Set(keys)
        let custom = Set(customOrder)
        var ordered = customOrder.filter(known.contains)
        let remaining = keys.filter { !custom.contains($0) }.sorted()
        ordered.append(contentsOf: remaining)
        return ordered
    }
}
