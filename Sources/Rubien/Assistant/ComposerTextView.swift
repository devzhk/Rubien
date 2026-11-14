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

/// Unmodified keys the AppKit composer offers to the paper-mention UI before
/// falling back to native text editing.
enum ComposerNavigationKey: Equatable {
    case returnKey
    case downArrow
    case upArrow
    case escape
}

/// The chat composer's editor. A plain SwiftUI `TextEditor` can't be used here: its
/// backing NSTextView is the first responder and a registered drag destination, so
/// it consumes ⌘V (an image-only pasteboard no-ops; a copied file pastes as its
/// path) and file drops on the editor area (inserted as path text) before any
/// SwiftUI-level `.onPasteCommand` / `.dropDestination` on an enclosing view can
/// run. This subclass routes those to the attachment pipeline and passes everything
/// else through to native text editing.
final class ComposerNSTextView: NSTextView {
    var onCommandReturn: () -> Void = {}
    var onNavigationKey: (ComposerNavigationKey) -> Bool = { _ in false }
    var onAttachFiles: ([URL]) -> Void = { _ in }
    var onAttachImageData: (Data, String) -> Void = { _, _ in }
    var onDragTargeted: (Bool) -> Void = { _ in }
    /// Returns whether it acted, so the key falls through when it did not.
    var onToggleDictation: () -> Bool = { false }
    /// Live dictation into this editor, if the surface offers it. The bridge
    /// keeps a matching back-reference, so the two are linked and unlinked here.
    weak var dictationBridge: ComposerDictationBridge? {
        didSet {
            guard oldValue !== dictationBridge else { return }
            oldValue?.detach(from: self)
            dictationBridge?.attach(to: self)
        }
    }

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
        // Unlike ⌘↩ this needs no focus here: the shortcut dictates to this
        // window's composer from wherever the user is reading. The handler
        // declines for a composer that is mounted but not showing.
        if Self.isDictationChord(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags),
            onToggleDictation()
        {
            return true
        }
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

    /// EXACTLY ⌘D, by character rather than key code so it follows the
    /// keyboard layout.
    static func isDictationChord(
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard charactersIgnoringModifiers?.lowercased() == "d" else { return false }
        let chord = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        return chord == .command
    }

    // MARK: Mention navigation

    /// Let an open mention popover consume plain Return/arrows/Escape. Modified
    /// keys remain owned by the text system so selection and editing shortcuts
    /// keep their native behavior.
    override func keyDown(with event: NSEvent) {
        if let key = Self.navigationKey(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ), onNavigationKey(key) {
            return
        }
        super.keyDown(with: event)
    }

