#if os(macOS)
import AppKit
import SwiftUI
import XCTest

@testable import Rubien

/// Spacing and caret rules, independent of any editor.
final class DictationInsertionTests: XCTestCase {
    private func replacement(_ transcript: String, _ before: Character?, _ after: Character?) -> String {
        DictationInsertion.replacement(for: transcript, before: before, after: after)
    }

    func testAddsSpacesOnlyWhereWordsWouldRunTogether() {
        XCTAssertEqual(replacement("hello", nil, nil), "hello")
        XCTAssertEqual(replacement("hello", "c", nil), " hello")
        XCTAssertEqual(replacement("hello", " ", nil), "hello")
        XCTAssertEqual(replacement("hello", "\n", nil), "hello")
        XCTAssertEqual(replacement("hello", ".", "T"), " hello ")
        XCTAssertEqual(replacement("hello", nil, " "), "hello")
        XCTAssertEqual(replacement("hello", "(", ")"), "hello")
        XCTAssertEqual(replacement("hello", "c", ","), " hello")
    }

    func testTrimsTranscriptWhitespaceAndKeepsInnerText() {
        XCTAssertEqual(replacement("  hello world \n", nil, nil), "hello world")
        XCTAssertEqual(replacement("   ", "c", "d"), "")
        XCTAssertEqual(replacement("", "c", "d"), "")
    }

    func testAddsNoSpaceBesideTextWrittenWithoutSpaces() {
        XCTAssertEqual(replacement("世界", "好", nil), "世界")
        XCTAssertEqual(replacement("hello", "好", "。"), "hello")
        XCTAssertEqual(replacement("こんにちは", "a", "b"), "こんにちは")
    }

    func testAlwaysSeparatingBeforeOverridesTheScriptRule() {
        func separated(_ transcript: String, _ before: Character?) -> String {
            DictationInsertion.replacement(
                for: transcript, before: before, after: nil, alwaysSeparatingBefore: true)
        }
        XCTAssertEqual(replacement("中文", "r", nil), "中文")
        XCTAssertEqual(separated("中文", "r"), " 中文")
        XCTAssertEqual(separated("中文", "制"), " 中文")
        XCTAssertEqual(separated(", and", "r"), " , and")
        XCTAssertEqual(separated("中文", " "), "中文")
        XCTAssertEqual(separated("中文", nil), "中文")
    }

    func testCaretAtTheEndOfLiveTextFollowsIt() {
        let live = NSRange(location: 4, length: 5)
        XCTAssertEqual(
            DictationInsertion.adjustedSelection(
                NSRange(location: 9, length: 0), replacing: live, newLength: 11),
            NSRange(location: 15, length: 0))
        // The selection the session started from counts as following too.
        XCTAssertEqual(
            DictationInsertion.adjustedSelection(live, replacing: live, newLength: 2),
            NSRange(location: 6, length: 0))
    }

    func testCaretElsewhereStaysOnTheSameText() {
        let live = NSRange(location: 4, length: 5)
        XCTAssertEqual(
            DictationInsertion.adjustedSelection(
                NSRange(location: 1, length: 2), replacing: live, newLength: 11),
            NSRange(location: 1, length: 2))
        XCTAssertEqual(
            DictationInsertion.adjustedSelection(
                NSRange(location: 12, length: 1), replacing: live, newLength: 11),
            NSRange(location: 18, length: 1))
        // A selection that overlapped the replaced text collapses to its end.
        XCTAssertEqual(
            DictationInsertion.adjustedSelection(
                NSRange(location: 6, length: 1), replacing: live, newLength: 2),
            NSRange(location: 6, length: 0))
    }
}

/// Drives the real composer text view, coordinator, and bridge without a SwiftUI
/// host, so the text system's own change and undo behavior is what gets tested.
@MainActor
final class ComposerDictationBridgeTests: XCTestCase {
    @MainActor
    private final class Editor {
        final class Draft {
            var text: String
            var selection: Range<Int>?
            var edits: [(old: String, new: String)] = []
            /// Runs inside the draft binding's setter, which the editor calls
            /// while it is still announcing a change.
            var onNextEdit: (() -> Void)?
            init(text: String) { self.text = text }
        }

