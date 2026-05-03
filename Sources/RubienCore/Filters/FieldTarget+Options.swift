import Foundation

public struct FieldTargetOption: Hashable, Sendable {
    public let target: FieldTarget
    public let label: String

    public init(target: FieldTarget, label: String) {
        self.target = target
        self.label = label
    }
}

extension FieldTarget {
    /// Enumerable option keys for single-select targets, `nil` for targets
    /// without a known finite set (text, multi-select, date, etc.). Used by
    /// `GroupEngine` to emit empty buckets when `GroupConfig.showEmpty` is on.
    public func knownSingleSelectKeys(propertyDefs: [PropertyDefinition]) -> [String]? {
        switch self {
        case .builtin(.readingStatus):
            // Status is user-extensible post-Phase-2: read the live option
            // set from the seeded Status PropertyDefinition (defaultFieldKey
            // == "readingStatus") so user-added values appear in filters/groups.
            // Falls back to the 4 built-ins if the def is missing for any reason.
            if let def = propertyDefs.first(forFieldKey: PropertyDefinition.readingStatusFieldKey) {
                return def.options.map(\.value)
            }
            return ReadingStatus.builtIn
        case .builtin(.referenceType):
            return ReferenceType.allCases.map(\.rawValue)
        case .custom(let id):
            guard let def = propertyDefs.first(where: { $0.id == id }),
                  def.type == .singleSelect else { return nil }
            return def.options.map(\.value)
        default:
            return nil
        }
    }

    /// The flat list of targets offered in filter/sort/group pickers. Built-in
    /// columns come first in a stable order; visible custom properties follow
    /// in their user-defined `sortOrder`. `excluding` lets callers drop value
    /// kinds that don't apply (e.g. sort excludes `.multiSelect`).
    public static func selectableOptions(
        propertyDefs: [PropertyDefinition],
        excluding excludedKinds: Set<FieldValueKind> = []
    ) -> [FieldTargetOption] {
        let builtins: [ColumnIdentifier] = [
            .title, .authors, .journal, .year, .referenceType,
            .tags, .readingStatus,
            .dateAdded, .dateModified,
            .doi, .publisher, .volume, .issue, .pages, .pdfAttached,
        ]
        var options: [FieldTargetOption] = builtins
            .filter { !excludedKinds.contains($0.valueKind) }
            .map { FieldTargetOption(target: .builtin($0), label: $0.header) }
        let customs = propertyDefs
            .filter {
                !$0.isDefault && $0.isVisible && $0.id != nil &&
                !excludedKinds.contains($0.type.valueKind)
            }
            .sorted { $0.sortOrder < $1.sortOrder }
        options.append(contentsOf: customs.map {
            FieldTargetOption(target: .custom($0.id ?? 0), label: $0.name)
        })
        return options
    }
}
