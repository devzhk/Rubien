#if os(macOS)
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

final class PDFMaterializationDiagnosticsTests: XCTestCase {
    func testReportsMissingCacheAndFilesUsingInjectedActiveRoot() throws {
        let database = try AppDatabase(DatabaseQueue())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-pdf-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("pdf".utf8).write(
            to: root.appendingPathComponent("present.pdf")
        )

        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM syncState")
            try db.execute(sql: """
                INSERT INTO reference(
                    syncId, title, dateAdded, dateModified
                ) VALUES
                    ('present', 'Present', ?, ?),
                    ('missing', 'Missing', ?, ?)
                """, arguments: [Date(), Date(), Date(), Date()])
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, syncId FROM reference
                WHERE syncId IN ('present', 'missing')
                """)
            for row in rows {
                let localID: Int64 = row["id"]
                let syncID: String = row["syncId"]
                let filename = syncID == "present" ? "present.pdf" : "missing.pdf"
                try db.execute(sql: """
                    INSERT INTO pdfCache(
                        referenceId, localFilename, contentHash,
                        assetVersion, materializedAt
                    ) VALUES(?, ?, 'hash', 1, ?)
                    """, arguments: [localID, filename, Date()])
            }
            try db.execute(sql: "DELETE FROM syncState")
            for id in ["present", "missing", "no-cache"] {
                try db.execute(sql: """
                    INSERT INTO syncState(entityType, entityId, isDirty)
                    VALUES('referencePDF', ?, 1)
                    """, arguments: [id])
            }
        }

        let diagnostics = try PDFMaterializationDiagnostics.read(
            from: database.dbWriter,
            pdfStorageURL: root
        )

        XCTAssertEqual(diagnostics.checkedDirtyPDFCount, 3)
        XCTAssertEqual(diagnostics.missingCacheCount, 1)
        XCTAssertEqual(diagnostics.missingFileCount, 1)
        XCTAssertEqual(
            Set(diagnostics.issues.map(\.syncId)),
            ["missing", "no-cache"]
        )
    }
}
#endif
