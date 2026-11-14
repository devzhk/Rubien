#if os(macOS)
import AppKit

/// Pure rules for placing a dictation transcript at an insertion point. Kept free
/// of AppKit state so spacing and caret behavior are unit-testable.
enum DictationInsertion {
    /// The text to put in the live range: the trimmed transcript plus a space on
    /// either side where the neighboring character would otherwise run into it.
    ///
    /// - Parameter alwaysSeparatingBefore: Put a space after any preceding
    ///   non-whitespace character, whatever the script. A completed `@paper`
    ///   mention loses its identity when a letter is appended to its title, and
    ///   Han characters are letters.
    static func replacement(
        for transcript: String,
        before: Character?,
        after: Character?,
        alwaysSeparatingBefore: Bool = false
    ) -> String {
        let core = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = core.first, let last = core.last else { return "" }
        var result = core
        if let before {
            let separate = alwaysSeparatingBefore
                ? !before.isWhitespace
                : needsSpace(between: before, and: first)
            if separate { result = " " + result }
        }
        if let after, needsSpace(between: last, and: after) { result += " " }
        return result
    }

    static func needsSpace(between left: Character, and right: Character) -> Bool {
        if left.isWhitespace || right.isWhitespace { return false }
        if isWrittenWithoutSpaces(left) || isWrittenWithoutSpaces(right) { return false }
        if "([{\u{201C}\u{2018}".contains(left) { return false }
        if ".,;:!?)]}\u{201D}\u{2019}%".contains(right) { return false }
        return true
    }

    /// Where an existing selection lands once `oldLive` holds `newLength` UTF-16
    /// units. A caret parked at the end of the live text (or the selection the
    /// session started from) keeps following it; a caret the user moved elsewhere
    /// stays on the same text.
    static func adjustedSelection(
        _ selection: NSRange,
        replacing oldLive: NSRange,
        newLength: Int
    ) -> NSRange {
        let newEnd = oldLive.location + newLength
        let follows = selection == oldLive
            || (selection.length == 0 && selection.location == NSMaxRange(oldLive))
        if follows { return NSRange(location: newEnd, length: 0) }
        if selection.location >= NSMaxRange(oldLive) {
            return NSRange(
                location: selection.location + newLength - oldLive.length,
                length: selection.length)
        }
        if NSMaxRange(selection) <= oldLive.location { return selection }
        return NSRange(location: newEnd, length: 0)
    }

    /// Han, kana, and CJK or full-width punctuation: text that takes no space
    /// between words, so a transcript must not gain one beside it.
    private static func isWrittenWithoutSpaces(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }
}

/// Streams a live dictation transcript into the composer editor as range edits.
///
/// Edits go through the text system's change notifications, so they reach the
/// draft binding and the mention reconciler exactly as typing does. Writing the
/// draft binding instead would replace the whole string on every partial result,
/// which resets the caret and undo history and can overwrite a concurrent edit.
@MainActor
final class ComposerDictationBridge {
    /// Reports that a change the bridge did not make ended the session. Runs
    /// synchronously before typing, paste, undo, or input-method composition is
    /// applied; after an outside draft replacement or the editor going away, it
    /// runs on the next main-queue turn (see `interrupt`). The session has
    /// already ended either way, so a transcript update that arrives late is
    /// ignored and the other change always wins.
    var onInterruption: (() -> Void)?

    /// A class because the session's undo action reads the final range when it
    /// runs, after the session itself is over.
    private final class Session {
        /// UTF-16 range of the dictated text in the editor.
        var liveRange: NSRange
        /// The selected text the session started from, restored by undo.
        let originalText: String
        let separatesFromPrecedingText: Bool
        var hasEdited = false
        weak var textView: NSTextView?

        init(
            liveRange: NSRange,
            originalText: String,
            separatesFromPrecedingText: Bool,
            textView: NSTextView
        ) {
            self.liveRange = liveRange
            self.originalText = originalText
            self.separatesFromPrecedingText = separatesFromPrecedingText
            self.textView = textView
        }
    }

