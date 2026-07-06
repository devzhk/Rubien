#if os(macOS)
import SwiftUI

/// A floating panel with a leading drag-to-resize edge. Owns the live drag offset
/// locally so dragging only re-renders this small view — not the enclosing view,
/// whose huge `body` would otherwise re-evaluate every drag frame and make the
/// resize stutter. Commits the new width to the binding on drag end.
///
/// Used for the library's details card and the readers' assistant card — overlay
/// it on the content with `.overlay(alignment: .trailing)`.
struct FloatingPanel<Content: View>: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    @ViewBuilder var content: () -> Content

    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        content()
            .frame(width: min(max(width - dragOffset, range.lowerBound), range.upperBound))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .updating($dragOffset) { value, state, _ in
                                state = value.translation.width
                            }
                            .onEnded { value in
                                width = min(max(width - value.translation.width, range.lowerBound), range.upperBound)
                            }
                    )
            }
    }
}
#endif
