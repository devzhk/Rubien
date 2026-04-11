import AppKit

extension NSScrollView {
    func applyRubienElegantScrollers() {
        scrollerStyle = .overlay
        scrollerKnobStyle = .default
        autohidesScrollers = true
        verticalScroller?.applyRubienElegantStyle()
        horizontalScroller?.applyRubienElegantStyle()
    }
}

extension NSScroller {
    func applyRubienElegantStyle() {
        scrollerStyle = .overlay
        controlSize = .mini
        knobStyle = .default
        alphaValue = 0.42
    }
}
