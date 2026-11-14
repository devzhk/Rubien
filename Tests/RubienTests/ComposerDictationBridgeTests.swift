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

        /// - Parameter selection: UTF-16 range; defaults to a caret at the end.
        init(_ text: String = "", selection: NSRange? = nil) {
            let draft = Draft(text: text)
            let bridge = ComposerDictationBridge()
            self.draft = draft
            self.bridge = bridge
            coordinator = ComposerTextView.Coordinator(ComposerTextView(
                text: Binding(
                    get: { draft.text },
                    set: { new in
                        draft.edits.append((old: draft.text, new: new))
                        draft.text = new
                        let hook = draft.onNextEdit
                        draft.onNextEdit = nil
                        hook?()
                    }),
                selection: Binding(get: { draft.selection }, set: { draft.selection = $0 }),
                focusRequestCount: 0,
                onCommandReturn: {},
                onNavigationKey: { _ in false },
                onAttachFiles: { _ in },
                onAttachImageData: { _, _ in },
                onDragTargeted: { _ in },
                dictationBridge: bridge))

            textView.delegate = coordinator
            textView.string = text
            textView.setSelectedRange(
                selection ?? NSRange(location: (text as NSString).length, length: 0))
            textView.dictationBridge = bridge
            bridge.onInterruption = { [unowned self] in
                textAtInterruption.append(textView.string)
            }
        }

        var string: String { textView.string }
        var undoManager: UndoManager { coordinator.undoManager }

        func type(_ text: String) {
            textView.insertText(text, replacementRange: textView.selectedRange())
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
        let editor = Editor()
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")

        editor.coordinator.syncExternalText("", into: editor.textView)
        XCTAssertEqual(editor.textAtInterruption, ["hello"])
        XCTAssertEqual(editor.string, "")
        XCTAssertFalse(editor.undoManager.canUndo)

        editor.bridge.update(transcript: "hello world")
        XCTAssertEqual(editor.string, "")
    }

    func testRemovingTheBridgeFromTheEditorEndsTheSession() {
        let editor = Editor()
        XCTAssertTrue(editor.bridge.begin())
        editor.bridge.update(transcript: "hello")

        editor.textView.dictationBridge = nil
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
