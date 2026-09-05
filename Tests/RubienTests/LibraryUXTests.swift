#if os(macOS)
import XCTest
import SwiftUI
import GRDB
@testable import Rubien
@testable import RubienCore

@MainActor
final class LibraryUXTests: XCTestCase {
    func testDensityDeterminesTitleWrappingRegardlessOfSavedView() {
        let title = ColumnIdentifier.title.rawValue
        let authors = ColumnIdentifier.authors.rawValue
        for saved: Set<String> in [[], [title], [authors], [title, authors]] {
            XCTAssertTrue(referenceTableWraps(columnID: title, savedWraps: saved, density: .comfortable))
            XCTAssertFalse(referenceTableWraps(columnID: title, savedWraps: saved, density: .compact))
            for density in ReferenceTableDensity.allCases {
                XCTAssertEqual(referenceTableWraps(columnID: authors, savedWraps: saved, density: density),
                               saved.contains(authors))
            }
        }
        let controls = visibleReferenceTableWrappableColumns(propertyDefs: [], isColumnVisible: { _ in true })
        XCTAssertFalse(controls.contains { $0.id == title }, "Density is the sole title-wrapping control")
        XCTAssertTrue(controls.contains { $0.id == authors })
    }

    func testComfortableTableFitsTitleAndBylineAfterMetadataUpdate() async throws {
        try await assertTableFitsUpdatedTitle(subtitle: "Cherubim et al. · 2026")
        try await assertTableFitsUpdatedTitle(subtitle: nil)
    }

    private func assertTableFitsUpdatedTitle(subtitle: String?) async throws {
        var cell = EditableStringCell(
            value: "Helium escaping from the atmosphere of a nearby rocky exoplanet orbiting in a habitable zone",
            isEditing: false, onBeginEdit: {}, onCommit: { _ in }, onCancel: {}
        )
        cell.wrap = true
        cell.subtitle = subtitle
        cell.displayLineLimit = 2
        cell.verticalPadding = 6
        let host = NSHostingController(rootView: cell)
        let full = host.sizeThatFits(in: CGSize(width: 360, height: 1_000))
        let compressed = host.sizeThatFits(in: CGSize(width: 360, height: 40))
        func tableContent(_ title: String) -> some View {
            var reference = Reference(title: title)
            reference.id = 1
            var displayedCell = EditableStringCell(value: title, isEditing: false,
                onBeginEdit: {}, onCommit: { _ in }, onCancel: {})
            displayedCell.wrap = true
            displayedCell.subtitle = cell.subtitle
            displayedCell.displayLineLimit = 2
            displayedCell.verticalPadding = 6
            return Table([reference]) {
                TableColumn("Title") { _ in displayedCell.equatable() }
                    .width(360)
            }
        }
        let tableHost = NSHostingController(rootView: tableContent("Untitled"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        tableHost.view.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
        window.contentViewController = tableHost
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil }
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable($0) }.first
        }
        for _ in 0..<10 {
            tableHost.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        tableHost.rootView = tableContent(cell.value)
        for _ in 0..<10 {
            tableHost.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let table = try XCTUnwrap(findTable(tableHost.view))
        XCTAssertGreaterThanOrEqual(table.rect(ofRow: 0).height, full.height)
        XCTAssertGreaterThan(full.height, 40)
        XCTAssertEqual(compressed.height, full.height, accuracy: 0.5,
                       "The row must measure the entire wrapped title and byline, even with a smaller height proposal")
    }

    func testTitleHeightChangesInvalidateOnlyTheirRowAndCoalesce() async throws {
        final class Table: NSTableView {
            var invalidated: [IndexSet] = []
            override func row(for view: NSView) -> Int { 3 }
            override func noteHeightOfRows(withIndexesChanged indexes: IndexSet) {
                invalidated.append(indexes)
            }
        }
        let table = Table()
        table.usesAutomaticRowHeights = true
        let anchor = ReferenceCellHeightObserver.Anchor()
        table.addSubview(anchor)
        anchor.updateHeight(42)
        anchor.updateHeight(58)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(table.invalidated, [IndexSet(integer: 3)])
        anchor.updateHeight(58)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(table.invalidated.count, 1, "Unchanged measurements must not create a layout loop")
        anchor.updateHeight(74)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(table.invalidated.count, 2)
    }

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
        XCTAssertEqual(view.parsedColumnWraps, [], "Existing saved wrapping data must not be rewritten")
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
