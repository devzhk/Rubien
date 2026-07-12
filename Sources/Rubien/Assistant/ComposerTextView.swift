#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pasteboard routing

/// What the composer does with pasteboard content (⌘V, Edit ▸ Paste, or a drag
/// landing on the editor itself).
enum ComposerPasteboardAction: Equatable {
    case attachFiles([URL])
    case attachImageData(Data)
    case passthrough
}

/// Classifies pasteboard content for the composer. Paste and drop rank types
/// differently on purpose:
///
/// - **Paste**: a copied *file* always attaches. Otherwise any plain string means
///   the user copied text — spreadsheet-cell and rich-text copies carry an image
///   render alongside the string, and attaching that render would silently lose
///   the text — so native text paste wins. An image-only pasteboard (screenshot,
///   most browsers' "Copy Image") attaches.
/// - **Drop**: dragging a picture is unambiguous, so image data outranks the
///   URL string browsers put next to it; only file URLs rank higher. Anything
///   else (plain text drags) passes through to native text insertion.
enum ComposerPasteboardRouter {
    /// Common raster types to REGISTER for drags. Registration needs concrete
    /// type strings (AppKit can't register "anything conforming to `.image`");
    /// detection below is dynamic, so this list only bounds which drags reach
    /// the editor at all, not which formats stage successfully.
    static let registeredImageTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.webP.identifier),
    ]

    static func pasteAction(for pasteboard: NSPasteboard) -> ComposerPasteboardAction {
        if let urls = fileURLs(on: pasteboard) { return .attachFiles(urls) }
        if pasteboard.availableType(from: [.string]) != nil { return .passthrough }
        if let data = imageData(on: pasteboard) { return .attachImageData(data) }
        return .passthrough
    }

    static func dropAction(for pasteboard: NSPasteboard) -> ComposerPasteboardAction {
        if let urls = fileURLs(on: pasteboard) { return .attachFiles(urls) }
        if let data = imageData(on: pasteboard) { return .attachImageData(data) }
        return .passthrough
    }

    /// Materialization-free twins of `pasteAction`/`dropAction` for feasibility
    /// checks on hot paths (menu validation, drag entry): `readObjects`/`data(forType:)`
    /// copy blobs and can trigger a synchronous cross-process promise fetch, which
    /// must not happen just to compute a Bool.
    static func pasteWouldAttach(_ pasteboard: NSPasteboard) -> Bool {
        if hasFileURLs(pasteboard) { return true }
        if pasteboard.availableType(from: [.string]) != nil { return false }
        return availableImageType(on: pasteboard) != nil
    }

    static func dropWouldAttach(_ pasteboard: NSPasteboard) -> Bool {
        hasFileURLs(pasteboard) || availableImageType(on: pasteboard) != nil
    }

    private static let fileURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true
    ]

    private static func hasFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLReadingOptions)
    }

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        guard
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self], options: fileURLReadingOptions) as? [URL],
            !urls.isEmpty
        else { return nil }
        return urls
    }

    /// First pasteboard type carrying image data, in the source's fidelity order.
    /// Dynamic `.image` conformance (the same check `AssistantAttachmentStore`
    /// applies to files) keeps "what pastes" in lockstep with what the store and
    /// ImageIO accept, instead of maintaining a second format list here.
    private static func availableImageType(
        on pasteboard: NSPasteboard
    ) -> NSPasteboard.PasteboardType? {
        pasteboard.types?.first { UTType($0.rawValue)?.conforms(to: .image) == true }
    }

    private static func imageData(on pasteboard: NSPasteboard) -> Data? {
        guard let type = availableImageType(on: pasteboard) else { return nil }
        return pasteboard.data(forType: type)
    }
}

// MARK: - Text view

