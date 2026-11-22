#if os(macOS)
import XCTest
import RubienCore
@testable import Rubien

final class ChatPaperAttachTargetTests: XCTestCase {
    private let supplementURL = "https://openaccess.thecvf.com/content/CVPR2026/supplemental/SpeeDiff_supp.pdf"
    private let plainPDFURL = "https://example.com/files/related-paper.pdf"

    private func lookup(
        titles: [Int64: String],
        attachments: [String: Int64] = [:]
    ) -> ChatPaperAttachTarget.Lookup {
        ChatPaperAttachTarget.Lookup(
            titles: { ids in titles.filter { ids.contains($0.key) } },
            attachmentParent: { attachments[$0] })
    }

    // MARK: Bridge payload

    func testRequestValidatesHintsLikeOpenPaperReference() throws {
        let request = try XCTUnwrap(ChatPaperAddRequest(messageBody: [
            "url": supplementURL,
            "title": "  SpeeDiff Supplementary Material  ",
            "parentReferenceId": NSNumber(value: 7),
            "siblingReferenceIds": [NSNumber(value: 7), NSNumber(value: 7), NSNumber(value: 12)],
        ] as [String: Any]))
        XCTAssertEqual(request.url, supplementURL)
        XCTAssertEqual(request.title, "SpeeDiff Supplementary Material")
        XCTAssertEqual(request.parentReferenceId, 7)
        XCTAssertEqual(request.siblingReferenceIds, [7, 12])

        let invalidIDs: [Any] = [
            kCFBooleanTrue as Any, NSNumber(value: 1.5), NSNumber(value: 0), NSNumber(value: -4),
            NSNumber(value: 9_007_199_254_740_992.0), "7", NSNumber(value: Double.infinity),
        ]
        for invalid in invalidIDs {
            let request = try XCTUnwrap(ChatPaperAddRequest(messageBody: [
                "url": supplementURL,
                "parentReferenceId": invalid,
                "siblingReferenceIds": [invalid],
            ] as [String: Any]), "\(invalid)")
            XCTAssertNil(request.parentReferenceId, "\(invalid)")
            XCTAssertEqual(request.siblingReferenceIds, [], "\(invalid)")
        }
        XCTAssertEqual(ChatPaperAddRequest.referenceID(NSNumber(value: 9_007_199_254_740_991.0)),
                       9_007_199_254_740_991)
    }

    func testRequestCapsSiblingsAndRejectsUnsafeURLs() throws {
        let many = (1...25).map { NSNumber(value: $0) }
        let request = try XCTUnwrap(ChatPaperAddRequest(messageBody: [
            "url": plainPDFURL, "siblingReferenceIds": many,
        ] as [String: Any]))
        XCTAssertEqual(request.siblingReferenceIds, Array(1...10))
        XCTAssertEqual(request.title, "")

        XCTAssertNil(ChatPaperAddRequest(messageBody: ["url": "file:///tmp/paper.pdf"]))
        XCTAssertNil(ChatPaperAddRequest(messageBody: ["url": "javascript:alert(1)"]))
        XCTAssertNil(ChatPaperAddRequest(messageBody: ["title": "No URL"]))
        XCTAssertNil(ChatPaperAddRequest(messageBody: "https://example.com/a.pdf"))
    }

    // MARK: Routing

    func testAttachableCandidatesOpenChooserAndOthersKeepAddReferenceFlow() {
        XCTAssertEqual(ChatPaperAddRoute.route(ChatPaperAddRequest(url: supplementURL)), .chooser)
        XCTAssertEqual(ChatPaperAddRoute.route(ChatPaperAddRequest(url: plainPDFURL)), .chooser)
        XCTAssertEqual(
            ChatPaperAddRoute.route(ChatPaperAddRequest(url: "https://example.com/notes/readme.md")),
            .chooser)
        let paper = "https://arxiv.org/abs/2606.24597"
        XCTAssertEqual(ChatPaperAddRoute.route(ChatPaperAddRequest(url: paper)), .addReference(paper))
        let web = "https://example.com/blog/post"
        XCTAssertEqual(ChatPaperAddRoute.route(ChatPaperAddRequest(url: web)), .addReference(web))
    }

    // MARK: Resolver

    func testDeclaredParentRanksFirstAndIsPreselected() {
        let request = ChatPaperAddRequest(
            url: plainPDFURL, title: "Related paper", parentReferenceId: 7, siblingReferenceIds: [12])
        let resolution = ChatPaperAttachTarget.resolve(
            request: request,
            context: .library,
            lookup: lookup(titles: [7: "SpeeDiff: Scalable Diffusion", 12: "Related"]))

        XCTAssertFalse(resolution.looksSupplementary)
        XCTAssertEqual(resolution.suggestions.map(\.referenceId), [7])
        XCTAssertEqual(resolution.suggestions.first?.reason, .assistant)
        XCTAssertEqual(resolution.suggestions.first?.title, "SpeeDiff: Scalable Diffusion",
                       "titles come from the database")
        XCTAssertEqual(resolution.preselected?.referenceId, 7)
    }

    func testCurrentPaperIsListedButPreselectedOnlyForSupplements() {
        let context = AssistantConversationContext.reference(
            ChatReference(id: 3, title: "Stale title", authors: ""))
        let unrelated = ChatPaperAttachTarget.resolve(
            request: ChatPaperAddRequest(url: plainPDFURL, title: "A related paper"),
            context: context,
            lookup: lookup(titles: [3: "Current Paper"]))
        XCTAssertEqual(unrelated.suggestions, [
            .init(referenceId: 3, title: "Current Paper", reason: .currentPaper),
        ])
        XCTAssertNil(unrelated.preselected, "a related PDF defaults to Add as a new reference")

        let supplement = ChatPaperAttachTarget.resolve(
            request: ChatPaperAddRequest(url: supplementURL, title: "Supplementary Material"),
            context: context,
            lookup: lookup(titles: [3: "Current Paper"]))
        XCTAssertTrue(supplement.looksSupplementary)
        XCTAssertEqual(supplement.preselected?.referenceId, 3)
        XCTAssertEqual(supplement.preselected?.reason, .currentPaper)
    }