    private weak var textView: ComposerNSTextView?
    private var session: Session?
    /// True only while the editor is being asked to accept the bridge's own
    /// change, so the bridge does not interrupt itself. Changes made by anyone
    /// else during the notifications that follow still interrupt.
    private var isValidatingOwnEdit = false

    var isActive: Bool { session != nil }

    /// The attached editor's text, or nil when no editor is attached. Ahead of
    /// the draft binding, which can lag the editor by an edit.
    var editorText: String? { textView?.string }

    // MARK: Session

    /// Starts a session at the editor's selection. Returns false when there is
    /// no editable editor, a session is already running, or an input method is
    /// composing (its marked text must not be split by inserted text).
    ///
    /// - Parameter separatingFromPrecedingText: See
    ///   `DictationInsertion.replacement`. Pass true when the caret sits at the
    ///   end of a completed `@paper` mention.
    @discardableResult
    func begin(separatingFromPrecedingText: Bool = false) -> Bool {
        guard session == nil,
              let textView,
              let storage = textView.textStorage,
              textView.isEditable,
              !textView.hasMarkedText()
        else { return false }
        var selection = textView.selectedRange()
        if selection.location == NSNotFound || NSMaxRange(selection) > storage.length {
            selection = NSRange(location: storage.length, length: 0)
        }
        textView.breakUndoCoalescing()
        session = Session(
            liveRange: selection,
            originalText: storage.mutableString.substring(with: selection),
            separatesFromPrecedingText: separatingFromPrecedingText,
            textView: textView)
        return true
    }

    /// Replaces the dictated text with the latest transcript.
    func update(transcript: String) {
        guard let session, let textView, let storage = textView.textStorage else { return }
        // Read through the storage's own string; `textView.string` copies the
        // whole draft, and this runs for every partial result.
        let text = storage.mutableString
        let live = session.liveRange
        guard NSMaxRange(live) <= text.length else { return }

        let replacement = DictationInsertion.replacement(
            for: transcript,
            before: Self.character(in: text, endingAt: live.location),
            after: Self.character(in: text, startingAt: NSMaxRange(live)),
            alwaysSeparatingBefore: session.separatesFromPrecedingText)
        // Leave a starting selection untouched until there is something to say.
        if replacement.isEmpty, !session.hasEdited { return }
        guard text.substring(with: live) != replacement else { return }

        let selection = textView.selectedRange()
        isValidatingOwnEdit = true
        let allowed = Self.validateChange(in: textView, range: live, replacement: replacement)
        isValidatingOwnEdit = false
        guard allowed else { return }

        // One undo action covers the whole session: it is registered with the
        // first edit and reads the session's final range when it runs.
        if !session.hasEdited { registerUndo(for: session, in: textView) }
        // Updated before the change is applied, so anything that reacts to the
        // change notifications (including an interrupting edit) sees a range
        // that matches the text.
        let newLength = (replacement as NSString).length
        session.liveRange = NSRange(location: live.location, length: newLength)
        session.hasEdited = true

        let adjusted = DictationInsertion.adjustedSelection(
            selection, replacing: live, newLength: newLength)
        Self.applyChange(in: textView, range: live, replacement: replacement, selecting: adjusted)
        if adjusted.location == live.location + newLength {
            textView.scrollRangeToVisible(adjusted)
        }
    }

    /// Ends the session, keeping the dictated text as ordinary text.
    func end() {
        guard let session else { return }
        self.session = nil
        guard let textView else { return }
        // A session whose text came back to where it started (a transcript
        // revised to nothing) would otherwise leave an undo step that does nothing.
        if session.hasEdited,
           let text = textView.textStorage?.mutableString,
           NSMaxRange(session.liveRange) <= text.length,
           text.substring(with: session.liveRange) == session.originalText {
            textView.undoManager?.removeAllActions(withTarget: session)
        }
        textView.breakUndoCoalescing()
    }

