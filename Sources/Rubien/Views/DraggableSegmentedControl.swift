#if os(macOS)
import SwiftUI

enum ReaderSegmentedControlMetrics {
    static let activeHighlightOpacity = 0.12
    static let hoverHighlightOpacity = 0.07

    static func highlightOpacity(isActive: Bool, isHovered: Bool) -> Double {
        if isActive { return activeHighlightOpacity }
        if isHovered { return hoverHighlightOpacity }
        return 0
    }
}

struct DraggableSegmentedControl<T: Hashable>: View {
    @Binding var selection: T
    let items: [(label: String, value: T)]

    @State private var dragIndex: Int?
    @State private var hoverIndex: Int?

    private var selectedIndex: Int {
        items.firstIndex(where: { $0.value == selection }) ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            let segmentWidth = geo.size.width / CGFloat(items.count)
            let activeIndex = dragIndex ?? selectedIndex

            ZStack(alignment: .leading) {
                if let hoverIndex, hoverIndex != activeIndex {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(ReaderSegmentedControlMetrics.hoverHighlightOpacity))
                        .frame(width: segmentWidth - 4, height: 24)
                        .offset(x: CGFloat(hoverIndex) * segmentWidth + 2)
                        .animation(.easeInOut(duration: 0.14), value: hoverIndex)
                }

                // Sliding indicator
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(ReaderSegmentedControlMetrics.activeHighlightOpacity))
                    .frame(width: segmentWidth - 4, height: 24)
                    .offset(x: CGFloat(activeIndex) * segmentWidth + 2)
                    .animation(.easeInOut(duration: 0.2), value: activeIndex)

                // Labels. Narrow hosts (the reader sidebars go down to 200 pt
                // with four segments) shrink the text instead of wrapping or
                // overlapping neighbors.
                HStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { index in
                        let isActive = activeIndex == index
                        let isHovered = hoverIndex == index
                        Text(items[index].label)
                            .font(.caption)
                            .fontWeight(isActive || isHovered ? .medium : .regular)
                            .foregroundStyle(isActive ? Color.accentColor : (isHovered ? .primary : .secondary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 2)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                withAnimation(.easeOut(duration: 0.12)) {
                                    if hovering {
                                        hoverIndex = index
                                    } else if hoverIndex == index {
                                        hoverIndex = nil
                                    }
                                }
                            }
                            .animation(.easeInOut(duration: 0.15), value: activeIndex)
                            .animation(.easeInOut(duration: 0.12), value: hoverIndex)
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = Int(value.location.x / segmentWidth)
                        let clamped = max(0, min(items.count - 1, index))
                        if dragIndex != clamped {
                            dragIndex = clamped
                        }
                    }
                    .onEnded { _ in
                        if let idx = dragIndex {
                            selection = items[idx].value
                        }
                        dragIndex = nil
                    }
            )
        }
        .frame(height: 28)
    }
}
#endif