/// The chat composer's editor. A plain SwiftUI `TextEditor` can't be used here: its
/// backing NSTextView is the first responder and a registered drag destination, so
/// it consumes ⌘V (an image-only pasteboard no-ops; a copied file pastes as its
/// path) and file drops on the editor area (inserted as path text) before any
/// SwiftUI-level `.onPasteCommand` / `.dropDestination` on an enclosing view can
/// run. This subclass routes those to the attachment pipeline and passes everything
/// else through to native text editing.
final class ComposerNSTextView: NSTextView {
    var onCommandReturn: () -> Void = {}
    var onAttachFiles: ([URL]) -> Void = { _ in }
    var onAttachImageData: (Data, String) -> Void = { _, _ in }
    var onDragTargeted: (Bool) -> Void = { _ in }

    /// True while the current drag session is ours to handle (files/images) rather
    /// than the text system's (text drags). Super only ever sees the phases of
    /// sessions we passed through, so its internal drag state stays consistent.
    private var isRoutingDrag = false

    // MARK: Sizing

    /// The scroll view installs the document view but never sizes it — with only a
    /// width autoresizing mask, an empty text view stays one line fragment tall (or
    /// zero-frame before first layout), leaving click-dead zones below the caret
    /// line. Keep the minimum height pinned to the clip view so the editor always
    /// fills its visible area (what `NSTextView.scrollableTextView()` arranges).
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        fillClipViewHeight()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        fillClipViewHeight()
    }

    private func fillClipViewHeight() {
        guard let clipView = superview as? NSClipView else { return }
        minSize = NSSize(width: 0, height: clipView.bounds.height)
        if frame.height < clipView.bounds.height {
            setFrameSize(NSSize(width: clipView.bounds.width, height: clipView.bounds.height))
        }
    }

    // MARK: ⌘↩ send

    /// The composer owns the return key deterministically (see the history on the
    /// old `onKeyPress` — SwiftUI's loose key-equivalent matching once made ⇧↩
    /// send). ⌘↩ sends; plain ↩ and every other modifier fall through to the text
    /// system. Key equivalents sweep the whole window's view tree, so require first
    /// responder — an unfocused composer must not steal ⌘↩ from elsewhere.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
            Self.isCommandReturnChord(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
        {
            onCommandReturn()
            return true  // consumed even when there's nothing to send — never a newline
        }
        return super.performKeyEquivalent(with: event)
    }

    /// EXACTLY ⌘ — caps lock reports as a modifier (strict equality would dead-key
    /// ⌘↩ for a caps-lock user) and keypad-Enter adds `.numericPad`/`.function`,
    /// so state flags are masked out before comparing.
    static func isCommandReturnChord(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let returnKey: UInt16 = 36
        let keypadEnter: UInt16 = 76
        guard keyCode == returnKey || keyCode == keypadEnter else { return false }
        let chord = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        return chord == .command
    }

    // MARK: Paste

    override func paste(_ sender: Any?) {
        switch ComposerPasteboardRouter.pasteAction(for: .general) {
        case .attachFiles(let urls):
            onAttachFiles(urls)
        case .attachImageData(let data):
            onAttachImageData(data, "Pasted Image.png")
        case .passthrough:
            super.paste(sender)
        }
    }

    /// Keep Edit ▸ Paste (and thus ⌘V) enabled for pasteboards only *we* can take —
    /// a plain text view otherwise reports an image-only pasteboard as unpastable.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)),
            ComposerPasteboardRouter.pasteWouldAttach(.general)
        {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Drops

    /// A plain text view doesn't register for raster types, so image-data drags
    /// (e.g. from a browser) would never reach `draggingEntered` without this.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + ComposerPasteboardRouter.registeredImageTypes
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isRoutingDrag = ComposerPasteboardRouter.dropWouldAttach(sender.draggingPasteboard)
        guard isRoutingDrag else { return super.draggingEntered(sender) }
        onDragTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isRoutingDrag ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        guard isRoutingDrag else { return super.draggingExited(sender) }
        endRoutedDrag()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isRoutingDrag ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isRoutingDrag else { return super.performDragOperation(sender) }
        switch ComposerPasteboardRouter.dropAction(for: sender.draggingPasteboard) {
        case .attachFiles(let urls):
            onAttachFiles(urls)
            return true
        case .attachImageData(let data):
            onAttachImageData(data, "Dropped Image.png")
            return true
        case .passthrough:
            return false
        }
    }

    /// The documented final callback after a successful drop — clear the highlight
    /// here rather than waiting on `draggingEnded` (which still covers sessions
    /// that end elsewhere).
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        guard isRoutingDrag else { return super.concludeDragOperation(sender) }
        endRoutedDrag()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        if isRoutingDrag { endRoutedDrag() }
        // Always safe: AppKit broadcasts `draggingEnded` to destinations that never
        // saw this session, so super must tolerate an unpaired call.
        super.draggingEnded(sender)
    }

    private func endRoutedDrag() {
        isRoutingDrag = false
        onDragTargeted(false)
    }
}

