#if os(macOS)
import XCTest
import GRDB
@testable import Rubien
@testable import RubienCore

@MainActor
final class LibraryUXTests: XCTestCase {
    func testComfortableBylineHandlesMissingMetadata() {
        var reference = Reference(title: "Example")
        XCTAssertNil(referenceTableByline(reference))
        reference.year = 2025
        XCTAssertEqual(referenceTableByline(reference), "2025")
        reference.authors = [AuthorName(given: "Jane", family: "Doe")]
        XCTAssertEqual(referenceTableByline(reference), "Doe · 2025")
        reference.authors.append(AuthorName(given: "John", family: "Smith"))
        XCTAssertEqual(referenceTableByline(reference), "Doe et al. · 2025")
        reference.authors = [AuthorName(given: "Consortium", family: "")]
        XCTAssertEqual(referenceTableByline(reference), "Consortium · 2025")
    }

    func testCellInvalidatesForSubtitleAndDensity() {
        let compact = EditableStringCell(value: "Paper", isEditing: false, onBeginEdit: {}, onCommit: { _ in }, onCancel: {})
        var comfortable = compact
        comfortable.subtitle = "Doe · 2025"
        comfortable.displayLineLimit = 2
        comfortable.verticalPadding = 6
        XCTAssertNotEqual(compact, comfortable)
        var updated = comfortable
        updated.subtitle = "Smith · 2026"
        XCTAssertNotEqual(comfortable, updated)
        updated = comfortable
        updated.displayLineLimit = 1
        XCTAssertNotEqual(comfortable, updated)
        updated = comfortable
        updated.verticalPadding = 0
        XCTAssertNotEqual(comfortable, updated)
    }

    func testDensityDefaultsAndRestoresSavedChoice() {
        let key = RubienPreferences.referenceTableDensityKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(RubienPreferences.referenceTableDensity, .comfortable)
        UserDefaults.standard.set("compact", forKey: key)
        XCTAssertEqual(RubienPreferences.referenceTableDensity, .compact)
        UserDefaults.standard.set("unknown", forKey: key)
        XCTAssertEqual(RubienPreferences.referenceTableDensity, .comfortable)
    }

    func testExcerptsIncludePDFPageAndExcludeMetadataForNotesScope() throws {
        let db = try AppDatabase(DatabaseQueue(path: ":memory:"))
        var reference = Reference(title: "Paper")
        reference.abstract = "Scaling abstract"
        try db.saveReference(&reference)
        var annotation = PDFAnnotationRecord(referenceId: reference.id!, type: .highlight, selectedText: "Scaling compute together", pageIndex: 2, rects: [])
        try db.saveAnnotation(&annotation)
        let notes = try librarySearchExcerpts(db: db, references: [reference], query: "scaling", scope: .notesAndHighlights, titleOnly: false)
        XCTAssertEqual(notes[reference.id!]?.text, "Scaling compute together")
        XCTAssertTrue(notes[reference.id!]?.source.contains("3") == true)
        let metadata = try librarySearchExcerpts(db: db, references: [reference], query: "scaling", scope: .papers, titleOnly: false)
        XCTAssertEqual(metadata[reference.id!]?.text, "Scaling abstract")
    }

    func testDefaultViewWrapsComfortablyWithoutOverridingSavedChoices() throws {
        let db = try AppDatabase(DatabaseQueue(path: ":memory:"))
        var view = try XCTUnwrap(db.fetchDefaultDatabaseView())
        XCTAssertEqual(referenceTableDefaultWraps(for: view, density: .comfortable), [ColumnIdentifier.title.rawValue])
        XCTAssertEqual(referenceTableDefaultWraps(for: view, density: .compact), [])
        view.dateModified = view.dateCreated.addingTimeInterval(1)
        XCTAssertEqual(referenceTableDefaultWraps(for: view, density: .comfortable), [])
        view.parsedColumnWraps = ["default_abstract"]
        XCTAssertEqual(referenceTableDefaultWraps(for: view, density: .comfortable), ["default_abstract"])
    }

    func testSeededWrappingSurvivesRenameReorderAndReload() throws {
        let db = try AppDatabase(DatabaseQueue(path: ":memory:"))
        var view = try XCTUnwrap(db.fetchDefaultDatabaseView())
        try initializeReferenceTableLayout(for: &view, db: db, density: .comfortable)
        view.name = "My library"
        try db.saveDatabaseView(&view)
        try db.reorderDatabaseViews([999, view.id!])
        let reloaded = try XCTUnwrap(db.fetchDatabaseView(id: view.id!))
        XCTAssertEqual(reloaded.parsedColumnWraps, [ColumnIdentifier.title.rawValue])
        XCTAssertEqual(referenceTableDefaultWraps(for: reloaded, density: .comfortable), reloaded.parsedColumnWraps)
        view.parsedColumnWraps = []
        try db.saveDatabaseView(&view)
        try initializeReferenceTableLayout(for: &view, db: db, density: .comfortable)
        XCTAssertEqual(view.parsedColumnWraps, [], "An explicitly saved unwrapped title must stay unwrapped")
    }

    func testExcerptUsesTheSameLiteralTermsAsSearch() throws {
        let db = try AppDatabase(DatabaseQueue(path: ":memory:"))
        var reference = Reference(title: "Paper")
        reference.notes = "scaling compute"
        try db.saveReference(&reference)
        let excerpts = try librarySearchExcerpts(db: db, references: [reference], query: "sca*ling", scope: .notesAndHighlights, titleOnly: false)
        XCTAssertEqual(excerpts[reference.id!]?.text, "scaling compute")
    }

    func testSnippetKeepsDistantMatchVisibleAndHandlesUnicode() {
        let text = String(repeating: "前文 ", count: 100) + "café training budget" + String(repeating: " more", count: 100)
        let snippet = librarySearchSnippet(text, terms: ["cafe"])
        XCTAssertTrue(snippet?.contains("café") == true)
        XCTAssertTrue(snippet?.hasPrefix("…") == true)
        XCTAssertTrue(snippet?.hasSuffix("…") == true)
        XCTAssertLessThanOrEqual(snippet?.count ?? 0, 182)
        XCTAssertNil(librarySearchSnippet("unrelated", terms: ["scaling"]))
    }
}
#endif
