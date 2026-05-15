import SwiftUI
import RubienCore

struct FilterChromeBar: View {
    @Binding var filters: [ViewFilter]
    let tags: [Tag]
    let propertyDefs: [PropertyDefinition]

    @State private var editingIndex: Int? = nil
    @State private var showAdd: Bool = false

    var body: some View {
        FlowLayout(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 5)

            ForEach(Array(filters.enumerated()), id: \.offset) { index, filter in
                pill(for: filter, index: index)
            }

            Button {
                showAdd = true
            } label: {
                ChromeBarPill(iconName: "plus", label: "Add filter")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showAdd) {
                FilterEditorPopover(
                    tags: tags,
                    propertyDefs: propertyDefs,
                    onCommit: { newFilter in
                        filters.append(newFilter)
                        showAdd = false
                    },
                    onCancel: { showAdd = false }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func pill(for filter: ViewFilter, index: Int) -> some View {
        let isEditing = editingIndex == index
        Button {
            editingIndex = index
        } label: {
            HStack(spacing: 4) {
                Text(filter.target.displayLabel(propertyDefs: propertyDefs))
                    .font(.system(size: 10, weight: .medium))
                Text(filter.op.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(filter.value.displayLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Button {
                    filters.remove(at: index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(
            get: { isEditing },
            set: { if !$0 { editingIndex = nil } }
        )) {
            FilterEditorPopover(
                initial: filter,
                tags: tags,
                propertyDefs: propertyDefs,
                onCommit: { updated in
                    if index < filters.count {
                        filters[index] = updated
                    }
                    editingIndex = nil
                },
                onCancel: { editingIndex = nil }
            )
        }
    }

}
