#if os(macOS)
import CloudKit
import GRDB
import XCTest
@testable import RubienCore
@testable import RubienSync

final class SyncIdentityDiagnosticsTests: XCTestCase {
    func testReportsIdentityShapesGateAndBlockedWork() throws {
        let database = try AppDatabase(DatabaseQueue())
        let unresolved = PDFAnnotationRecord.makeRecord(
            recordName: "pdfAnnotation:waiting-child",
            annotation: PDFAnnotationRecord(
                syncId: "waiting-child",
                referenceId: 0,
                referenceSyncId: "missing-parent",
                type: .highlight,
                pageIndex: 0,
                rects: []
            )
        )
        let invalid = Reference.makeRecord(
            recordName: "reference:record-name-id",
            reference: Reference(
                syncId: "mismatched-payload-id",
                title: "Invalid"
            )
        )
        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO reference(syncId, title, dateAdded, dateModified)
                VALUES
                    ('44', 'Legacy', ?, ?),
                    ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'UUID', ?, ?)
                """, arguments: [Date(), Date(), Date(), Date()])
            try db.execute(sql: """
                INSERT INTO syncState(entityType, entityId, isDirty, pushInFlight)
                VALUES
                    ('reference', '44', 1, 0),
                    ('reference', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 1, 0)
                ON CONFLICT(entityType, entityId) DO UPDATE SET isDirty = 1
                """)
            try db.execute(sql: """
                INSERT INTO tombstone(
                    entityType, entityId, confirmedByServer, isPushEligible
                ) VALUES
                    ('reference', '45', 0, 1),
                    ('reference', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 0, 1),
                    ('tag', '46', 0, 0)
                """)
            try SyncEntityType.quarantineRemoteRecord(unresolved, db: db)
            try SyncEntityType.quarantineRemoteRecord(invalid, db: db)
        }

        let diagnostics = try database.dbWriter.read {
            try SyncIdentityDiagnostics.read(from: $0)
        }
        XCTAssertEqual(diagnostics.identitySchemaVersion, 13)
        XCTAssertEqual(
            diagnostics.identityCountsByEntityType["reference"]?.legacy,
            1
        )
        XCTAssertEqual(
            diagnostics.identityCountsByEntityType["reference"]?.uuid,
            1
        )
        XCTAssertEqual(diagnostics.ineligibleLegacyTombstoneCount, 1)
        XCTAssertEqual(diagnostics.quarantinedRecordCount, 2)
        XCTAssertEqual(diagnostics.unresolvedGlobalForeignKeyCount, 1)
        XCTAssertEqual(diagnostics.invalidRemoteRecordCount, 1)
        XCTAssertTrue(diagnostics.fullHistoryReplayPending)
        XCTAssertTrue(diagnostics.writerUpgradeRequired)
        XCTAssertEqual(diagnostics.blockedSaveCount, 1)
        XCTAssertEqual(diagnostics.blockedDeleteCount, 1)

        try database.dbWriter.write {
            try SyncStateStore().acknowledgeWriterUpgrade($0)
        }
        let acknowledged = try database.dbWriter.read {
            try SyncIdentityDiagnostics.read(from: $0)
        }
        XCTAssertFalse(acknowledged.writerUpgradeRequired)
        XCTAssertEqual(acknowledged.blockedSaveCount, 0)
        XCTAssertEqual(acknowledged.blockedDeleteCount, 0)
        XCTAssertNotNil(acknowledged.writerUpgradeAcknowledgedAt)
        XCTAssertEqual(
            acknowledged.writerUpgradeAcknowledgedSchemaVersion,
            "v13"
        )
    }
}
#endif