    static func navigationKey(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ComposerNavigationKey? {
        let chord = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard chord.isEmpty else { return nil }
        switch keyCode {
        case 36, 76: return .returnKey
        case 125: return .downArrow
        case 126: return .upArrow
        case 53: return .escape
        default: return nil
        }
    }

    // MARK: Dictation

    /// Every text change that carries replacement text is validated here first:
    /// typing, paste, undo, text substitutions, and the dictation bridge's own
    /// edits. A nil array is an attributes-only change, which leaves dictated
    /// text where it is.
    override func shouldChangeText(
        inRanges affectedRanges: [NSValue],
        replacementStrings: [String]?
    ) -> Bool {
        if replacementStrings != nil { dictationBridge?.editorWillChangeText() }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    /// Marked text is an edit in progress; dictation must stop before it starts
    /// rather than rewrite text around a half-composed character.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        dictationBridge?.editorWillChangeText()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
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
    /// Matches the transcript renderer's 14 px base message text.
    static let messageFontSize: CGFloat = 14

    @Binding var text: String
    /// Character-offset selection in `text`. Offsets avoid retaining potentially
    /// invalid `String.Index` values while AppKit and SwiftUI bindings coalesce.
    @Binding var selection: Range<Int>?
    /// Monotonic counter — each bump moves first-responder status to the editor
    /// (the write-only replacement for the old `@FocusState`).
    var focusRequestCount: Int
    var onCommandReturn: () -> Void
    var onNavigationKey: (ComposerNavigationKey) -> Bool
    var onAttachFiles: ([URL]) -> Void
    var onAttachImageData: (Data, String) -> Void
    var onDragTargeted: (Bool) -> Void
    var dictationBridge: ComposerDictationBridge? = nil
    var onToggleDictation: () -> Bool = { false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.focusRingType = .none
        scrollView.applyRubienElegantScrollers()

        let textView = Self.makeTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.onCommandReturn = onCommandReturn
        textView.onNavigationKey = onNavigationKey
        textView.onAttachFiles = onAttachFiles
        textView.onAttachImageData = onAttachImageData
        textView.onDragTargeted = onDragTargeted
        textView.dictationBridge = dictationBridge
        textView.onToggleDictation = onToggleDictation

        scrollView.documentView = textView
        return scrollView
    }

    /// The editor's text-system configuration, apart from the SwiftUI wiring, so
    /// tests can drive the same text view the composer uses.
    static func makeTextView() -> ComposerNSTextView {
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
        textView.font = .systemFont(ofSize: Self.messageFontSize)
        textView.textColor = .textColor
        return textView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView.documentView as? ComposerNSTextView)?.dictationBridge = nil
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        context.coordinator.parent = self
        textView.onCommandReturn = onCommandReturn
        textView.onNavigationKey = onNavigationKey
        textView.onAttachFiles = onAttachFiles
        textView.onAttachImageData = onAttachImageData
        textView.onDragTargeted = onDragTargeted
        textView.dictationBridge = dictationBridge
        textView.onToggleDictation = onToggleDictation
        let coordinator = context.coordinator
        coordinator.syncExternalState(text: text, selection: selection, into: textView)

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
        /// Character offsets matching the primary AppKit selection.
        var lastSyncedSelection: Range<Int>?
        /// Drafts this editor replaced with its own edits and has not yet seen
        /// SwiftUI render back. See `syncExternalText`.
        private var unconfirmedPreviousTexts: [String] = []
        /// A draft that matched one of those and may yet be an outside write.
        private var unresolvedDraft: String?
        private var unresolvedDraftCheck = 0
        /// Counts the editor's own edits, so a pending outside write that an
        /// edit has since superseded is not applied over it.
        private var editCount = 0
        /// How long a draft equal to one of this editor's previous texts may go
        /// unconfirmed before it is taken for an outside write after all.
        var staleRenderGrace: TimeInterval = 0.5
        /// Editor-private undo stack — the window's shared undo manager would let
        /// ⌘Z in the composer unwind other views' registrations (and vice versa).
        let undoManager = UndoManager()

        init(_ parent: ComposerTextView) {
            self.parent = parent
            honoredFocusRequestCount = parent.focusRequestCount
            lastSyncedText = parent.text
            lastSyncedSelection = parent.selection
        }

        /// Adopts a render's draft and selection. A selection is only meaningful
        /// against the text it was measured in, so a render whose text is
        /// ignored as stale leaves the selection alone too.
        func syncExternalState(
            text: String,
            selection: Range<Int>?,
            into textView: ComposerNSTextView
        ) {
            guard syncExternalText(text, into: textView) else { return }
            if selection != lastSyncedSelection,
               let selection,
               let nativeRange = ComposerTextView.nativeRange(for: selection, in: text) {
                lastSyncedSelection = selection
                textView.setSelectedRange(nativeRange)
                textView.scrollRangeToVisible(nativeRange)
            } else if selection == nil {
                lastSyncedSelection = nil
            }
        }

        /// Adopts a draft written from outside the editor (send cleared it, the
        /// conversation switched, a mention was completed). Returns false when
        /// the draft is ignored as a stale render, so the editor's text stands.
        @discardableResult
        func syncExternalText(_ text: String, into textView: ComposerNSTextView) -> Bool {
            // Compare against the cache, not `textView.string` — the latter bridges
            // the whole text storage to a fresh String on every render (and this
            // runs per streaming tick); the cache stays COW-identical to the
            // binding when nothing changed, so the common case is O(1).
            guard text != lastSyncedText else {
                unconfirmedPreviousTexts.removeAll()
                unresolvedDraft = nil
                return true
            }
            // SwiftUI can re-render the editor with the draft from before an
            // edit it just published, then again with the new one. It happens
            // in Agent Home, whose draft is owned several views up. That echo is
            // not an outside write: acting on it would revert the edit and end
            // dictation. An outside write can equal the same text, though, and
            // the draft cannot be read back reliably at this point, so the echo
            // is only acted on if no render confirms the editor's text in time.
            if unconfirmedPreviousTexts.contains(text) {
                // The surface re-renders per streaming tick; seeing the same
                // value again must not postpone its deadline.
                if unresolvedDraft != text { armStaleRenderCheck(for: text, in: textView) }
                return false
            }
            replaceText(with: text, in: textView)
            return true
        }

        private func armStaleRenderCheck(for draft: String, in textView: ComposerNSTextView) {
            unresolvedDraft = draft
            unresolvedDraftCheck += 1
            let check = unresolvedDraftCheck
            let edits = editCount
            DispatchQueue.main.asyncAfter(deadline: .now() + staleRenderGrace) { [weak self, weak textView] in
                guard let self, let textView, self.unresolvedDraftCheck == check,
                      let draft = self.unresolvedDraft
                else { return }
                // The binding already carries the newer edit.
                guard self.editCount == edits else {
                    self.unresolvedDraft = nil
                    return
                }
                if draft != self.lastSyncedText { self.replaceText(with: draft, in: textView) }
            }
        }

        private func replaceText(with text: String, in textView: ComposerNSTextView) {
            // Assigning `string` bypasses the text view's change validation.
            // This runs inside a view update, where the session's owner must
            // not publish changes.
            textView.dictationBridge?.interrupt(deferringNotification: true)
            // Replace wholesale and drop undo history — undoing across a
            // programmatic replacement restores text the user never typed here.
            textView.string = text
            // A render still carrying the replaced text is stale, like one
            // carrying text the editor's own edits replaced.
            unconfirmedPreviousTexts = lastSyncedText == text ? [] : [lastSyncedText]
            lastSyncedText = text
            lastSyncedSelection = nil
            unresolvedDraft = nil
            undoManager.removeAllActions()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            editCount += 1
            let latest = textView.string
            if latest != lastSyncedText {
                // A few entries are plenty: each is confirmed by the next render.
                unconfirmedPreviousTexts.append(lastSyncedText)
                if unconfirmedPreviousTexts.count > 8 { unconfirmedPreviousTexts.removeFirst() }
            }
            lastSyncedText = latest
            parent.text = latest
            syncSelection(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            syncSelection(from: textView)
        }

        private func syncSelection(from textView: NSTextView) {
            guard let latest = ComposerTextView.selectionOffsets(from: textView) else { return }
            guard latest != lastSyncedSelection else { return }
            lastSyncedSelection = latest
            parent.selection = latest
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
    }

    static func selectionOffsets(from textView: NSTextView) -> Range<Int>? {
        let text = textView.string
        guard let range = Range(textView.selectedRange(), in: text) else { return nil }
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        return lower..<upper
    }

    static func nativeRange(
        for offsets: Range<Int>,
        in text: String
    ) -> NSRange? {
        guard offsets.lowerBound >= 0,
              offsets.upperBound >= offsets.lowerBound,
              let lower = text.index(
                text.startIndex,
                offsetBy: offsets.lowerBound,
                limitedBy: text.endIndex
              ),
              let upper = text.index(
                lower,
                offsetBy: offsets.upperBound - offsets.lowerBound,
                limitedBy: text.endIndex
              )
        else { return nil }
        return NSRange(lower..<upper, in: text)
    }
}
#endif
