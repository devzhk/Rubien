import SwiftUI

/// Wrapping layout for chip-like children: packs subviews left-to-right and
/// starts a new row when the next subview would overflow the proposed width.
struct FlowLayout: Layout {
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
