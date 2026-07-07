#if os(macOS)
import AppKit
import SwiftUI

enum ReaderResizeMetrics {
    static let hitTargetWidth: CGFloat = 24
    static let showsVisualHandle = false
    static let usesExplicitResizeCursor = true
    static let usesNativeResizeCursorTracking = true
}

enum FloatingPanelMetrics {
    static let resizeHitTargetWidth = ReaderResizeMetrics.hitTargetWidth

    static func width(
        afterLeadingEdgeTranslation translation: CGFloat,
        from width: CGFloat,
        in range: ClosedRange<CGFloat>
    ) -> CGFloat {
        min(max(width - translation, range.lowerBound), range.upperBound)
    }
}

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

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        content()
            .frame(width: FloatingPanelMetrics.width(
                afterLeadingEdgeTranslation: dragOffset,
                from: width,
                in: range
            ))
            .overlay(alignment: .leading) {
                ReaderResizeHandle(
                    onDragChanged: { translation in
                        dragOffset = translation
                    },
                    onDragEnded: { translation in
                        width = FloatingPanelMetrics.width(
                            afterLeadingEdgeTranslation: translation,
                            from: width,
                            in: range
                        )
                        dragOffset = 0
                    }
                )
                    .frame(width: FloatingPanelMetrics.resizeHitTargetWidth)
                    .frame(maxHeight: .infinity)
                    .offset(x: -FloatingPanelMetrics.resizeHitTargetWidth / 2)
            }
    }
}

struct ReaderResizeHandle: NSViewRepresentable {
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderResizeHandleView {
        let view = ReaderResizeHandleView()
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: ReaderResizeHandleView, context: Context) {
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

final class ReaderResizeHandleView: NSView {
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: ((CGFloat) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var dragStartX: CGFloat?

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        let translation = event.locationInWindow.x - dragStartX
        onDragChanged?(translation)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStartX else { return }
        let translation = event.locationInWindow.x - dragStartX
        onDragEnded?(translation)
        self.dragStartX = nil
    }
}
#endif