        let draft: Draft
        let textView = ComposerTextView.makeTextView()
        let bridge: ComposerDictationBridge
        let coordinator: ComposerTextView.Coordinator
        /// Editor text at the moment each interruption was reported.
        var textAtInterruption: [String] = []

        /// The representable as a render would build it. `shownText` and
        /// `shownSelection` are what that render's bindings read, which can
        /// lag the draft; writes always reach the draft.
        private static func view(
            of draft: Draft,
            bridge: ComposerDictationBridge,
            shownText: (() -> String)? = nil,
            shownSelection: (() -> Range<Int>?)? = nil
        ) -> ComposerTextView {
            ComposerTextView(
                text: Binding(
                    get: { shownText?() ?? draft.text },
                    set: { new in
                        draft.edits.append((old: draft.text, new: new))
                        draft.text = new
                        let hook = draft.onNextEdit
                        draft.onNextEdit = nil
                        hook?()
                    }),
                selection: Binding(
                    get: { shownSelection.map { $0() } ?? draft.selection },
                    set: { draft.selection = $0 }),
                focusRequestCount: 0,
                onCommandReturn: {},
                onNavigationKey: { _ in false },
                onAttachFiles: { _ in },
                onAttachImageData: { _, _ in },
                onDragTargeted: { _ in },
                dictationBridge: bridge)
        }

        /// - Parameter selection: UTF-16 range; defaults to a caret at the end.
        init(_ text: String = "", selection: NSRange? = nil) {
            let draft = Draft(text: text)
            let bridge = ComposerDictationBridge()
            self.draft = draft
            self.bridge = bridge
            coordinator = ComposerTextView.Coordinator(Self.view(of: draft, bridge: bridge))

            textView.delegate = coordinator
            coordinator.textView = textView
            textView.string = text
            textView.setSelectedRange(
                selection ?? NSRange(location: (text as NSString).length, length: 0))
            textView.dictationBridge = bridge
            // Weak: a deferred interruption can arrive after a test has ended.
            bridge.onInterruption = { [weak self] in
                guard let self else { return }
                textAtInterruption.append(textView.string)
            }
        }

        var string: String { textView.string }
        var undoManager: UndoManager { coordinator.undoManager }

        func type(_ text: String) {
            textView.insertText(text, replacementRange: textView.selectedRange())
        }

        /// Runs the coordinator's render path (what `updateNSView` does) with
        /// bindings that read `text` and `selection`, whatever the draft holds.
        func render(text: String, selection: Range<Int>?) {
            coordinator.update(
                from: Self.view(
                    of: draft, bridge: bridge,
                    shownText: { text }, shownSelection: { selection }),
                textView: textView)
        }

        /// The text a new editor would start with if a render showing `text`
        /// built it for `bridge` (this editor's surface unless given).
        func newEditorText(
            inARenderShowing text: String,
            for bridge: ComposerDictationBridge? = nil
        ) -> String {
            Self.view(of: draft, bridge: bridge ?? self.bridge, shownText: { text }).initialText
        }

        /// Runs work the editor scheduled on the main queue.
        func drainMainQueue(for seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        /// Lets the undo manager close the group it opened for the current
        /// event, the way returning to the run loop does between real events.
        func endEvent(file: StaticString = #filePath, line: UInt = #line) {
            RunLoop.current.run(until: Date())
            XCTAssertEqual(undoManager.groupingLevel, 0, file: file, line: line)
        }
    }

    private let paper = ChatReference(
        id: 7, title: "Attention Is All You Need", authors: "Vaswani et al.")

    // MARK: Inserting

