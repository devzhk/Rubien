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
