import XCTest
import GRDB
@testable import RubienCore

final class MigrationV2Tests: XCTestCase {

    func testV2CreatesPdfCacheTable() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.dbWriter.read { db in
            let cols = try Row.fetchAll(db, sql: "SELECT name FROM pragma_table_info('pdfCache')")
                .map { $0["name"] as String }
            XCTAssertEqual(
                Set(cols),
                Set(["referenceId", "localFilename", "contentHash", "assetVersion", "materializedAt", "lastOpenedAt"]),
                "pdfCache schema must match the spec"
            )
        }
    }

    func testV2CreatesPdfUploadQueueTable() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.dbWriter.read { db in
            let cols = try Row.fetchAll(db, sql: "SELECT name FROM pragma_table_info('pdfUploadQueue')")
                .map { $0["name"] as String }
            XCTAssertEqual(
                Set(cols),
                Set(["referenceId", "localFilename", "queuedAt"]),
                "pdfUploadQueue schema must match the spec"
            )
        }
    }
}