    func testInsertsAtTheCaretWithSpacing() {
        let editor = Editor("abc def", selection: NSRange(location: 3, length: 0))
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")

        XCTAssertEqual(editor.string, "abc hello def")
        XCTAssertEqual(editor.draft.text, "abc hello def")
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 9, length: 0))
        XCTAssertEqual(editor.draft.selection, 9..<9)
    }

    func testReplacesTheStartingSelectionOnlyOnceThereAreWords() {
        let editor = Editor("abc XXX def", selection: NSRange(location: 4, length: 3))
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "  ")
        XCTAssertEqual(editor.string, "abc XXX def")
        XCTAssertTrue(editor.draft.edits.isEmpty)

        editor.bridge.update(transcript: "hello")
        XCTAssertEqual(editor.string, "abc hello def")
    }

    func testRevisedPartialResultsReplaceOnlyTheDictatedText() {
        let editor = Editor("Start. ")
        XCTAssertTrue(editor.bridge.begin())
        for transcript in ["hello wor", "hello world", "Hello, world."] {
            editor.bridge.update(transcript: transcript)
            XCTAssertEqual(editor.string, "Start. " + transcript)
            // The draft is current as soon as the update returns.
            XCTAssertEqual(editor.draft.text, editor.string)
        }
        XCTAssertEqual(editor.draft.edits.count, 3)
        // The bridge's own edits never count as interruptions.
        XCTAssertTrue(editor.textAtInterruption.isEmpty)
        XCTAssertTrue(editor.bridge.isActive)

        // A transcript revised down to nothing removes the dictated text.
        editor.bridge.update(transcript: "")
        XCTAssertEqual(editor.string, "Start. ")
    }

    func testRepeatedTranscriptMakesNoEdit() {
        let editor = Editor()
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")
        editor.bridge.update(transcript: "hello ")
        XCTAssertEqual(editor.draft.edits.count, 1)
    }

    func testInsertedTextUsesTheEditorFont() throws {
        let editor = Editor()
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hi")

        let storage = try XCTUnwrap(editor.textView.textStorage)
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font, editor.textView.font)
    }

    func testComposedCharactersAndUnspacedScripts() {
        let family = "你好👨‍👩‍👧‍👦"
        let editor = Editor(family)
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "世界")
        editor.bridge.update(transcript: "世界和平")
        XCTAssertEqual(editor.string, family + "世界和平")
        XCTAssertEqual(editor.draft.selection, 7..<7)

        let accented = Editor("e\u{301}")
        XCTAssertTrue(accented.bridge.begin())
        accented.bridge.update(transcript: "ok")
        XCTAssertEqual(accented.string, "e\u{301} ok")
        XCTAssertEqual(accented.draft.selection, 4..<4)
    }

    // MARK: Caret

    func testACaretTheUserMovedIsLeftAlone() {
        let editor = Editor("abc def", selection: NSRange(location: 3, length: 0))
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")

        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.bridge.update(transcript: "hello world")
        XCTAssertEqual(editor.string, "abc hello world def")
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.bridge.isActive)

        // A caret after the dictated text stays on the same character.
        let end = (editor.string as NSString).length
        editor.textView.setSelectedRange(NSRange(location: end, length: 0))
        editor.bridge.update(transcript: "hi")
        XCTAssertEqual(editor.string, "abc hi def")
        XCTAssertEqual(
            editor.textView.selectedRange(),
            NSRange(location: (editor.string as NSString).length, length: 0))
    }

    // MARK: Interruptions

    func testTypingEndsTheSessionBeforeItsEditAndTheUserTextWins() {
        let editor = Editor()
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")

        editor.type("!")
        XCTAssertEqual(editor.textAtInterruption, ["hello"])
        XCTAssertFalse(editor.bridge.isActive)
        XCTAssertEqual(editor.string, "hello!")

        editor.bridge.update(transcript: "hello world")
        XCTAssertEqual(editor.string, "hello!")
        XCTAssertEqual(editor.draft.text, "hello!")
    }

    /// An edit made while the editor is still announcing a dictation edit must
    /// interrupt like any other, and keep its own undo step.
    func testAnEditMadeDuringADictationChangeNotificationStillInterrupts() {
        let editor = Editor()
        XCTAssertTrue(editor.bridge.begin())
        editor.draft.onNextEdit = { editor.type("!") }
        editor.bridge.update(transcript: "hello")
        editor.endEvent()

        XCTAssertEqual(editor.textAtInterruption, ["hello"])
        XCTAssertFalse(editor.bridge.isActive)
        XCTAssertEqual(editor.string, "hello!")
        editor.bridge.update(transcript: "hello world")
        XCTAssertEqual(editor.string, "hello!")

        XCTAssertTrue(editor.undoManager.canUndo)
        editor.undoManager.undo()
        XCTAssertEqual(editor.string, "")
    }

    func testInputMethodCompositionBlocksStartAndEndsASession() {
        let editor = Editor("ab")
        let noReplacement = NSRange(location: NSNotFound, length: 0)
        editor.textView.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: noReplacement)
        XCTAssertTrue(editor.textView.hasMarkedText())
        XCTAssertFalse(editor.bridge.begin())

        editor.textView.unmarkText()
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")
        editor.textView.setMarkedText(
            "ha", selectedRange: NSRange(location: 2, length: 0), replacementRange: noReplacement)
        XCTAssertEqual(editor.textAtInterruption.count, 1)
        XCTAssertFalse(editor.bridge.isActive)
    }

    func testExternalDraftReplacementEndsTheSession() {
        let editor = Editor("abc")
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")

        // What the surface does when send clears the draft.
        editor.bridge.replaceEditorText("")
        XCTAssertFalse(editor.bridge.isActive)
        XCTAssertEqual(editor.string, "")
        XCTAssertFalse(editor.undoManager.canUndo)

        editor.bridge.update(transcript: "hello world")
        XCTAssertEqual(editor.string, "")

        // Reported a turn later, to a receiver that may publish changes.
        XCTAssertTrue(editor.textAtInterruption.isEmpty)
        editor.drainMainQueue(for: 0.01)
        XCTAssertEqual(editor.textAtInterruption, [""])
    }

    func testADeferredInterruptionNotifiesTheReceiverInstalledWhenItHappened() {
        let editor = Editor()
        var calls: [String] = []
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")
        editor.bridge.onInterruption = { calls.append("first") }

        editor.bridge.interrupt(deferringNotification: true)
        XCTAssertFalse(editor.bridge.isActive)
        XCTAssertTrue(calls.isEmpty)
        editor.bridge.update(transcript: "hello world")
        XCTAssertEqual(editor.string, "hello")

        // A new session installs its own receiver before the next turn.
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.onInterruption = { calls.append("second") }
        editor.drainMainQueue(for: 0.01)
        XCTAssertEqual(calls, ["first"])
        XCTAssertTrue(editor.bridge.isActive)

        // The synchronous form reports before returning.
        editor.bridge.interrupt()
        XCTAssertEqual(calls, ["first", "second"])
        XCTAssertFalse(editor.bridge.isActive)
    }

    func testEditorTextFollowsTheAttachedEditor() {
        let editor = Editor("abc")
        XCTAssertEqual(editor.bridge.editorText, "abc")
        editor.type("d")
        XCTAssertEqual(editor.bridge.editorText, "abcd")
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")
        XCTAssertEqual(editor.bridge.editorText, "abcd hello")

        editor.textView.dictationBridge = nil
        XCTAssertNil(editor.bridge.editorText)
    }

    // MARK: Renders and replacements

    /// The editor owns its text. SwiftUI can render it with a draft from
    /// before an edit it just published (seen in Agent Home, whose draft is
    /// owned several views up), so no render's draft is applied: not an older
    /// one, a newer one, or an empty one.
    func testARenderNeverChangesTheEditorText() {
        let editor = Editor("Note: ")
        editor.type("a")
        editor.endEvent()
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")
        let edits = editor.draft.edits.count
        XCTAssertEqual(editor.string, "Note: a hello")

        for shown in ["Note: a", "Note: ", "", "Note: a hello world", "unrelated"] {
            editor.render(text: shown, selection: editor.draft.selection)
            XCTAssertEqual(editor.string, "Note: a hello", "render showing \"\(shown)\"")
            XCTAssertTrue(editor.bridge.isActive, "render showing \"\(shown)\"")
            XCTAssertTrue(editor.undoManager.canUndo, "render showing \"\(shown)\"")
        }
        editor.drainMainQueue(for: 0.01)
        XCTAssertTrue(editor.textAtInterruption.isEmpty)
        XCTAssertEqual(editor.draft.edits.count, edits)

        // Dictation carries on into the same text.
        editor.bridge.update(transcript: "hello world")
        XCTAssertEqual(editor.string, "Note: a hello world")
        XCTAssertEqual(editor.draft.text, "Note: a hello world")
    }

    func testRendersDoNotDisturbTyping() {
        let editor = Editor("x")
        // Each render repeats the selection the editor published, with a
        // draft that is older, current, or empty.
        editor.type("y")
        editor.render(text: "x", selection: editor.draft.selection)
        editor.type("z")
        editor.render(text: "xy", selection: editor.draft.selection)
        editor.render(text: "", selection: editor.draft.selection)
        editor.render(text: "xyz", selection: editor.draft.selection)
        XCTAssertEqual(editor.string, "xyz")
        XCTAssertEqual(editor.draft.text, "xyz")
        XCTAssertTrue(editor.undoManager.canUndo)
    }

    func testReplacingTheContentsReplacesTheTextWithoutWritingTheDraft() {
        let editor = Editor("abc")
        editor.type("d")
        editor.endEvent()
        XCTAssertTrue(editor.undoManager.canUndo)
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")
        let draftBefore = editor.draft.text
        let edits = editor.draft.edits.count

        editor.textView.replaceContents(with: "new text")
        XCTAssertEqual(editor.string, "new text")
        XCTAssertFalse(editor.bridge.isActive)
        XCTAssertFalse(editor.undoManager.canUndo)
        // The caller writes the draft itself.
        XCTAssertEqual(editor.draft.text, draftBefore)
        XCTAssertEqual(editor.draft.edits.count, edits)

        // The interruption is reported on the next main-queue turn.
        XCTAssertTrue(editor.textAtInterruption.isEmpty)
        editor.drainMainQueue(for: 0.01)
        XCTAssertEqual(editor.textAtInterruption, ["new text"])

        // A render still showing the old draft leaves the new text alone.
        editor.render(text: draftBefore, selection: nil)
        XCTAssertEqual(editor.string, "new text")
    }

    func testReplacingTheContentsWithTheSameTextChangesNothing() {
        let editor = Editor("abc")
        editor.type("d")
        editor.endEvent()
        XCTAssertTrue(editor.bridge.begin())

        editor.bridge.replaceEditorText("abcd")
        XCTAssertEqual(editor.string, "abcd")
        XCTAssertTrue(editor.bridge.isActive)
        XCTAssertTrue(editor.undoManager.canUndo)
    }

    func testReplacingThroughTheBridgeNeedsAnAttachedEditor() {
        let unattached = ComposerDictationBridge()
        unattached.replaceEditorText("text")
        XCTAssertNil(unattached.editorText)

        let editor = Editor("abc")
        editor.bridge.replaceEditorText("xyz")
        XCTAssertEqual(editor.string, "xyz")
        XCTAssertEqual(editor.draft.text, "abc")

        editor.textView.dictationBridge = nil
        editor.bridge.replaceEditorText("")
        XCTAssertEqual(editor.string, "xyz")
    }

    /// The bridge outlives the surface's editors and keeps the text for the
    /// next one: the attached editor's, then what it held when it detached.
    func testTheBridgeKeepsTheEditorTextForTheNextEditor() {
        XCTAssertNil(ComposerDictationBridge().retainedEditorText)

        let editor = Editor("abc")
        XCTAssertEqual(editor.bridge.retainedEditorText, "abc")
        editor.type("d")
        editor.endEvent()
        XCTAssertEqual(editor.bridge.retainedEditorText, "abcd")
        editor.undoManager.undo()
        XCTAssertEqual(editor.bridge.retainedEditorText, "abc")
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")
        XCTAssertEqual(editor.bridge.retainedEditorText, "abc hello")
        editor.bridge.replaceEditorText("")
        XCTAssertEqual(editor.bridge.retainedEditorText, "")

        // The editor goes away. Its text is kept, and a replacement made with
        // no editor is what the next one gets.
        editor.type("x")
        editor.textView.dictationBridge = nil
        XCTAssertNil(editor.bridge.editorText)
        XCTAssertEqual(editor.bridge.retainedEditorText, "x")
        editor.bridge.replaceEditorText("")
        XCTAssertEqual(editor.bridge.retainedEditorText, "")
        XCTAssertEqual(editor.string, "x")
    }

    /// Agent Home builds a new editor when its composer docks or returns to
    /// the start page, in a render whose draft can be out of date. The new
    /// editor starts from the surface's previous editor instead.
    func testANewEditorStartsFromThePreviousEditorsText() {
        let editor = Editor("draft")
        // A surface's first editor has only the draft to start from.
        XCTAssertEqual(
            editor.newEditorText(inARenderShowing: "draft", for: ComposerDictationBridge()),
            "draft")

        editor.type(" more")
        XCTAssertEqual(editor.newEditorText(inARenderShowing: "draft"), "draft more")
        // New conversation clears the draft, then the composer is rebuilt.
        editor.bridge.replaceEditorText("")
        XCTAssertEqual(editor.newEditorText(inARenderShowing: "draft more"), "")
        editor.type("next")

        // The same whether the old editor is still attached when the new one
        // is built or has been taken down first.
        for detachesFirst in [false, true] {
            let bridge = editor.bridge
            if detachesFirst { editor.textView.dictationBridge = nil }
            let rebuilt = ComposerTextView.makeTextView()
            rebuilt.string = editor.newEditorText(inARenderShowing: "draft more")
            rebuilt.dictationBridge = bridge
            XCTAssertEqual(rebuilt.string, "next", "detached first: \(detachesFirst)")
            XCTAssertNil(editor.textView.dictationBridge)
            XCTAssertEqual(bridge.editorText, "next")
            // Back to the first editor for the second pass.
            editor.textView.dictationBridge = bridge
        }
    }

    // MARK: Undo and the draft

    /// The text view undoes and redoes typed text without announcing a text
    /// change. The draft follows anyway.
    func testUndoingTypedTextUpdatesTheDraft() {
        let editor = Editor("abc")
        editor.type("d")
        editor.endEvent()
        XCTAssertEqual(editor.draft.text, "abcd")

        editor.undoManager.undo()
        XCTAssertEqual(editor.string, "abc")
        XCTAssertEqual(editor.draft.text, "abc")
        XCTAssertEqual(editor.draft.selection, 3..<3)
        editor.undoManager.redo()
        XCTAssertEqual(editor.string, "abcd")
        XCTAssertEqual(editor.draft.text, "abcd")
    }

    /// Dictation's own undo step announces its change, so undoing it writes
    /// the draft once.
    func testUndoingDictationWritesTheDraftOnce() {
        let editor = Editor("abc")
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")
        editor.endEvent()
        editor.bridge.end()
        let edits = editor.draft.edits.count

        editor.undoManager.undo()
        XCTAssertEqual(editor.draft.text, "abc")
        XCTAssertEqual(editor.draft.edits.count, edits + 1)
        editor.undoManager.redo()
        XCTAssertEqual(editor.draft.text, "abc hello")
        XCTAssertEqual(editor.draft.edits.count, edits + 2)
    }

    /// After a replacement the caller has written the draft, and typing the
    /// replaced text again is still published.
    func testTypingAfterAReplacementIsPublished() {
        let editor = Editor()
        editor.type("abc")
        editor.bridge.replaceEditorText("")
        editor.draft.text = ""
        editor.type("abc")
        XCTAssertEqual(editor.draft.text, "abc")
    }

    /// A selection the surface sets lands in the editor's text, also when the
    /// render's draft is stale. Emoji take two UTF-16 units per character.
    func testASelectionIsMeasuredInTheEditorText() {
        let editor = Editor("👍👍cd")
        editor.render(text: "abcdef", selection: 2..<2)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 4, length: 0))

        // Han characters before the caret, against a stale draft too short
        // to hold the offset.
        let han = Editor("你好👍abc")
        han.render(text: "你好", selection: 3..<4)
        XCTAssertEqual(han.textView.selectedRange(), NSRange(location: 4, length: 1))
    }

    /// What completing a mention does: the editor gets the completed text,
    /// then the caret is set; the render that carries the caret can still
    /// show the draft from before the completion.
    func testACaretSetAfterAReplacementLandsInTheNewText() {
        let token = PaperMentions.token(for: paper)
        let editor = Editor("见 @att")
        let completed = "见 \(token) "
        editor.bridge.replaceEditorText(completed)
        editor.draft.text = completed
        let caret = completed.count
        editor.render(text: "见 @att", selection: caret..<caret)
        XCTAssertEqual(
            editor.textView.selectedRange(),
            NSRange(location: (completed as NSString).length, length: 0))

        // The same offset set again after another replacement still applies.
        editor.bridge.replaceEditorText("见 " + completed)
        editor.render(text: completed, selection: caret..<caret)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: caret, length: 0))
    }

    /// A render repeating the selection the editor published does nothing,
    /// even with a stale draft.
    func testARenderRepeatingThePublishedSelectionLeavesTheCaret() {
        let editor = Editor("abc")
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertEqual(editor.draft.selection, 1..<1)
        editor.render(text: "", selection: 1..<1)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 1, length: 0))
        editor.render(text: "", selection: nil)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 1, length: 0))
    }

    func testRemovingTheBridgeFromTheEditorEndsTheSession() {
        let editor = Editor()
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")

        editor.textView.dictationBridge = nil
        XCTAssertFalse(editor.bridge.isActive)
        editor.drainMainQueue(for: 0.01)
        XCTAssertEqual(editor.textAtInterruption.count, 1)
        editor.bridge.update(transcript: "hello world")
        XCTAssertEqual(editor.string, "hello")
        XCTAssertFalse(editor.bridge.begin())
    }

    func testMovingTheBridgeToAnotherEditorUnlinksTheFirst() {
        let first = Editor("one")
        let second = Editor("two")
        second.textView.dictationBridge = first.bridge
        XCTAssertNil(first.textView.dictationBridge)

        XCTAssertTrue(first.bridge.begin())
        first.bridge.update(transcript: "hello")
        XCTAssertEqual(second.string, "two hello")
        XCTAssertEqual(first.string, "one")

        // Typing in the editor the bridge left must not end its new session.
        first.type("!")
        XCTAssertEqual(first.string, "one!")
        XCTAssertTrue(first.bridge.isActive)
    }

    func testOnlyOneSessionAtATimeAndEndIsQuiet() {
        let editor = Editor()
        XCTAssertTrue(editor.bridge.begin())
        XCTAssertFalse(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")
        editor.bridge.end()
        XCTAssertFalse(editor.bridge.isActive)
        XCTAssertTrue(editor.textAtInterruption.isEmpty)

        editor.bridge.update(transcript: "late result")
        XCTAssertEqual(editor.string, "hello")
        XCTAssertTrue(editor.bridge.begin())
    }

    // MARK: Undo

    func testUndoRemovesTheWholeDictationAndRedoRestoresIt() {
        let editor = Editor("abc XXX", selection: NSRange(location: 4, length: 3))
        XCTAssertTrue(editor.bridge.begin())
        for transcript in ["hel", "hello", "hello world"] {
            editor.bridge.update(transcript: transcript)
            editor.endEvent()
        }
        editor.bridge.end()
        XCTAssertEqual(editor.string, "abc hello world")

        editor.undoManager.undo()
        XCTAssertEqual(editor.string, "abc XXX")
        XCTAssertEqual(editor.draft.text, "abc XXX")
        XCTAssertFalse(editor.undoManager.canUndo)

        editor.undoManager.redo()
        XCTAssertEqual(editor.string, "abc hello world")
        XCTAssertEqual(editor.draft.text, "abc hello world")

        // Undo and redo keep alternating rather than working only once.
        editor.undoManager.undo()
        XCTAssertEqual(editor.string, "abc XXX")
        editor.undoManager.redo()
        XCTAssertEqual(editor.string, "abc hello world")
    }

    func testUndoStepsBackThroughLaterTypingThenTheDictation() {
        let editor = Editor("Note: ")
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")
        editor.endEvent()
        editor.type("!")
        editor.endEvent()
        XCTAssertEqual(editor.string, "Note: hello!")

        editor.undoManager.undo()
        XCTAssertEqual(editor.string, "Note: hello")
        editor.undoManager.undo()
        XCTAssertEqual(editor.string, "Note: ")
    }

    func testUndoDuringASessionEndsItFirst() {
        let editor = Editor()
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")
        editor.endEvent()

        editor.undoManager.undo()
        XCTAssertEqual(editor.textAtInterruption, ["hello"])
        XCTAssertEqual(editor.string, "")
        editor.bridge.update(transcript: "hello world")
        XCTAssertEqual(editor.string, "")
    }

    func testASessionThatEndsWithNoChangeLeavesNoUndoStep() {
        let editor = Editor("abc")
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")
        editor.endEvent()
        XCTAssertTrue(editor.undoManager.canUndo)

        editor.bridge.update(transcript: "")
        editor.endEvent()
        editor.bridge.end()
        XCTAssertEqual(editor.string, "abc")
        XCTAssertFalse(editor.undoManager.canUndo)
    }

    // MARK: Mentions

    /// The surface reconciles mentions from each (old, new) draft pair it
    /// observes. This replays those pairs the same way.
    private func reconciled(
        _ mentions: [PaperMentionSelection],
        through edits: ArraySlice<(old: String, new: String)>
    ) -> [PaperMentionSelection] {
        edits.reduce(mentions) { PaperMentions.reconciling($0, from: $1.old, to: $1.new) }
    }

    func testMentionsSurviveDictationBeforeAndAfterThem() {
        let token = PaperMentions.token(for: paper)
        let original = "See \(token) for details"
        var mentions = [PaperMentionSelection(reference: paper, range: 4..<(4 + token.count))]
        let editor = Editor(original, selection: NSRange(location: 0, length: 0))
        var seen = 0
        func reconcileAndAssertPresent(file: StaticString = #filePath, line: UInt = #line) {
            mentions = reconciled(mentions, through: editor.draft.edits[seen...])
            seen = editor.draft.edits.count
            XCTAssertEqual(
                PaperMentions.selectionsStillPresent(in: editor.draft.text, from: mentions).count,
                1, file: file, line: line)
        }

        // Dictating before the mention shifts it.
        XCTAssertTrue(editor.bridge.begin())
        for transcript in ["Com", "Compare this", "Compare"] {
            editor.bridge.update(transcript: transcript)
            reconcileAndAssertPresent()
        }
        editor.bridge.end()
        XCTAssertEqual(editor.string, "Compare " + original)
        XCTAssertEqual(mentions.first?.range.lowerBound, 12)

        // Dictating after the mention leaves it where it is.
        let end = (editor.string as NSString).length
        editor.textView.setSelectedRange(NSRange(location: end, length: 0))
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "thanks")
        reconcileAndAssertPresent()
        XCTAssertEqual(editor.string, "Compare " + original + " thanks")
        XCTAssertEqual(mentions.first?.range.lowerBound, 12)
    }

    /// A letter appended to a mention's title drops the mention, and Han
    /// characters are letters that normally take no space.
    func testDictationAtTheEndOfAMentionStaysSeparatedInAnyScript() {
        let token = PaperMentions.token(for: paper)
        let original = "See \(token)"
        let mentions = [PaperMentionSelection(reference: paper, range: 4..<(4 + token.count))]

        let editor = Editor(original)
        XCTAssertTrue(editor.bridge.begin(separatingFromPrecedingText: true))
        editor.bridge.update(transcript: "中文")
        XCTAssertEqual(editor.string, original + " 中文")
        let kept = reconciled(mentions, through: editor.draft.edits[...])
        XCTAssertEqual(
            PaperMentions.selectionsStillPresent(in: editor.draft.text, from: kept).count, 1)

        // Without the flag the same dictation runs into the title.
        let unseparated = Editor(original)
        XCTAssertTrue(unseparated.bridge.begin())
        unseparated.bridge.update(transcript: "中文")
        XCTAssertEqual(unseparated.string, original + "中文")
        XCTAssertTrue(reconciled(mentions, through: unseparated.draft.edits[...]).isEmpty)
    }
}
#endif
