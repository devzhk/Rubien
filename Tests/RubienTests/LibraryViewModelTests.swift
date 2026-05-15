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
