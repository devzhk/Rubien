#if os(macOS)
import XCTest
import GRDB
@testable import Rubien
@testable import RubienCore

@MainActor
final class LibraryViewModelTests: XCTestCase {

    private func makeTestDB() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    // MARK: - Initialization

    func testViewModelInitialState() throws {
        let db = try makeTestDB()
        let vm = LibraryViewModel(db: db)
        XCTAssertEqual(vm.searchText, "")
        XCTAssertFalse(vm.isImporting)
        XCTAssertNil(vm.importProgress)
        XCTAssertNil(vm.errorMessage)
    }

    func testDefaultSidebarSelection() throws {
        let db = try makeTestDB()
        let vm = LibraryViewModel(db: db)
        XCTAssertEqual(vm.selectedSidebar, .allReferences)
    }

    func testExplicitRevealPreemptsDelayedDefaultViewSelection() throws {
        let db = try makeTestDB()
        let vm = LibraryViewModel(db: db)

        vm.selectSidebar(
            .allReferences,
            stashCurrentDraft: false,
            preemptsInitialDefaultView: true
        )
        vm.databaseViews = [try XCTUnwrap(db.fetchDefaultDatabaseView())]
        vm.selectDefaultViewIfNeeded()

        XCTAssertEqual(vm.selectedSidebar, .allReferences)
    }

    // MARK: - Save Reference

    func testSaveReference() throws {
        let db = try makeTestDB()
        let vm = LibraryViewModel(db: db)
        var ref = Reference(title: "ViewModel Save Test")
        vm.saveReference(&ref)
        XCTAssertNotNil(ref.id, "Saved reference should have an ID")
        XCTAssertNil(vm.errorMessage, "No error should occur")
    }

    func testSaveReferenceSetsDateModified() throws {
        let db = try makeTestDB()
        let vm = LibraryViewModel(db: db)
        var ref = Reference(title: "Date Modified Test")
        let before = Date()
        vm.saveReference(&ref)
        XCTAssertGreaterThanOrEqual(ref.dateModified, before)
    }

    func testSaveReferenceReturnsCreatedThenExistingForDuplicate() throws {
        let db = try makeTestDB()
        let vm = LibraryViewModel(db: db)

        var first = Reference(title: "Dedup Target")
        first.doi = "10.1234/dedup.feedback"
        let firstResult = vm.saveReference(&first)
        XCTAssertEqual(firstResult, .created)

        var dup = Reference(title: "Dedup Target (re-added)")
        dup.doi = "10.1234/dedup.feedback"
        let dupResult = vm.saveReference(&dup)
        XCTAssertEqual(dupResult, .existing, "Re-adding the same DOI should merge, not create")
        XCTAssertEqual(dup.id, first.id, "Duplicate should resolve to the existing row")
    }

    func testAddConfirmationMessageDistinguishesCreatedFromExisting() {
        let created = LibraryViewModel.addConfirmationMessage(for: .created)
        let existing = LibraryViewModel.addConfirmationMessage(for: .existing)
        XCTAssertFalse(created.isEmpty)
        XCTAssertFalse(existing.isEmpty)
        XCTAssertNotEqual(created, existing, "Created and duplicate adds must give different feedback")
    }

    func testFlashAddConfirmationSetsToastWithoutTouchingImportProgress() throws {
        let db = try makeTestDB()
        let vm = LibraryViewModel(db: db)
        XCTAssertNil(vm.addConfirmation)
        vm.flashAddConfirmation("Already in your library")
        XCTAssertEqual(vm.addConfirmation?.message, "Already in your library")
        XCTAssertNil(vm.importProgress, "Add confirmation must not clobber bulk-import progress")
    }

    // MARK: - Delete Reference

    func testDeleteReferenceRemovesFromDB() throws {
        let db = try makeTestDB()
        let vm = LibraryViewModel(db: db)
        var ref = Reference(title: "Delete DB Test")
        vm.saveReference(&ref)
        let id = ref.id!

        vm.deleteReferences([ref])
        let fetched = try db.fetchReferences(ids: [id])
        XCTAssertTrue(fetched.isEmpty, "Deleted reference should not be fetchable")
    }

    // MARK: - Tag Management

    func testSaveTag() throws {
        let db = try makeTestDB()
        let vm = LibraryViewModel(db: db)
        var tag = Tag(name: "ViewModel Tag Test", color: "#FF0000")
        vm.saveTag(&tag)
        XCTAssertNotNil(tag.id)
        XCTAssertNil(vm.errorMessage)
    }

    func testDeleteTag() throws {
        let db = try makeTestDB()
        let vm = LibraryViewModel(db: db)
        var tag = Tag(name: "Delete Tag Test")
        vm.saveTag(&tag)
        let id = tag.id!

        vm.deleteTag(id: id)
        let all = try db.fetchAllTags()
        XCTAssertFalse(all.contains(where: { $0.id == id }))
    }

    // MARK: - Error Handling

    func testErrorMessageClearsOnNil() throws {
        let db = try makeTestDB()
        let vm = LibraryViewModel(db: db)
        vm.errorMessage = "Test error"
        XCTAssertEqual(vm.errorMessage, "Test error")
        vm.errorMessage = nil
        XCTAssertNil(vm.errorMessage)
    }
}
#endif
