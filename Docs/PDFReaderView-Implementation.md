# PDFReaderView Implementation Notes

Covers the non-obvious parts of the `PDFReaderView` module: the floating
selection toolbar, annotation persistence + render sync, and highlight-click
→ sidebar-card navigation. UI styling and tunable constants are not
documented here — read the code for those.

---

## File layout

| File | Responsibility |
|------|----------------|
| `Views/PDFReaderView.swift` | Main view, ViewModel, Coordinator, all annotation logic |
| `Views/AnnotationSidebarView.swift` | Right-hand annotation card list (`AnnotationCard`) |
| `Models/PDFAnnotationRecord.swift` | Persistence model (GRDB) |
| `Helpers/PDFView+ElegantScrollers.swift` | PDFView extension: internal scroll view lookup + scroller styling |

---

## 1. Floating selection toolbar

### 1.1 Data flow

```
User drags to select text
    │
    ▼
CommitAwarePDFView.mouseUp / keyUp
    │  commitSelectionIfNeeded()
    ▼
Coordinator.handleCommittedSelection(selection)
    │  compute pageRects + PDF anchor
    ▼
PDFReaderViewModel.stageSelection(...)
    │  stored in stagedSelectionPDFAnchor (page coordinate space)
    ▼
Coordinator.updateSelectionToolbarLayout()
    │  pdfView.convert(anchor, from: page)
    │  visibility check against pdfView.visibleRect
    │  convert to SwiftUI overlay coordinates
    ▼
PDFReaderViewModel.selectionToolbarLayout (@Published)
    │
    ▼
PDFReaderView.selectionActionBarOverlay
    └─ SelectionActionBar.position(x:y:)   ← toolbar appears here
```

### 1.2 Anchor storage: PDF page coordinate space

```swift
struct StagedSelectionPDFAnchor: Equatable {
    var pageIndex: Int
    var lastLineBounds: CGRect   // PDF page space — invariant under scroll/zoom
}
```

The anchor uses the **last line** of the selection
(`selection.selectionsByLine().last`), so the toolbar sits directly beneath
that line. Storing in page space (not viewport space) is what lets us
recompute the correct on-screen position after a scroll or zoom.

### 1.3 Scroll tracking: `boundsDidChange`

`Coordinator.ensureObservers(for:)` subscribes to two notifications:

| Notification | Trigger |
|--------------|---------|
| `NSView.boundsDidChangeNotification` (on clipView) | User scrolls the PDF |
| `PDFViewScaleChanged` | User zooms the PDF |

Each fires `updateSelectionToolbarLayout()`, which re-projects the page-space
anchor into viewport coordinates. No cached viewport position, no drift.

```swift
// ensureObservers install points:
// 1. after makeNSView, async (once the view is in the hierarchy)
// 2. after makeNSView, asyncAfter 0.1s (let PDFKit lay out its subviews)
// 3. every updateNSView call (fallback)
```

### 1.4 Gotcha: `internalScrollView`

PDFKit's internal scroll view (private class `PDFScrollView`) is a
**subview** of `PDFView`. `NSView.enclosingScrollView` only walks ancestors,
so it always returns `nil` here.

```swift
// PDFView+ElegantScrollers.swift
var internalScrollView: NSScrollView? {
    // Fast path: PDFScrollView is typically the first subview
    subviews.first as? NSScrollView ?? descendantScrollViews(of: self).first
}
```

Three call sites use this helper:

| Site | Purpose |
|------|---------|
| `ensureObservers` | Grab the `clipView` to install the scroll observer |
| `updateSelectionToolbarLayout` | Confirm a scroll view exists |
| `centerRectInViewport` | Precise scroll-to-rect for sidebar navigation |

### 1.5 Gotcha: coordinate-space alignment

`scrollView.contentView.bounds` is in the **document coordinate space**
(includes accumulated scroll offset — y values reach tens of thousands of
points). `pdfView.convert(rect, from: page)` returns the rect in the
**PDFView's own coordinate space**. They are not comparable — `intersects`
between them is meaningless.

Use `pdfView.visibleRect` instead; it lives in the same space as the
`convert(_:from:)` result:

```swift
let rectInPDFView = pdfView.convert(anchor.lastLineBounds, from: page)
let visibleRect = pdfView.visibleRect   // same space ✓

if !rectInPDFView.intersects(visibleRect) {
    // Selection scrolled out of view — hide the toolbar
}
```

Conversion into the SwiftUI overlay (anchored at `visibleRect.origin`):

```swift
let midX = rectInPDFView.midX - visibleRect.minX

if pdfView.isFlipped {
    lineTopSwift    = rectInPDFView.minY - visibleRect.minY
    lineBottomSwift = rectInPDFView.maxY - visibleRect.minY
} else {
    lineBottomSwift = visibleRect.height - (rectInPDFView.minY - visibleRect.minY)
    lineTopSwift    = visibleRect.height - (rectInPDFView.maxY - visibleRect.minY)
}
```

### 1.6 Toolbar placement

- Default: 12pt below the selection's last line.
- If the bottom edge is too close (< 6pt clearance), flip to **above** the
  selection.
- If neither fits, fall back to below and let the bar clip gracefully.
- Horizontally, clamp inside the overlay margins.

---

## 2. Annotation persistence & render sync

### 2.1 Model (`PDFAnnotationRecord`)

- GRDB-backed, table name `pdfAnnotation`.
- Rects are stored as a JSON array (`rectsData`), so multi-line highlights
  keep their individual segment rects.
- `unionBounds` populates `PDFAnnotation.bounds`; `quadrilateralPoints`
  carries the per-segment geometry.

### 2.2 Incremental sync (`syncAnnotations`)

```
annotations array from DB
    │
    ├─ keys that disappeared → removeAnnotation from PDFPage
    │
    └─ new or changed records (renderHash mismatch)
           → createPDFAnnotation(from:)
           → page.addAnnotation(annotation)
           → store in trackedAnnotations[id]
```

`renderHash` is derived from `id + type + color + pageIndex + noteText +
rects`. This is what lets us skip re-rendering unchanged annotations on
every sync pass.

### 2.3 `TrackedAnnotation`

```swift
struct TrackedAnnotation {
    let annotation: PDFAnnotation   // Retained by the PDFPage, not us
    let pageIndex: Int
    let renderHash: Int
}

var trackedAnnotations: [Int64: TrackedAnnotation] = [:]
// key = PDFAnnotationRecord.id
```

---

## 3. Highlight click → sidebar card

```
User clicks an existing highlight
    │
    ▼
CommitAwarePDFView.mouseUp
    │  currentSelection is empty (not a drag)
    │  annotationAtClick(event)
    │    convert(locationInWindow, from: nil) → PDFView space
    │    convert(point, to: page)             → PDF page space
    │    page.annotation(at: pdfPoint)        → PDFAnnotation?
    ▼
Coordinator.handleAnnotationClicked(annotation)
    │  walk trackedAnnotations
    │  find the key whose tracked.annotation === annotation
    │  viewModel.selectedAnnotationId = key
    ▼
AnnotationSidebarView
    └─ .onChange(of: selectedAnnotationId)
         proxy.scrollTo(newId, anchor: .center)   ← auto-scroll + flash
```

Click resolution order inside `mouseUp`: if there's an active
`currentSelection`, treat the click as a selection commit; otherwise probe
for a hit annotation; only then fall through to clearing the selection.