// MARK: - SwiftUI wrapper

/// Drop-in for the composer's old `TextEditor`: same body font, clear background,
/// 5 pt line-fragment padding (the placeholder overlay aligns to it), growing with
/// the ZStack sizer and scrolling internally past the frame cap.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// Monotonic counter — each bump moves first-responder status to the editor
    /// (the write-only replacement for the old `@FocusState`).
    var focusRequestCount: Int
    var onCommandReturn: () -> Void
    var onAttachFiles: ([URL]) -> Void
    var onAttachImageData: (Data, String) -> Void
    var onDragTargeted: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.focusRingType = .none
        scrollView.applyRubienElegantScrollers()

        let textView = ComposerNSTextView()
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // No minSize here — `fillClipViewHeight` owns it (pinned to the clip view).
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 5
        textView.textContainerInset = .zero
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .textColor
        textView.delegate = context.coordinator
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        context.coordinator.parent = self
        textView.onCommandReturn = onCommandReturn
        textView.onAttachFiles = onAttachFiles
        textView.onAttachImageData = onAttachImageData
        textView.onDragTargeted = onDragTargeted

        // Compare against the coordinator's cache, not `textView.string` — the
        // latter bridges the whole text storage to a fresh String on every render
        // (and this runs per streaming tick); the cache stays COW-identical to the
        // binding when nothing changed, so the common case is O(1).
        if text != context.coordinator.lastSyncedText {
            // External write (send cleared the draft, conversation switched):
            // replace wholesale and drop undo history — undoing across a
            // programmatic replacement restores text the user never typed here.
            textView.string = text
            context.coordinator.lastSyncedText = text
            context.coordinator.undoManager.removeAllActions()
        }

        let coordinator = context.coordinator
        if focusRequestCount != coordinator.honoredFocusRequestCount {
            let requested = focusRequestCount
            // Defer out of the SwiftUI update pass; responder changes relayout.
            DispatchQueue.main.async { [weak textView] in
                // Not yet in a window (fresh pane mount): leave the request
                // unhonored so the next update retries instead of dropping it.
                guard let textView, let window = textView.window else { return }
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
                coordinator.honoredFocusRequestCount = requested
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var honoredFocusRequestCount: Int
        /// Mirror of the text view's string, shared (COW) with the binding — lets
        /// `updateNSView` detect external writes without re-bridging the AppKit
        /// text storage every render.
        var lastSyncedText: String
        /// Editor-private undo stack — the window's shared undo manager would let
        /// ⌘Z in the composer unwind other views' registrations (and vice versa).
        let undoManager = UndoManager()

        init(_ parent: ComposerTextView) {
            self.parent = parent
            honoredFocusRequestCount = parent.focusRequestCount
            lastSyncedText = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let latest = textView.string
            lastSyncedText = latest
            parent.text = latest
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
    }
}
#endif
