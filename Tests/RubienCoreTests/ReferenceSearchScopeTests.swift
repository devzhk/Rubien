import XCTest
import GRDB
@testable import RubienCore

final class ReferenceSearchScopeTests: XCTestCase {
    private func database() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    private func search(_ db: AppDatabase, _ query: String, _ scope: ReferenceSearchScope?) throws -> Set<Int64> {
        var filter = ReferenceFilter()
        filter.keyword = query
        filter.contentScope = scope
        return Set(try db.fetchReferences(scope: .all, filter: filter, limit: 0, orderBy: .relevance).compactMap(\.id))
    }

    func testScopesSeparateMetadataNotesAndBothAnnotationTypes() throws {
        let db = try database()
        var paper = Reference(title: "Scaling laws")
        var note = Reference(title: "Reading notes")
        note.notes = "Scaling needs more data"
        var pdf = Reference(title: "Training compute")
        var web = Reference(title: "A web article")
        try db.saveReference(&paper)
        try db.saveReference(&note)
        try db.saveReference(&pdf)
        try db.saveReference(&web)
        var pdfAnnotation = PDFAnnotationRecord(referenceId: pdf.id!, type: .highlight, selectedText: "Scaling compute", pageIndex: 2, rects: [])
        try db.saveAnnotation(&pdfAnnotation)
        var webAnnotation = WebAnnotationRecord(referenceId: web.id!, type: .note, noteText: "Scaling budgets", anchorText: "budget")
        try db.saveWebAnnotation(&webAnnotation)
        XCTAssertEqual(try search(db, "scaling", .papers), [paper.id!])
        XCTAssertEqual(try search(db, "scaling", .notesAndHighlights), [note.id!, pdf.id!, web.id!])
        XCTAssertEqual(try search(db, "scaling", .everything), [paper.id!, note.id!, pdf.id!, web.id!])
        XCTAssertEqual(try search(db, "scaling", nil), [paper.id!, note.id!], "Legacy clients retain FTS-only search")
    }

    func testEverythingCanMatchTermsAcrossMetadataAndAnnotationsWithoutDuplicates() throws {
        let db = try database()
        var paper = Reference(title: "Scaling")
        try db.saveReference(&paper)
        for _ in 0..<2 {
            var annotation = PDFAnnotationRecord(referenceId: paper.id!, type: .highlight, selectedText: "compute", pageIndex: 0, rects: [])
            try db.saveAnnotation(&annotation)
        }
        var filter = ReferenceFilter()
        filter.contentScope = .everything
        filter.keyword = "scaling compute"
        let refs = try db.fetchReferences(scope: .all, filter: filter, limit: 20, orderBy: .relevance)
        XCTAssertEqual(refs.map(\.id), [paper.id])
        filter.contentScope = .notesAndHighlights
        XCTAssertTrue(try db.fetchReferences(scope: .all, filter: filter).isEmpty)
        filter.keywordOperator = .or
        XCTAssertEqual(try db.fetchReferences(scope: .all, filter: filter).map(\.id), [paper.id])
    }

    func testAnnotationSearchHonorsTagTypeAndYearFilters() throws {
        let db = try database()
        var paper = Reference(title: "Selected paper")
        paper.year = 2025
        var other = Reference(title: "Other paper")
        other.year = 2020
        try db.saveReference(&paper)
        try db.saveReference(&other)
        for reference in [paper, other] {
            var annotation = WebAnnotationRecord(referenceId: reference.id!, type: .highlight, anchorText: "shared phrase")
            try db.saveWebAnnotation(&annotation)
        }
        var tag = Tag(name: "Selected")
        try db.saveTag(&tag)
        try db.setTags(forReference: paper.id!, tagIds: [tag.id!])
        var filter = ReferenceFilter()
        filter.contentScope = .notesAndHighlights
        filter.keyword = "shared"
        filter.yearFrom = 2024
        filter.yearTo = 2026
        filter.referenceType = paper.referenceType
        XCTAssertEqual(try db.fetchReferences(scope: .tag(tag.id!), filter: filter).map(\.id), [paper.id])
        filter.referenceType = .book
        XCTAssertTrue(try db.fetchReferences(scope: .tag(tag.id!), filter: filter).isEmpty)
    }

    func testEmptyNotesScopeOnlyReturnsAnnotatedReferences() throws {
        let db = try database()
        var plain = Reference(title: "Plain")
        var annotated = Reference(title: "Annotated")
        annotated.notes = "My note"
        try db.saveReference(&plain)
        try db.saveReference(&annotated)
        XCTAssertEqual(try search(db, "", .notesAndHighlights), [annotated.id!])
        XCTAssertEqual(try search(db, "\"*()", .notesAndHighlights), [annotated.id!])
    }

    func testAnnotationWildcardsAreLiteralAndQuotesAreSafe() throws {
        let db = try database()
        var actual = Reference(title: "Actual")
        var other = Reference(title: "Other")
        try db.saveReference(&actual)
        try db.saveReference(&other)
        var a = PDFAnnotationRecord(referenceId: actual.id!, type: .note, noteText: "100% value_one", pageIndex: 0, rects: [])
        var b = PDFAnnotationRecord(referenceId: other.id!, type: .note, noteText: "1000 valueXone", pageIndex: 0, rects: [])
        try db.saveAnnotation(&a)
        try db.saveAnnotation(&b)
        XCTAssertEqual(try search(db, "100%", .notesAndHighlights), [actual.id!])
        XCTAssertEqual(try search(db, "\"value_one\"", .notesAndHighlights), [actual.id!])
        XCTAssertNoThrow(try search(db, "\") OR (\"", .everything))
    }

    func testScopedTitleOnlyRetainsSubstringMatching() throws {
        let db = try database()
        var reference = Reference(title: "Bioinformatics methods")
        try db.saveReference(&reference)
        for scope in [ReferenceSearchScope.everything, .papers] {
            var filter = ReferenceFilter()
            filter.keyword = "informatics"
            filter.titleOnly = true
            filter.contentScope = scope
            XCTAssertEqual(try db.fetchReferences(scope: .all, filter: filter).map(\.id), [reference.id])
        }
    }

    func testUnicodeMatchesReferenceNotesAndBothAnnotationTypes() throws {
        let db = try database()
        var note = Reference(title: "Notes")
        note.notes = "Café ÉTUDES"
        var pdf = Reference(title: "PDF")
        var web = Reference(title: "Web")
        try db.saveReference(&note)
        try db.saveReference(&pdf)
        try db.saveReference(&web)
        var pdfAnnotation = PDFAnnotationRecord(referenceId: pdf.id!, type: .highlight, selectedText: "Café ÉTUDES", pageIndex: 0, rects: [])
        var webAnnotation = WebAnnotationRecord(referenceId: web.id!, type: .highlight, anchorText: "Café ÉTUDES")
        try db.saveAnnotation(&pdfAnnotation)
        try db.saveWebAnnotation(&webAnnotation)
        for query in ["cafe", "études", "éTUDes"] {
            XCTAssertEqual(try search(db, query, .notesAndHighlights), [note.id!, pdf.id!, web.id!])
        }
    }

    func testTitleOnlyDoesNotMatchAnnotations() throws {
        let db = try database()
        var paper = Reference(title: "Training")
        paper.notes = "scaling"
        try db.saveReference(&paper)
        var filter = ReferenceFilter()
        filter.contentScope = .everything
        filter.keyword = "scaling"
        filter.titleOnly = true
        XCTAssertTrue(try db.fetchReferences(scope: .all, filter: filter).isEmpty)
    }
}
