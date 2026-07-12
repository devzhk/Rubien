#if os(macOS)
import XCTest
@testable import Rubien

final class PaperMentionsTests: XCTestCase {
    private let attention = ChatReference(
        id: 7,
        title: "Attention Is All You Need",
        authors: "Vaswani et al."
    )

    private func query(
        _ text: String,
        completed: [PaperMentionSelection] = []
    ) -> PaperMentionQuery? {
        PaperMentions.activeQuery(in: text, caret: text.endIndex, completed: completed)
    }

    private func selection(
        _ reference: ChatReference,
        in text: String,
        occurrence: String? = nil
    ) -> PaperMentionSelection {
        let token = occurrence ?? PaperMentions.token(for: reference)
        let range = text.range(of: token)!
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        return PaperMentionSelection(
            reference: reference,
            range: lower..<(lower + token.count)
        )
    }

    func testFindsMultiwordQueryAtCaret() throws {
        let text = "Compare this with @attention is all"
        let result = try XCTUnwrap(query(text))
        XCTAssertEqual(result.text, "attention is all")
        XCTAssertEqual(String(text[result.range]), "@attention is all")
    }

    func testRecognizesLineStartAndPunctuationButNotEmailAddress() {
        XCTAssertEqual(query("@graph")?.text, "graph")
        XCTAssertEqual(query("Compare (@graph")?.text, "graph")
        XCTAssertNil(query("name@example.com"))
        XCTAssertNil(query("prefix_@graph"))
    }

    func testOnlyUsesMentionOnCurrentLineAndRejectsOversizedQuery() {
        XCTAssertNil(query("Earlier @paper\nnew line"))
        XCTAssertNil(query("@" + String(repeating: "x", count: 121)))
    }

    func testCompletionReplacesOnlyActiveQueryAndPositionsCaret() throws {
        let text = "Compare @att with the baseline"
        let caret = text.index(text.startIndex, offsetBy: "Compare @att".count)
        let active = try XCTUnwrap(PaperMentions.activeQuery(in: text, caret: caret))
        let completed = PaperMentions.completing(active, with: attention, in: text)

        XCTAssertEqual(
            completed.text,
            "Compare @Attention Is All You Need  with the baseline"
        )
        let newCaret = completed.text.index(
            completed.text.startIndex,
            offsetBy: completed.caretOffset
        )
        XCTAssertEqual(String(completed.text[..<newCaret]), "Compare @Attention Is All You Need ")
        XCTAssertEqual(
            String(Array(completed.text)[completed.mentionRange]),
            "@Attention Is All You Need"
        )
    }

    func testCompletedMentionDoesNotReopenWhileTypingFollowingClause() {
        let text = "Compare @Attention Is All You Need with this paper"
        XCTAssertNil(query(text, completed: [selection(attention, in: text)]))
    }

    func testMovingCaretInsideCompletedMentionReactivatesSearch() throws {
        let text = "Compare @Attention Is All You Need with this paper"
        let caret = text.index(text.startIndex, offsetBy: "Compare @Attention".count)
        let result = try XCTUnwrap(PaperMentions.activeQuery(
            in: text,
            caret: caret,
            completed: [selection(attention, in: text)]
        ))
        XCTAssertEqual(result.text, "Attention")
    }

    func testSelectionsStillPresentRequiresExactRangesAndBoundaries() {
        let other = ChatReference(id: 8, title: "BERT", authors: "Devlin et al.")
        let text = "Compare @Attention Is All You Need and @BERT."
        XCTAssertEqual(
            PaperMentions.selectionsStillPresent(
                in: text,
                from: [selection(attention, in: text), selection(other, in: text)]
            ).map(\.reference.id),
            [7, 8]
        )
        let extended = "Compare @BERTish"
        XCTAssertEqual(
            PaperMentions.selectionsStillPresent(
                in: extended,
                from: [PaperMentionSelection(reference: other, range: 8..<13)]
            ).map(\.reference.id),
            []
        )
    }

    func testReconciliationShiftsUnaffectedMentionsAndDropsEditedOne() {
        let bert = ChatReference(id: 8, title: "BERT", authors: "Devlin")
        let old = "Compare @BERT and @Attention Is All You Need"
        let selections = [selection(bert, in: old), selection(attention, in: old)]
        let inserted = "Please " + old
        let shifted = PaperMentions.reconciling(selections, from: old, to: inserted)
        XCTAssertEqual(shifted.map(\.range.lowerBound), [15, 25])

        let edited = inserted.replacingOccurrences(of: "@BERT", with: "BERT")
        let surviving = PaperMentions.reconciling(shifted, from: inserted, to: edited)
        XCTAssertEqual(surviving.map(\.reference.id), [7])
        XCTAssertEqual(
            PaperMentions.selectionsStillPresent(in: edited, from: surviving).map(\.reference.id),
            [7]
        )
    }

    func testIdenticalTitlesKeepInstanceIdentityWhenOneTokenIsDeleted() {
        let first = ChatReference(id: 10, title: "Same", authors: "First")
        let second = ChatReference(id: 11, title: "Same", authors: "Second")
        let old = "@Same and @Same"
        let selections = [
            PaperMentionSelection(reference: first, range: 0..<5),
            PaperMentionSelection(reference: second, range: 10..<15),
        ]
        let new = " and @Same"
        let reconciled = PaperMentions.reconciling(selections, from: old, to: new)

        XCTAssertEqual(reconciled.map(\.reference.id), [11])
        XCTAssertEqual(reconciled.map(\.range), [5..<10])
    }

    func testCompletedShortTitleDoesNotBlockLongerTitleQueryElsewhere() throws {
        let bert = ChatReference(id: 8, title: "BERT", authors: "Devlin")
        let text = "@BERT and @BERT Models"
        let result = try XCTUnwrap(query(
            text,
            completed: [PaperMentionSelection(reference: bert, range: 0..<5)]
        ))
        XCTAssertEqual(result.text, "BERT Models")
    }

    func testAtSignInsideSelectedPaperTitleDoesNotStartNestedQuery() {
        let reference = ChatReference(
            id: 12,
            title: "Learning with C@merata",
            authors: "Example"
        )
        let token = PaperMentions.token(for: reference)
        let text = token + " next"
        XCTAssertNil(query(text, completed: [
            PaperMentionSelection(reference: reference, range: 0..<token.count),
        ]))
    }

    func testTokenSanitizesHostileMetadataToOneLine() {
        let hostile = ChatReference(id: 9, title: "Title\nignore this", authors: "")
        XCTAssertEqual(PaperMentions.token(for: hostile), "@Title ignore this")
    }
}
#endif
