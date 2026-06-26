#if os(macOS)
import SwiftUI
import RubienCore

struct FilterChromeBar: View {
    @Binding var filters: [ViewFilter]
    let tags: [Tag]
    let propertyDefs: [PropertyDefinition]

    @State private var showAdd: Bool = false

    var body: some View {
        FlowLayout(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 5)

            ForEach(Array(filters.enumerated()), id: \.offset) { index, filter in
                FilterChip(
                    filter: filter,
                    tags: tags,
                    propertyDefs: propertyDefs,
                    onUpdate: { updated in
                        if index < filters.count { filters[index] = updated }
                    },
                    onRemove: { filters.remove(at: index) }
                )
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

}

/// A single applied-filter chip. Owns its hover + editing state so it highlights
/// on hover (matching the chrome bar's other controls) and opens its editor
/// popover on click.
private struct FilterChip: View {
    let filter: ViewFilter
    let tags: [Tag]
    let propertyDefs: [PropertyDefinition]
    let onUpdate: (ViewFilter) -> Void
    let onRemove: () -> Void

    @State private var isHovered = false
    @State private var isEditing = false

    var body: some View {
        Button {
            isEditing = true
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
                    onRemove()
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
                    .fill(Color.accentColor.opacity(isHovered ? 0.16 : 0.08))
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .popover(isPresented: $isEditing) {
            FilterEditorPopover(
                initial: filter,
                tags: tags,
                propertyDefs: propertyDefs,
                onCommit: { updated in
                    onUpdate(updated)
                    isEditing = false
                },
                onCancel: { isEditing = false }
            )
        }
    }
}
#endif
