import SwiftUI
import RubienCore

struct GroupEditorPopover: View {
    @Binding var groupBy: GroupConfig?
    let propertyDefs: [PropertyDefinition]
    let currentBuckets: [GroupBucket]

    private static let reorderRowHeight: CGFloat = 28
    private static let reorderListMaxHeight: CGFloat = 200

    var body: some View {
        // Grouping targets exclude text and number per spec.
        let options = FieldTarget.selectableOptions(propertyDefs: propertyDefs, excluding: [.text, .number])
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content(options: options)
            if let config = groupBy {
                if !currentBuckets.isEmpty {
                    Divider()
                    reorderList(config: config)
                }
                Divider()
                removeButton
            }
        }
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Text("Group")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func content(options: [FieldTargetOption]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldPicker(options: options)
            if let config = groupBy {
                if config.target.valueKind(propertyDefs: propertyDefs) == .date {
                    dateBinPicker(current: config)
                }
                if config.target.knownSingleSelectKeys(propertyDefs: propertyDefs) != nil {
                    showEmptyToggle(current: config)
                }
            }
        }
        .padding(14)
    }

    private func fieldPicker(options: [FieldTargetOption]) -> some View {
        HStack {
            Text("Field")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option.label) {
                        setTarget(option.target)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentFieldLabel(options: options))
                        .font(.system(size: 12))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private func dateBinPicker(current: GroupConfig) -> some View {
        HStack {
            Text("Bucket")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Picker("", selection: Binding(
                get: { current.dateBin ?? .month },
                set: { newBin in
                    var updated = current
                    updated.dateBin = newBin
                    groupBy = updated
                }
            )) {
                Text("Week").tag(DateBin.week)
                Text("Month").tag(DateBin.month)
                Text("Year").tag(DateBin.year)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Drag-reorderable list of the current group keys in the order they
    /// render. Dragging writes `config.customOrder`; unknown keys that appear
    /// later (new tags, new options) slot into natural order at the end until
    /// the user drags them.
    private func reorderList(config: GroupConfig) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Group order")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if config.customOrder != nil {
                    Button("Reset") {
                        var updated = config
                        updated.customOrder = nil
                        groupBy = updated
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
            List {
                ForEach(currentBuckets, id: \.key) { bucket in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text(bucket.label)
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(bucket.references.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .onMove { source, destination in
                    var keys = currentBuckets.map(\.key)
                    keys.move(fromOffsets: source, toOffset: destination)
                    var updated = config
                    updated.customOrder = keys
                    groupBy = updated
                }
            }
            .listStyle(.plain)
            .frame(height: min(CGFloat(currentBuckets.count) * Self.reorderRowHeight + 12, Self.reorderListMaxHeight))
        }
    }

    private func showEmptyToggle(current: GroupConfig) -> some View {
        Toggle(isOn: Binding(
            get: { current.showEmpty },
            set: { newValue in
                var updated = current
                updated.showEmpty = newValue
                groupBy = updated
            }
        )) {
            Text("Show empty groups")
                .font(.system(size: 12))
        }
        .toggleStyle(.checkbox)
    }

    private var removeButton: some View {
        Button("Remove grouping") { groupBy = nil }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func currentFieldLabel(options: [FieldTargetOption]) -> String {
        guard let config = groupBy else { return "Select field…" }
        return config.target.displayLabel(propertyDefs: propertyDefs)
    }

    private func setTarget(_ target: FieldTarget) {
        let isDate = target.valueKind(propertyDefs: propertyDefs) == .date
        var updated = groupBy ?? GroupConfig(target: target)
        updated.target = target
        updated.dateBin = isDate ? (updated.dateBin ?? .month) : nil
        groupBy = updated
    }
}