    func testAttachmentContextSuggestsItsParentReference() {
        let resolution = ChatPaperAttachTarget.resolve(
            request: ChatPaperAddRequest(url: supplementURL, title: "Appendix"),
            context: .attachment(ChatReaderAttachment(syncId: "att-1", title: "Appendix A")),
            lookup: lookup(titles: [5: "Parent Paper"], attachments: ["att-1": 5]))
        XCTAssertEqual(resolution.suggestions.map(\.referenceId), [5])
        XCTAssertEqual(resolution.suggestions.first?.reason, .currentPaper)

        let removed = ChatPaperAttachTarget.resolve(
            request: ChatPaperAddRequest(url: supplementURL, title: "Appendix"),
            context: .attachment(ChatReaderAttachment(syncId: "gone", title: "Appendix A")),
            lookup: lookup(titles: [5: "Parent Paper"], attachments: ["att-1": 5]))
        XCTAssertEqual(removed.suggestions, [])
    }

    func testShownAboveMatchesSiblingShortTitlesOnlyForSupplements() {
        let titles: [Int64: String] = [
            7: "SpeeDiff: Scalable Pixel-Anchored Diffusion",
            8: "Élan — A Study of Things",
            9: "Unrelated Work",
            10: "AB: too short to match",
        ]
        let request = ChatPaperAddRequest(
            url: supplementURL,
            title: "speediff and ELAN — CVPR 2026 Supplementary Material (AB)",
            siblingReferenceIds: [9, 7, 8, 10])
        let resolution = ChatPaperAttachTarget.resolve(
            request: request, context: .library, lookup: lookup(titles: titles))
        XCTAssertEqual(resolution.suggestions.map(\.referenceId), [7, 8])
        XCTAssertTrue(resolution.suggestions.allSatisfy { $0.reason == .shownAbove })
        XCTAssertEqual(resolution.preselected?.referenceId, 7)

        let notSupplement = ChatPaperAttachTarget.resolve(
            request: ChatPaperAddRequest(
                url: plainPDFURL, title: "SpeeDiff follow-up", siblingReferenceIds: [7]),
            context: .library, lookup: lookup(titles: titles))
        XCTAssertEqual(notSupplement.suggestions, [])
        XCTAssertNil(notSupplement.preselected)
    }

    func testRankingDeduplicatesByReferenceAndCapsAtThree() {
        let titles: [Int64: String] = [1: "Alpha Paper", 2: "Beta Paper", 3: "Gamma Paper", 4: "Delta Paper"]
        let request = ChatPaperAddRequest(
            url: supplementURL,
            title: "Alpha Paper Beta Paper Gamma Paper Delta Paper supplement",
            parentReferenceId: 1,
            siblingReferenceIds: [1, 2, 3, 4])
        let resolution = ChatPaperAttachTarget.resolve(
            request: request,
            context: .reference(ChatReference(id: 2, title: "Beta", authors: "")),
            lookup: lookup(titles: titles))
        XCTAssertEqual(resolution.suggestions.map(\.referenceId), [1, 2, 3])
        XCTAssertEqual(resolution.suggestions.map(\.reason), [.assistant, .currentPaper, .shownAbove])
        XCTAssertEqual(resolution.preselected?.reason, .assistant)
    }

    func testDeletedSuggestionsAreDroppedAndNoneLeavesNewReference() {
        let request = ChatPaperAddRequest(
            url: supplementURL, title: "Ghost Paper supplement",
            parentReferenceId: 40, siblingReferenceIds: [41])
        let resolution = ChatPaperAttachTarget.resolve(
            request: request,
            context: .reference(ChatReference(id: 42, title: "Ghost", authors: "")),
            lookup: lookup(titles: [:]))
        XCTAssertEqual(resolution.suggestions, [])
        XCTAssertNil(resolution.preselected)

        let failing = ChatPaperAttachTarget.Lookup(
            titles: { _ in throw ReferenceAttachmentError.busy },
            attachmentParent: { _ in throw ReferenceAttachmentError.busy })
        XCTAssertEqual(
            ChatPaperAttachTarget.resolve(request: request, context: .library, lookup: failing).suggestions,
            [])

        let none = ChatPaperAttachTarget.resolve(
            request: ChatPaperAddRequest(url: plainPDFURL, title: "Paper"),
            context: .library, lookup: lookup(titles: [1: "Unused"]))
        XCTAssertEqual(none.suggestions, [])
        XCTAssertNil(none.preselected)
    }

    func testShortTitleUsesFirstColonOrSpacedDash() {
        XCTAssertEqual(ChatPaperAttachTarget.shortTitle("SpeeDiff: Scalable — Diffusion"), "SpeeDiff")
        XCTAssertEqual(ChatPaperAttachTarget.shortTitle("Graph Nets – A Survey: Part 1"), "Graph Nets")
        XCTAssertEqual(ChatPaperAttachTarget.shortTitle("Pixel-Anchored Diffusion - Extended"), "Pixel-Anchored Diffusion")
        XCTAssertEqual(ChatPaperAttachTarget.shortTitle("No Separator Title"), "No Separator Title")
        XCTAssertNil(ChatPaperAttachTarget.shortTitle("AB: Too short"))
        XCTAssertNil(ChatPaperAttachTarget.shortTitle(": Leading colon"))
    }
}
#endif
