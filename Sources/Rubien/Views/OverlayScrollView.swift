import SwiftUI
import AppKit

struct OverlayScrollView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            ScrollView { content }
        } else {
            LegacyOverlayScrollView { content }
        }
    }
}

private struct LegacyOverlayScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.applyRubienElegantScrollers()

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = hostingView

        // Pinning leading/trailing/top (no bottom) lets NSHostingView's
        // intrinsic height drive scroll content sizing.
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hostingView = scrollView.documentView as? NSHostingView<Content> else { return }
        hostingView.rootView = content
        scrollView.applyRubienElegantScrollers()
        // SwiftUI doesn't re-measure intrinsicContentSize on rootView swap;
        // nudge AppKit to recompute it before the next layout pass.
        DispatchQueue.main.async {
            scrollView.documentView?.invalidateIntrinsicContentSize()
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}
