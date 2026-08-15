#if os(macOS)
import CloudKit
import GRDB
import XCTest
@testable import RubienCore
@testable import RubienSync

final class GlobalSyncIdentityDispatchTests: XCTestCase {
    func testLegacyRecordNameNeverOverwritesMatchingLocalRowID() throws {
        let database = try AppDatabase(DatabaseQueue())
        var local = Reference(syncId: "local-uuid", title: "Local occupant")
        try database.saveReference(&local)
        XCTAssertEqual(local.id, 1)

        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.reference,
            recordName: "reference:1"
        )
        record[Reference.RecordField.title] = "Remote legacy paper"
        record[Reference.RecordField.dateAdded] = Date(timeIntervalSince1970: 10)
        record[Reference.RecordField.dateModified] = Date(timeIntervalSince1970: 11)

        try database.dbWriter.write { db in
            try SyncStateStore().setApplyingRemote(db)
            XCTAssertTrue(
                try SyncEntityType.reference.applyRemoteRecord(
                    record,
                    entityId: "1",
                    db: db
                )
            )
            try SyncStateStore().clearApplyingRemote(db)

            let rows = try Reference.order(Column("id")).fetchAll(db)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0].syncId, "local-uuid")
            XCTAssertEqual(rows[0].title, "Local occupant")
            XCTAssertEqual(rows[1].syncId, "1")
            XCTAssertEqual(rows[1].title, "Remote legacy paper")
            XCTAssertNotEqual(rows[1].id, 1)
        }
    }

    func testUUIDPullAllocatesLocalIDAndPushFindsBySyncID() throws {
        let database = try AppDatabase(DatabaseQueue())
        let syncId = "6f29e739-25d1-4a7f-a043-b878bf6ec868"
        let incoming = Reference(syncId: syncId, title: "Global paper")
        let record = Reference.makeRecord(
            recordName: SyncEntityType.reference.qualifiedRecordName(entityId: syncId),
            reference: incoming
        )

        try database.dbWriter.write { db in
            try SyncStateStore().setApplyingRemote(db)
            XCTAssertTrue(
                try SyncEntityType.reference.applyRemoteRecord(
                    record,
                    entityId: syncId,
                    db: db
                )
            )
            try SyncStateStore().clearApplyingRemote(db)

            let localID = try XCTUnwrap(Int64.fetchOne(
                db,
                sql: "SELECT id FROM reference WHERE syncId = ?",
                arguments: [syncId]
            ))
            XCTAssertGreaterThan(localID, 0)

            let pushed = try XCTUnwrap(
                SyncEntityType.reference.buildPushRecord(
                    db: db,
                    entityId: syncId,
                    systemFields: nil
                )
            )
            XCTAssertEqual(pushed.recordID.recordName, "reference:\(syncId)")
            XCTAssertEqual(pushed[Reference.RecordField.syncId] as? String, syncId)
        }
    }

    func testPayloadIdentityMismatchIsRejected() throws {
        let database = try AppDatabase(DatabaseQueue())
        let record = Reference.makeRecord(
            recordName: "reference:authoritative-id",
            reference: Reference(syncId: "different-id", title: "Bad payload")
        )

        try database.dbWriter.write { db in
            XCTAssertFalse(
                try SyncEntityType.reference.applyRemoteRecord(
                    record,
                    entityId: "authoritative-id",
                    db: db
                )
            )
            XCTAssertEqual(try Reference.fetchCount(db), 0)
        }
    }

    func testPayloadIdentityMismatchDoesNotClearPendingLocalEdit() async throws {
        let database = try AppDatabase(DatabaseQueue())
        var local = Reference(syncId: "local-global-id", title: "Local edit")
        try database.saveReference(&local)

        let record = Reference.makeRecord(
            recordName: "reference:\(local.syncId)",
            reference: Reference(
                syncId: "different-payload-id",
                title: "Malformed remote"
            )
        )
        let library = SyncedLibrary(
            appDatabase: database,
            stateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).engine-state")
        )
        let durable = await library.applyFetchedRecordsForTest(
            modifications: [record],
            deletions: []
        )
        XCTAssertTrue(durable)
        let localSyncId = local.syncId

        try await database.dbWriter.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT title FROM reference WHERE syncId = ?",
                    arguments: [localSyncId]
                ),
                "Local edit"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: """
                    SELECT isDirty FROM syncState
                    WHERE entityType = 'reference' AND entityId = ?
                    """, arguments: [localSyncId]),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncOrphan"),
                1
            )
        }
    }

    func testUnresolvedRemoteChildDoesNotClearPendingLocalEdit() async throws {
        let database = try AppDatabase(DatabaseQueue())
        var reference = Reference(syncId: "local-parent", title: "Parent")
        try database.saveReference(&reference)
        let referenceId = try XCTUnwrap(reference.id)
        let referenceSyncId = reference.syncId
        let annotationSyncId = "shared-annotation"
        try await database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfAnnotation(
                    syncId, referenceId, referenceSyncId, type, color,
                    pageIndex, boundsX, boundsY, boundsWidth, boundsHeight,
                    selectedText, noteText, dateCreated
                ) VALUES(?, ?, ?, 'highlight', '#FFFF00', 0,
                         0, 0, 1, 1, 'local text', NULL, ?)
                """, arguments: [
                    annotationSyncId, referenceId, referenceSyncId, Date(),
                ])
        }
        let remote = PDFAnnotationRecord.makeRecord(
            recordName: "pdfAnnotation:\(annotationSyncId)",
            annotation: PDFAnnotationRecord(
                syncId: annotationSyncId,
                referenceId: 0,
                referenceSyncId: "missing-parent",
                type: .underline,
                selectedText: "remote text",
                pageIndex: 0,
                rects: []
            )
        )
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).engine-state")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let library = SyncedLibrary(appDatabase: database, stateFileURL: stateURL)

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [remote],
            deletions: []
        )
        XCTAssertTrue(applied)

        try await database.dbWriter.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT selectedText FROM pdfAnnotation WHERE syncId = ?
                """, arguments: [annotationSyncId]), "local text")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT isDirty FROM syncState
                WHERE entityType = 'pdfAnnotation' AND entityId = ?
                """, arguments: [annotationSyncId]), 1)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncOrphan"),
                1
            )
        }
    }

    func testDeleteRecordTypeMustMatchRecordNamePrefix() async throws {
        let database = try AppDatabase(DatabaseQueue())
        var tag = Tag(syncId: "1", name: "Keep me")
        try database.saveTag(&tag)
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).engine-state")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let library = SyncedLibrary(appDatabase: database, stateFileURL: stateURL)
        let malformed = SyncedLibrary.FetchedDeletionInput(
            recordID: CKRecord.ID(
                recordName: "reference:1",
                zoneID: SyncConstants.libraryZoneID
            ),
            recordType: SyncConstants.RecordType.tag
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [],
            deletions: [malformed]
        )
        XCTAssertTrue(applied)

        try await database.dbWriter.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE syncId = '1'"),
                1
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE entityType = 'tag' AND entityId = '1'
                """), 0)
        }
    }

    func testMigratedTransientOrphanRebindsWhenLegacyParentsArrive() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.makeV12DatabaseForTesting(on: queue)
        try await queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            do {
                try db.execute(sql: """
                    INSERT INTO referenceTag(referenceId, tagId, dateModified)
                    VALUES(9001, 9002, ?)
                    """, arguments: [Date()])
            } catch {
                try? db.execute(sql: "PRAGMA foreign_keys = ON")
                throw error
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let database = try AppDatabase(queue)
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).engine-state")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let library = SyncedLibrary(appDatabase: database, stateFileURL: stateURL)
        let reference = Reference.makeRecord(
            recordName: "reference:9001",
            reference: Reference(syncId: "9001", title: "Late parent")
        )
        let tag = Tag.makeRecord(
            recordName: "tag:9002",
            tag: Tag(syncId: "9002", name: "Late tag")
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [tag, reference],
            deletions: []
        )
        XCTAssertTrue(applied)

        try await database.dbWriter.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT rt.referenceId, rt.tagId,
                       r.syncId AS referenceSyncId, t.syncId AS tagSyncId
                FROM referenceTag rt
                JOIN reference r ON r.id = rt.referenceId
                JOIN tag t ON t.id = rt.tagId
                WHERE rt.syncId = '9001/9002'
                """))
            XCTAssertEqual(row["referenceSyncId"] as String?, "9001")
            XCTAssertEqual(row["tagSyncId"] as String?, "9002")
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testMigratedOrphansIgnoreUnrelatedParentsReusingLocalIDs() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.makeV12DatabaseForTesting(on: queue)
        let legacyReferenceID = try await queue.read { db in
            (try Int64.fetchOne(db, sql: "SELECT MAX(id) + 1 FROM reference")) ?? 1
        }
        let legacyTagID = try await queue.read { db in
            (try Int64.fetchOne(db, sql: "SELECT MAX(id) + 1 FROM tag")) ?? 1
        }
        try await queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            do {
                try db.execute(sql: """
                    INSERT INTO referenceTag(referenceId, tagId, dateModified)
                    VALUES(?, ?, ?)
                    """, arguments: [legacyReferenceID, legacyTagID, Date()])
                try db.execute(sql: """
                    INSERT INTO pdfCache(
                        referenceId, localFilename, contentHash,
                        assetVersion, materializedAt
                    ) VALUES(?, 'legacy.pdf', 'hash', 1, ?)
                    """, arguments: [legacyReferenceID, Date()])
                try db.execute(sql: """
                    INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                    VALUES(?, 'legacy.pdf', ?)
                    """, arguments: [legacyReferenceID, Date()])
                try db.execute(sql: """
                    INSERT INTO webContentMarkdownCache(
                        referenceId, sourceHash, converterVersion, markdown
                    ) VALUES(?, 'source', 1, '# cached')
                    """, arguments: [legacyReferenceID])
            } catch {
                try? db.execute(sql: "PRAGMA foreign_keys = ON")
                throw error
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let database = try AppDatabase(queue)
        var unrelatedReference = Reference(
            syncId: "unrelated-reference",
            title: "Unrelated local parent"
        )
        var unrelatedTag = Tag(
            syncId: "unrelated-tag",
            name: "Unrelated local tag"
        )
        try database.saveReference(&unrelatedReference)
        try database.saveTag(&unrelatedTag)
        XCTAssertEqual(unrelatedReference.id, legacyReferenceID)
        XCTAssertEqual(unrelatedTag.id, legacyTagID)

        // The durable shadows still name the missing decimal parents rather
        // than these UUID occupants. Local-only rows are physically outside
        // their live tables, so ordinary cache and upload consumers cannot
        // attach them to the UUID Reference that reused the old positive ID.
        try await database.dbWriter.read { db in
            let tablePairs = [
                ("pdfCache", "syncLegacyPDFCacheOrphan"),
                ("pdfUploadQueue", "syncLegacyPDFUploadQueueOrphan"),
                ("webContentMarkdownCache", "syncLegacyWebContentCacheOrphan"),
            ]
            for (liveTable, orphanTable) in tablePairs {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(liveTable)"),
                    0
                )
                XCTAssertEqual(
                    try String.fetchOne(
                        db,
                        sql: "SELECT legacyReferenceSyncId FROM \(orphanTable)"
                    ),
                    String(legacyReferenceID)
                )
            }
        }

        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).engine-state")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let library = SyncedLibrary(
            appDatabase: database,
            stateFileURL: stateURL,
            pdfAssetSyncEnabledProvider: { true }
        )
        await library.performInitialBaselineIfNeeded()
        let prematureDrain = await library.drainPDFUploadQueueIntoSyncState()
        XCTAssertTrue(prematureDrain.isEmpty)
        try await database.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState
                WHERE entityType = 'referencePDF'
                  AND entityId = 'unrelated-reference' AND isDirty = 1
                """), 0)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue"),
                0
            )
            XCTAssertNil(try SyncEntityType.referencePDF.buildPushRecord(
                db: db,
                entityId: "unrelated-reference",
                systemFields: nil
            ))
        }
        let reference = Reference.makeRecord(
            recordName: "reference:\(legacyReferenceID)",
            reference: Reference(
                syncId: String(legacyReferenceID),
                title: "Intended legacy parent"
            )
        )
        let tag = Tag.makeRecord(
            recordName: "tag:\(legacyTagID)",
            tag: Tag(
                syncId: String(legacyTagID),
                name: "Intended legacy tag"
            )
        )
        let applied = await library.applyFetchedRecordsForTest(
            modifications: [tag, reference],
            deletions: []
        )
        XCTAssertTrue(applied)
        let repairedDrain = await library.drainPDFUploadQueueIntoSyncState()
        XCTAssertEqual(repairedDrain, [String(legacyReferenceID)])

        try await database.dbWriter.read { db in
            let intendedReferenceID = try XCTUnwrap(Int64.fetchOne(
                db,
                sql: "SELECT id FROM reference WHERE syncId = ?",
                arguments: [String(legacyReferenceID)]
            ))
            let intendedTagID = try XCTUnwrap(Int64.fetchOne(
                db,
                sql: "SELECT id FROM tag WHERE syncId = ?",
                arguments: [String(legacyTagID)]
            ))
            XCTAssertNotEqual(intendedReferenceID, legacyReferenceID)
            XCTAssertNotEqual(intendedTagID, legacyTagID)
            let pivot = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT referenceId, tagId, referenceSyncId, tagSyncId
                FROM referenceTag
                """))
            XCTAssertEqual(pivot["referenceId"] as Int64?, intendedReferenceID)
            XCTAssertEqual(pivot["tagId"] as Int64?, intendedTagID)
            XCTAssertEqual(
                pivot["referenceSyncId"] as String?,
                String(legacyReferenceID)
            )
            XCTAssertEqual(pivot["tagSyncId"] as String?, String(legacyTagID))
            let tablePairs = [
                ("pdfCache", "syncLegacyPDFCacheOrphan"),
                ("webContentMarkdownCache", "syncLegacyWebContentCacheOrphan"),
            ]
            for (liveTable, orphanTable) in tablePairs {
                XCTAssertEqual(
                    try Int64.fetchOne(
                        db,
                        sql: "SELECT referenceId FROM \(liveTable)"
                    ),
                    intendedReferenceID
                )
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(orphanTable)"),
                    0
                )
            }
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pdfUploadQueue"),
                0
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncLegacyPDFUploadQueueOrphan
                """), 0)
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT title FROM reference WHERE id = ?",
                    arguments: [legacyReferenceID]
                ),
                "Unrelated local parent"
            )
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testLegacyPDFQuarantineHonorsDeleteAndSameBatchServerWinner() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.makeV12DatabaseForTesting(on: queue)
        let firstMissingID = try await queue.read { db in
            (try Int64.fetchOne(db, sql: "SELECT MAX(id) + 1 FROM reference")) ?? 1
        }
        let deletedReferenceID = firstMissingID
        let serverWinnerReferenceID = firstMissingID + 1
        let deletedFilename = "\(UUID().uuidString)-deleted-legacy.pdf"
        let losingFilename = "\(UUID().uuidString)-losing-legacy.pdf"
        let pdfDirectory = AppDatabase.pdfStorageURL
        try FileManager.default.createDirectory(
            at: pdfDirectory,
            withIntermediateDirectories: true
        )
        let deletedURL = pdfDirectory.appendingPathComponent(deletedFilename)
        let losingURL = pdfDirectory.appendingPathComponent(losingFilename)
        try Data("%PDF-deleted-legacy".utf8).write(to: deletedURL)
        try Data("%PDF-losing-legacy".utf8).write(to: losingURL)
        defer {
            try? FileManager.default.removeItem(at: deletedURL)
            try? FileManager.default.removeItem(at: losingURL)
        }

        try await queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            do {
                for (referenceID, filename) in [
                    (deletedReferenceID, deletedFilename),
                    (serverWinnerReferenceID, losingFilename),
                ] {
                    try db.execute(sql: """
                        INSERT INTO pdfCache(
                            referenceId, localFilename, contentHash,
                            assetVersion, materializedAt
                        ) VALUES (?, ?, 'legacy-hash', 1, ?)
                        """, arguments: [referenceID, filename, Date()])
                    try db.execute(sql: """
                        INSERT INTO pdfUploadQueue(
                            referenceId, localFilename, queuedAt
                        ) VALUES (?, ?, ?)
                        """, arguments: [referenceID, filename, Date()])
                }
            } catch {
                try? db.execute(sql: "PRAGMA foreign_keys = ON")
                throw error
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let database = try AppDatabase(queue)
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).engine-state")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let library = SyncedLibrary(appDatabase: database, stateFileURL: stateURL)

        let deleted = SyncedLibrary.FetchedDeletionInput(
            recordID: CKRecord.ID(
                recordName: "referencePDF:\(deletedReferenceID)",
                zoneID: SyncConstants.libraryZoneID
            ),
            recordType: SyncConstants.RecordType.referencePDF
        )
        let deletionApplied = await library.applyFetchedRecordsForTest(
            modifications: [],
            deletions: [deleted]
        )
        XCTAssertTrue(deletionApplied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedURL.path))

        let serverSourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-server.pdf")
        try Data("%PDF-server-winner".utf8).write(to: serverSourceURL)
        defer { try? FileManager.default.removeItem(at: serverSourceURL) }
        let winnerSyncId = String(serverWinnerReferenceID)
        let winnerReference = Reference.makeRecord(
            recordName: "reference:\(winnerSyncId)",
            reference: Reference(
                syncId: winnerSyncId,
                title: "Server winner"
            )
        )
        let winnerPDF = ReferencePDFRecord.makeRecord(
            recordName: "referencePDF:\(winnerSyncId)",
            payload: ReferencePDFRecord(
                referenceId: 0,
                referenceSyncId: winnerSyncId,
                assetURL: serverSourceURL,
                assetVersion: 2,
                contentHash: "server-hash",
                originalFilename: "server.pdf",
                dateModified: Date()
            )
        )
        let winnerApplied = await library.applyFetchedRecordsForTest(
            modifications: [winnerPDF, winnerReference],
            deletions: []
        )
        XCTAssertTrue(winnerApplied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: losingURL.path))

        // A later parent modification must not resurrect the PDF whose
        // authoritative deletion already consumed its quarantine rows.
        let deletedParentSyncId = String(deletedReferenceID)
        let deletedParent = Reference.makeRecord(
            recordName: "reference:\(deletedParentSyncId)",
            reference: Reference(
                syncId: deletedParentSyncId,
                title: "Late deleted-PDF parent"
            )
        )
        let lateParentApplied = await library.applyFetchedRecordsForTest(
            modifications: [deletedParent],
            deletions: []
        )
        XCTAssertTrue(lateParentApplied)

        let serverFilename = try await database.dbWriter.read { db in
            for table in [
                "syncLegacyPDFCacheOrphan",
                "syncLegacyPDFUploadQueueOrphan",
            ] {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"),
                    0
                )
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM pdfCache pc
                JOIN reference r ON r.id = pc.referenceId
                WHERE r.syncId = ?
                """, arguments: [deletedParentSyncId]), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM pdfUploadQueue q
                JOIN reference r ON r.id = q.referenceId
                WHERE r.syncId IN (?, ?)
                """, arguments: [deletedParentSyncId, winnerSyncId]), 0)
            let winner = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT pc.localFilename, pc.contentHash
                FROM pdfCache pc
                JOIN reference r ON r.id = pc.referenceId
                WHERE r.syncId = ?
                """, arguments: [winnerSyncId]))
            XCTAssertEqual(winner["contentHash"] as String?, "server-hash")
            XCTAssertNotEqual(winner["localFilename"] as String?, losingFilename)
            return winner["localFilename"] as String
        }
        let serverURL = pdfDirectory.appendingPathComponent(serverFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: serverURL.path))
        try? FileManager.default.removeItem(at: serverURL)
    }

    func testUUIDForeignKeyWritesOnlyStringAndResolvesLocally() throws {
        let database = try AppDatabase(DatabaseQueue())
        var reference = Reference(syncId: "reference-global", title: "Parent")
        try database.saveReference(&reference)
        let localReferenceID = try XCTUnwrap(reference.id)

        let annotation = PDFAnnotationRecord(
            syncId: "annotation-global",
            referenceId: localReferenceID,
            referenceSyncId: reference.syncId,
            type: .highlight,
            pageIndex: 2,
            rects: []
        )
        let record = PDFAnnotationRecord.makeRecord(
            recordName: "pdfAnnotation:annotation-global",
            annotation: annotation
        )
        XCTAssertNil(record[PDFAnnotationRecord.RecordField.referenceId])
        XCTAssertEqual(
            record[PDFAnnotationRecord.RecordField.referenceSyncId] as? String,
            reference.syncId
        )

        try database.dbWriter.write { db in
            try SyncStateStore().setApplyingRemote(db)
            XCTAssertTrue(
                try SyncEntityType.pdfAnnotation.applyRemoteRecord(
                    record,
                    entityId: annotation.syncId,
                    db: db
                )
            )
            try SyncStateStore().clearApplyingRemote(db)

            let stored = try XCTUnwrap(PDFAnnotationRecord
                .filter(Column("syncId") == annotation.syncId)
                .fetchOne(db))
            XCTAssertEqual(stored.referenceId, localReferenceID)
            XCTAssertEqual(stored.referenceSyncId, reference.syncId)
        }
    }

    func testV12WriterSafetyClassifierMirrorsLegacyGrammar() {
        XCTAssertTrue(SyncEntityType.reference.isUnsafeForV12(entityId: "42"))
        XCTAssertFalse(SyncEntityType.reference.isUnsafeForV12(entityId: "042"))
        XCTAssertFalse(SyncEntityType.reference.isUnsafeForV12(entityId: "reference-global"))

        XCTAssertTrue(SyncEntityType.referenceTag.isUnsafeForV12(entityId: "1/2"))
        XCTAssertFalse(SyncEntityType.referenceTag.isUnsafeForV12(entityId: "ref-global/2"))
        XCTAssertTrue(SyncEntityType.referenceTag.isUnsafeForV12(entityId: "malformed"))

        XCTAssertTrue(
            SyncEntityType.readingActivity.isUnsafeForV12(
                entityId: "generation/install/7/2026-08-14"
            )
        )
        XCTAssertFalse(
            SyncEntityType.readingActivity.isUnsafeForV12(
                entityId: "generation/install/reference-global/2026-08-14"
            )
        )
        XCTAssertTrue(
            SyncEntityType.readingActivity.isUnsafeForV12(entityId: "malformed")
        )

        XCTAssertFalse(
            SyncEntityType.assistantActivity.isUnsafeForV12(entityId: "opaque")
        )
        XCTAssertFalse(
            SyncEntityType.activityEpoch.isUnsafeForV12(entityId: "reading")
        )
    }
}
#endif
