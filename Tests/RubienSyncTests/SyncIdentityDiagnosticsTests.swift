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
        XCTAssertEqual(diagnostics.contradictoryIntentCount, 0)
        XCTAssertEqual(diagnostics.pushInFlightCount, 0)

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
            "v14"
        )
    }

    func testReportsDurableIntentAndPDFAnomalies() throws {
        let database = try AppDatabase(DatabaseQueue())
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM syncState")
            try db.execute(sql: "DELETE FROM tombstone")
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES
                    ('live-untracked', 'Untracked', '#fff', ?),
                    ('live-clean', 'Clean', '#fff', ?),
                    ('live-overlap', 'Overlap', '#fff', ?)
                """, arguments: [Date(), Date(), Date()])
            try db.execute(sql: "DELETE FROM syncState")
            let store = SyncStateStore()
            for source in SyncLocalEntityCatalog.current {
                for id in try source.identities(db) {
                    try store.queueSave(
                        db,
                        entityType: try XCTUnwrap(
                            SyncEntityType(rawValue: source.entityType)
                        ),
                        entityId: id
                    )
                }
            }
            try store.removeState(
                db,
                entityType: .tag,
                entityId: "live-untracked"
            )
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, isDirty, pushInFlight
                ) VALUES
                    ('tag', 'live-clean', 0, 0),
                    ('tag', 'live-overlap', 1, 1),
                    ('tag', 'clean-orphan', 0, 0),
                    ('tag', 'dirty-orphan', 1, 0),
                    ('referencePDF', 'missing-pdf-cache', 1, 0),
                    ('referencePDF', '42', 1, 0)
                ON CONFLICT(entityType, entityId) DO UPDATE SET
                    isDirty=excluded.isDirty,
                    pushInFlight=excluded.pushInFlight,
                    systemFields=NULL,
                    lastPushedAt=NULL
                """)
            try db.execute(sql: """
                INSERT INTO tombstone(
                    entityType, entityId, confirmedByServer, isPushEligible
                ) VALUES('tag', 'live-overlap', 0, 1)
                """)
            try db.execute(sql: """
                INSERT INTO syncSession(key, value)
                VALUES('baselineState', 'complete')
                ON CONFLICT(key) DO UPDATE SET value='complete'
                """)
        }

        let diagnostics = try database.dbWriter.read {
            try SyncIdentityDiagnostics.read(from: $0)
        }
        XCTAssertEqual(diagnostics.contradictoryIntentCount, 1)
        XCTAssertEqual(diagnostics.pushInFlightCount, 1)
        XCTAssertEqual(diagnostics.removableOrphanSyncStateCount, 1)
        XCTAssertEqual(diagnostics.preservedOrphanSyncStateCount, 3)
        XCTAssertEqual(diagnostics.unpublishedLiveEntityCount, 2)
        XCTAssertEqual(diagnostics.missingPDFCacheUploadCount, 2)
        XCTAssertEqual(diagnostics.stalePDFIdentityCount, 1)
        XCTAssertEqual(diagnostics.ambiguousPDFIdentityCount, 1)
    }

    func testCanonicalNumericPDFIdentityIsNotReportedAsStale() throws {
        let database = try AppDatabase(DatabaseQueue())
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM syncState")
            try db.execute(sql: """
                INSERT INTO reference(
                    id, syncId, title, dateAdded, dateModified
                ) VALUES(42, '42', 'Legacy PDF owner', ?, ?)
                """, arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId, localFilename, contentHash, assetVersion,
                    materializedAt
                ) VALUES(42, 'legacy.pdf', 'hash', 1, ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, isDirty, pushInFlight
                ) VALUES('referencePDF', '42', 1, 0)
                """)
        }

        let diagnostics = try database.dbWriter.read {
            try SyncIdentityDiagnostics.read(from: $0)
        }
        XCTAssertEqual(diagnostics.stalePDFIdentityCount, 0)
        XCTAssertEqual(diagnostics.ambiguousPDFIdentityCount, 0)
    }

    func testAmbiguousNumericPDFCollisionIsReportedAndPreserved() throws {
        let database = try AppDatabase(DatabaseQueue())
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM syncState")
            try db.execute(sql: """
                INSERT INTO reference(
                    id, syncId, title, dateAdded, dateModified
                ) VALUES
                    (42, 'reference-uuid', 'Legacy interpretation', ?, ?),
                    (43, '42', 'Canonical interpretation', ?, ?)
                """, arguments: [Date(), Date(), Date(), Date()])
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId, localFilename, contentHash, assetVersion,
                    materializedAt
                ) VALUES
                    (42, 'legacy.pdf', 'legacy-hash', 1, ?),
                    (43, 'canonical.pdf', 'canonical-hash', 1, ?)
                """, arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO syncState(
                    entityType, entityId, isDirty, pushInFlight
                ) VALUES('referencePDF', '42', 1, 0)
                """)
        }

        let diagnostics = try database.dbWriter.read {
            try SyncIdentityDiagnostics.read(from: $0)
        }
        XCTAssertEqual(diagnostics.stalePDFIdentityCount, 1)
        XCTAssertEqual(diagnostics.ambiguousPDFIdentityCount, 1)
    }

    func testLiveRowWithActiveDeleteIsNotReportedAsUnpublished() throws {
        let database = try AppDatabase(DatabaseQueue())
        try database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM syncState")
            try db.execute(sql: "DELETE FROM tombstone")
            try db.execute(sql: """
                INSERT INTO tag(syncId, name, color, dateModified)
                VALUES('pending-delete', 'Fetched Again', '#fff', ?)
                """, arguments: [Date()])
            let store = SyncStateStore()
            for source in SyncLocalEntityCatalog.current {
                let type = try XCTUnwrap(
                    SyncEntityType(rawValue: source.entityType)
                )
                for id in try source.identities(db) {
                    try store.queueSave(db, entityType: type, entityId: id)
                }
            }
            try store.removeState(
                db,
                entityType: .tag,
                entityId: "pending-delete"
            )
            try db.execute(sql: """
                INSERT INTO tombstone(
                    entityType, entityId, confirmedByServer, isPushEligible
                ) VALUES('tag', 'pending-delete', 0, 1)
                """)
            try db.execute(sql: """
                INSERT INTO syncSession(key, value)
                VALUES('baselineState', 'complete')
                ON CONFLICT(key) DO UPDATE SET value='complete'
                """)
        }

        let diagnostics = try database.dbWriter.read {
            try SyncIdentityDiagnostics.read(from: $0)
        }
        XCTAssertEqual(diagnostics.unpublishedLiveEntityCount, 0)
    }
}
#endif
