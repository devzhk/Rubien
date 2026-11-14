#if os(macOS)
import XCTest
@testable import Rubien

/// The mention rules the composer relies on while dictating: bringing mentions up
/// to date before a send, and spacing dictation away from a completed mention.
final class PaperMentionsDictationTests: XCTestCase {
    private let attention = ChatReference(
        id: 7,
        title: "Attention Is All You Need",
        authors: "Vaswani et al.")

    private func mention(in text: String) -> PaperMentionSelection {
        let token = PaperMentions.token(for: attention)
        let range = text.range(of: token)!
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        return PaperMentionSelection(reference: attention, range: lower..<(lower + token.count))
    }

    // MARK: Bringing mentions up to date

    /// A dictation edit and ⌘↩ in the same run-loop turn: the draft already holds
    /// the dictated text, the mentions still match the draft before it.
    func testStaleMentionsSurviveSendOnceBroughtUpToDate() {
        let reconciled = "@Attention Is All You Need compare"
        let draft = "Note: @Attention Is All You Need compare"
        let stale = [mention(in: reconciled)]

        XCTAssertTrue(
            PaperMentions.selectionsStillPresent(in: draft, from: stale).isEmpty,
            "Without reconciling first, the send-time check drops the mention")

        let current = PaperMentions.updating(stale, reconciledAgainst: reconciled, to: draft)
        XCTAssertEqual(current, [mention(in: draft)])
        XCTAssertEqual(PaperMentions.selectionsStillPresent(in: draft, from: current), current)
    }

    func testMentionBeforeDictatedTextKeepsItsRange() {
        let reconciled = "@Attention Is All You Need "
        let draft = "@Attention Is All You Need compare with recurrence"
        let current = PaperMentions.updating(
            [mention(in: reconciled)], reconciledAgainst: reconciled, to: draft)
        XCTAssertEqual(current.map(\.range), [0..<26])
    }

    /// The deferred `onChange` runs after send already brought the mentions up to
    /// date. It must not apply the same edit again.
    func testUpdatingAgainstTheCurrentDraftChangesNothing() {
        let draft = "Note: @Attention Is All You Need compare"
        let current = [mention(in: draft)]
        XCTAssertEqual(PaperMentions.updating(current, reconciledAgainst: draft, to: draft), current)

        let reapplied = PaperMentions.reconciling(
            current, from: "@Attention Is All You Need compare", to: draft)
        XCTAssertTrue(reapplied.isEmpty, "Applying the edit twice would have dropped it")
    }

    func testEditInsideAMentionStillDropsIt() {
        let reconciled = "@Attention Is All You Need"
        let draft = "@Attention Is Not All You Need"
        XCTAssertTrue(PaperMentions.updating(
            [mention(in: reconciled)], reconciledAgainst: reconciled, to: draft).isEmpty)
    }

    // MARK: Caret at the end of a mention

    func testCaretAtTheEndOfAMention() {
        let text = "See @Attention Is All You Need"
        let mentions = [mention(in: text)]
        let end = text.count
        XCTAssertTrue(PaperMentions.caretEndsMention(end..<end, in: text, mentions: mentions))
    }

    func testCaretAfterTheMentionsTrailingSpaceDoesNotCount() {
        let text = "See @Attention Is All You Need "
        let mentions = [mention(in: text)]
        let end = text.count
        XCTAssertFalse(PaperMentions.caretEndsMention(end..<end, in: text, mentions: mentions))
    }

    func testCaretInsideOrBeforeAMentionDoesNotCount() {
        let text = "See @Attention Is All You Need"
        let mentions = [mention(in: text)]
        XCTAssertFalse(PaperMentions.caretEndsMention(4..<4, in: text, mentions: mentions))
        XCTAssertFalse(PaperMentions.caretEndsMention(10..<10, in: text, mentions: mentions))
    }

    func testSelectionOrMissingCaretDoesNotCount() {
        let text = "See @Attention Is All You Need"
        let mentions = [mention(in: text)]
        XCTAssertFalse(PaperMentions.caretEndsMention(4..<text.count, in: text, mentions: mentions))
        XCTAssertFalse(PaperMentions.caretEndsMention(nil, in: text, mentions: mentions))
        XCTAssertFalse(PaperMentions.caretEndsMention(text.count..<text.count, in: text, mentions: []))
    }

    func testMentionNoLongerInTheTextDoesNotCount() {
        let original = "See @Attention Is All You Need"
        let edited = "See @Attention Is All You Nee"
        let stale = [mention(in: original)]
        let end = original.count
        XCTAssertFalse(PaperMentions.caretEndsMention(end..<end, in: edited, mentions: stale))
    }

    func testOffsetsAreCharactersNotUTF16() {
        let text = "看 👩‍💻 @Attention Is All You Need"
        let mentions = [mention(in: text)]
        let end = text.count
        XCTAssertNotEqual(end, (text as NSString).length)
        XCTAssertTrue(PaperMentions.caretEndsMention(end..<end, in: text, mentions: mentions))
    }
}
#endif
