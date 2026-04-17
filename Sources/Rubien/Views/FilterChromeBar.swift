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
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .medium))
                    Text("Add filter")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2))
                )
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

// MARK: - Simple wrapping layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let (rows, _) = layoutRows(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * spacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        let (rows, indicesByRow) = layoutRows(subviews: subviews, maxWidth: maxWidth)
        var y = bounds.minY
        for (rowIdx, row) in rows.enumerated() {
            var x = bounds.minX
            for subIdx in indicesByRow[rowIdx] {
                let size = subviews[subIdx].sizeThatFits(.unspecified)
                subviews[subIdx].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func layoutRows(subviews: Subviews, maxWidth: CGFloat) -> (rows: [CGSize], indicesByRow: [[Int]]) {
        let proposal = ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil)
        var rows: [CGSize] = []
        var indicesByRow: [[Int]] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0
        var currentIndices: [Int] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(proposal)
            let needed = currentIndices.isEmpty ? size.width : currentWidth + spacing + size.width
            if needed > maxWidth && !currentIndices.isEmpty {
                rows.append(CGSize(width: currentWidth, height: currentHeight))
                indicesByRow.append(currentIndices)
                currentWidth = min(size.width, maxWidth)
                currentHeight = size.height
                currentIndices = [index]
            } else {
                currentWidth = min(needed, maxWidth)
                currentHeight = max(currentHeight, size.height)
                currentIndices.append(index)
            }
        }
        if !currentIndices.isEmpty {
            rows.append(CGSize(width: currentWidth, height: currentHeight))
            indicesByRow.append(currentIndices)
        }
        return (rows, indicesByRow)
    }
}
