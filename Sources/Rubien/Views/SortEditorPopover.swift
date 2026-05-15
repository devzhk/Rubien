#if os(macOS)
import SwiftUI
import RubienCore

struct SortEditorPopover: View {
    @Binding var sorts: [ViewSort]
    let propertyDefs: [PropertyDefinition]

    var body: some View {
        let options = FieldTarget.selectableOptions(propertyDefs: propertyDefs, excluding: [.multiSelect])
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if sorts.isEmpty {
                emptyState
            } else {
                sortList(options: options)
            }
            Divider()
            addButton(options: options)
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Sort")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !sorts.isEmpty {
                Button("Clear all") { sorts.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        Text("No sort applied")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func sortList(options: [FieldTargetOption]) -> some View {
        List {
            ForEach(Array(sorts.enumerated()), id: \.element.target) { index, sort in
                sortRow(sort: sort, at: index, options: options)
            }
            .onMove(perform: moveSort)
        }
        .listStyle(.plain)
        .frame(height: min(CGFloat(sorts.count) * 32 + 12, 240))
    }

    @ViewBuilder
    private func sortRow(sort: ViewSort, at index: Int, options: [FieldTargetOption]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option.label) {
                        if index < sorts.count {
                            sorts[index].target = option.target
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(sort.target.displayLabel(propertyDefs: propertyDefs))
                        .font(.system(size: 12))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                if index < sorts.count {
                    sorts[index].ascending.toggle()
                }
            } label: {
                Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(sort.ascending ? "Ascending" : "Descending")

            Button {
                sorts.remove(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
        }
    }

    private func addButton(options: [FieldTargetOption]) -> some View {
        let canAdd = canAddSort(options: options)
        return Button {
            addSort(options: options)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                Text("Add sort")
                    .font(.system(size: 12))
            }
            .foregroundStyle(canAdd ? .secondary : .tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
    }

    private func canAddSort(options: [FieldTargetOption]) -> Bool {
        let used = Set(sorts.map(\.target))
        return options.contains { !used.contains($0.target) }
    }

    private func moveSort(from offsets: IndexSet, to destination: Int) {
        sorts.move(fromOffsets: offsets, toOffset: destination)
    }

    private func addSort(options: [FieldTargetOption]) {
        let used = Set(sorts.map(\.target))
        let available = options.first { !used.contains($0.target) }?.target ?? .builtin(.dateAdded)
        sorts.append(ViewSort(target: available, ascending: false))
    }
}
#endif