    /// Ends the session because another change is about to be applied.
    ///
    /// - Parameter deferringNotification: Report the interruption on the next
    ///   main-queue turn instead of now. For callers inside a SwiftUI view
    ///   update, where the receiver must not publish changes. The session still
    ///   ends now, and the notification goes to the receiver installed now, not
    ///   to one a new session installs in between.
    func interrupt(deferringNotification: Bool = false) {
        guard session != nil else { return }
        #if DEBUG
        DictationSelfTest.interruptionTrace?(Thread.callStackSymbols)
        #endif
        end()
        guard let onInterruption else { return }
        if deferringNotification {
            DispatchQueue.main.async { onInterruption() }
        } else {
            onInterruption()
        }
    }

    // MARK: Editor hooks

    /// Called by `ComposerNSTextView` when the bridge becomes its bridge.
    func attach(to textView: ComposerNSTextView) {
        guard self.textView !== textView else { return }
        // Unlink the previous editor, or its edits would keep interrupting
        // sessions that now belong to this one.
        self.textView?.dictationBridge = nil
        self.textView = textView
    }

    /// Linking and unlinking happen inside SwiftUI view updates.
    func detach(from textView: ComposerNSTextView) {
        guard self.textView === textView else { return }
        interrupt(deferringNotification: true)
        self.textView = nil
    }

    /// The editor calls this before every text change, including the bridge's own.
    func editorWillChangeText() {
        guard !isValidatingOwnEdit else { return }
        interrupt()
    }

    // MARK: Private

    private func registerUndo(for session: Session, in textView: NSTextView) {
        guard let undoManager = textView.undoManager else { return }
        // The session is the target so `end()` can withdraw exactly this action.
        // The undo manager does not retain targets; the capture keeps it alive.
        undoManager.registerUndo(withTarget: session) { [session] _ in
            guard let textView = session.textView else { return }
            Self.swapText(in: textView, range: session.liveRange, with: session.originalText)
        }
        undoManager.setActionName("Dictation")
    }

    /// Replaces `range` with `text` and registers the reverse swap, so undo and
    /// redo alternate between the dictated text and what it replaced.
    private static func swapText(in textView: NSTextView, range: NSRange, with text: String) {
        guard let undoManager = textView.undoManager,
              let storage = textView.textStorage,
              NSMaxRange(range) <= storage.length
        else { return }
        let replaced = storage.mutableString.substring(with: range)
        let newRange = NSRange(location: range.location, length: (text as NSString).length)
        guard validateChange(in: textView, range: range, replacement: text) else { return }
        applyChange(
            in: textView, range: range, replacement: text,
            selecting: NSRange(location: NSMaxRange(newRange), length: 0))

        undoManager.registerUndo(withTarget: textView) { textView in
            swapText(in: textView, range: newRange, with: replaced)
        }
        undoManager.setActionName("Dictation")
    }

    /// Asks the text view to accept a programmatic change. The text view
    /// registers its own undo action here; that stays off, because the inverse
    /// it records for a programmatic replacement keeps the old range and raises
    /// a range exception when replayed.
    private static func validateChange(
        in textView: NSTextView,
        range: NSRange,
        replacement: String
    ) -> Bool {
        let undoManager = textView.undoManager
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        return textView.shouldChangeText(in: range, replacementString: replacement)
    }

    /// Makes a validated change and notifies the text system, which is what
    /// carries the new text to the delegate and the draft binding.
    private static func applyChange(
        in textView: NSTextView,
        range: NSRange,
        replacement: String,
        selecting selection: NSRange
    ) {
        textView.textStorage?.replaceCharacters(
            in: range,
            with: NSAttributedString(string: replacement, attributes: textView.typingAttributes))
        // Text first, then selection: the order typing publishes them in.
        textView.didChangeText()
        textView.setSelectedRange(selection)
    }

    private static func character(in text: NSString, endingAt location: Int) -> Character? {
        guard location > 0 else { return nil }
        return text.substring(with: text.rangeOfComposedCharacterSequence(at: location - 1)).last
    }

    private static func character(in text: NSString, startingAt location: Int) -> Character? {
        guard location < text.length else { return nil }
        return text.substring(with: text.rangeOfComposedCharacterSequence(at: location)).first
    }
}
#endif
