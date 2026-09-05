#if os(macOS)
import AppKit
import SwiftUI

/// Refresh AppKit's cached row height when a visible title/byline changes size.
struct ReferenceCellHeightObserver: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.updateHeight(height)
    }

    final class Anchor: NSView {
        private var measuredHeight: CGFloat?
        private var needsHeightUpdate = false
        private var scheduled = false

        func updateHeight(_ height: CGFloat) {
            guard height.isFinite, height > 0 else { return }
            if measuredHeight.map({ abs($0 - height) > 0.5 }) ?? true {
                measuredHeight = height
                needsHeightUpdate = true
            }
            scheduleUpdate()
        }

        override func layout() {
            super.layout()
            scheduleUpdate()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleUpdate()
        }

        private func scheduleUpdate() {
            guard needsHeightUpdate, !scheduled else { return }
            scheduled = true
            // Never re-enter row measurement during SwiftUI's layout/update.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                var ancestor = self.superview
                while let view = ancestor {
                    if let table = view as? NSTableView {
                        let row = table.row(for: self)
                        guard table.usesAutomaticRowHeights, row >= 0 else { return }
                        self.needsHeightUpdate = false
                        let rows = IndexSet(integer: row)
                        table.noteHeightOfRows(withIndexesChanged: rows)
                        // Newly inserted SwiftUI rows can retain AppKit's estimated
                        // height even after their content has been measured. If
                        // that cache still clips the title, reset automatic sizing
                        // without rebuilding the table or changing its selection.
                        if let height = self.measuredHeight,
                           table.rect(ofRow: row).height + 0.5 < height {
                            table.usesAutomaticRowHeights = false
                            table.usesAutomaticRowHeights = true
                            table.noteHeightOfRows(withIndexesChanged: rows)
                        }
                        return
                    }
                    ancestor = view.superview
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
