#if os(macOS)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

/// Independent peers can create the same tag name under different global
/// identities. Reconciliation chooses an identity-only winner while preserving
/// this library's local row address and re-keying derived pivots atomically.
final class TagReconcileTests: XCTestCase {
    private var db: AppDatabase!
    private let store = SyncStateStore()
    private var engineStateURLs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() {
        for url in engineStateURLs { try? FileManager.default.removeItem(at: url) }
        engineStateURLs = []
        db = nil
        super.tearDown()
    }

    private func makeLibrary() -> SyncedLibrary {
        let stateFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).engine-state")
        engineStateURLs.append(stateFileURL)
        return SyncedLibrary(
            appDatabase: db,
            stateFileURL: stateFileURL,
            pdfAssetSyncEnabledProvider: { true })
    }

    private func tagRecord(syncId: String, name: String, color: String) -> CKRecord {
        Tag.makeRecord(
            recordName: SyncEntityType.tag.qualifiedRecordName(entityId: syncId),
            tag: Tag(syncId: syncId, name: name, color: color))
    }

    /// Apply a tag record through the production path under `applyingRemote` (so
    /// the dirty-tracking triggers are suppressed), the way the batch loop does
    /// minus its `markPulled`.
    private func applyTagUnderRemote(_ record: CKRecord, entityId: String) throws {
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try SyncEntityType.tag.applyRemoteRecord(record, entityId: entityId, db: db)
            try self.store.clearApplyingRemote(db)
        }
    }

    /// A remote tag whose name already exists locally adopts the incoming global
    /// identity while retaining its local row, rekeys pivots, and cleans the
    /// loser's stale sync bookkeeping.
    func testTagNameCollisionAdoptsIncomingSyncIdAndRekeysPivots() throws {
        var ref = Reference(title: "R1")
        try db.saveReference(&ref)
        let refId = try XCTUnwrap(ref.id)
        var local = Tag(name: "accel", color: "#FF0000")
        try db.saveTag(&local)
        let localTagId = try XCTUnwrap(local.id)
        let localSyncId = local.syncId
        try db.setTags(forReference: refId, tagIds: [localTagId])
        // Give the pivot a distinctive timestamp so we can prove the re-key
        // preserves the PIVOT's own dateModified, not the incoming tag's.
        try db.dbWriter.write { db in
            try db.execute(sql: "UPDATE referenceTag SET dateModified = ? WHERE referenceId=? AND tagId=?",
                           arguments: ["2020-01-01 00:00:00.000", refId, localTagId])
        }

        let remoteId = localTagId + 1000          // legacy peer identity
        let remoteSyncId = String(remoteId)
        let record = tagRecord(syncId: remoteSyncId, name: "accel", color: "#AF52DE")

        try applyTagUnderRemote(record, entityId: remoteSyncId)

        try db.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE name='accel'"), 1)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name='accel'"), localTagId)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT syncId FROM tag WHERE name='accel'"), remoteSyncId)
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE id=?", arguments: [remoteId]))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT color FROM tag WHERE id=?", arguments: [localTagId]), "#AF52DE")
            // The local surrogate remains stable while the pivot adopts the
            // winner's global endpoint identity.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceTag WHERE referenceId=? AND tagId=?", arguments: [refId, localTagId]), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tagSyncId FROM referenceTag WHERE referenceId=? AND tagId=?", arguments: [refId, localTagId]), remoteSyncId)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            // The loser was deleted under applyingRemote (cleanup trigger
            // suppressed) — its stale syncState must be cleaned explicitly.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE entityType='tag' AND entityId=?", arguments: [localSyncId]), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE entityType='referenceTag' AND entityId LIKE ?", arguments: ["%/\(localSyncId)"]), 0)
            // Finding 1: the re-keyed pivot is dirtied by hand (the dirty trigger
            // is suppressed under applyingRemote), so the local association pushes.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT isDirty FROM syncState WHERE entityType='referenceTag' AND entityId=?", arguments: ["\(ref.syncId)/\(remoteSyncId)"]), 1)
            // Finding 3: the re-keyed pivot keeps its OWN dateModified, not the tag's.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT CAST(dateModified AS TEXT) FROM referenceTag WHERE referenceId=? AND tagId=?", arguments: [refId, localTagId]), "2020-01-01 00:00:00.000")
        }
    }

    /// A peer's historical integer row ID is payload history, not a local
    /// address. An unrelated tag at that integer must survive unchanged.
    func testIncomingPeerRowIDCollisionDoesNotOverwriteUnrelatedTag() throws {
        // Loser: local `accel` (the colliding name) carrying its own reference.
        var loserRef = Reference(title: "LoserRef")
        try db.saveReference(&loserRef)
        let loserRefId = try XCTUnwrap(loserRef.id)
        var loser = Tag(name: "accel", color: "#FF0000")
        try db.saveTag(&loser)
        let loserId = try XCTUnwrap(loser.id)
        try db.setTags(forReference: loserRefId, tagIds: [loserId])

        let incomingId = loserId + 1000
        // Bystander: an unrelated tag already sits at the historical integer
        // identity (forced id), carrying its own reference.
        var bystanderRef = Reference(title: "BystanderRef")
        try db.saveReference(&bystanderRef)
        let bystanderRefId = try XCTUnwrap(bystanderRef.id)
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag (id, syncId, name, color, dateModified) VALUES (?,?,?,?,?)",
                           arguments: [incomingId, "bystander-sync", "unrelated", "#00FF00", Date()])
        }
        try db.setTags(forReference: bystanderRefId, tagIds: [incomingId])

        let remoteSyncId = String(incomingId)
        let record = tagRecord(syncId: remoteSyncId, name: "accel", color: "#AF52DE")
        try applyTagUnderRemote(record, entityId: remoteSyncId)

        try db.dbWriter.read { db in
            // The incoming peer's integer happens to equal a bystander's local
            // row ID, but lookup is global-identity-only, so neither row is lost.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE name='accel'"), 1)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name='accel'"), loserId)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT syncId FROM tag WHERE name='accel'"), remoteSyncId)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE name='unrelated'"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT color FROM tag WHERE id=?", arguments: [loserId]), "#AF52DE")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceTag WHERE referenceId=? AND tagId=?", arguments: [loserRefId, loserId]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceTag WHERE referenceId=? AND tagId=?", arguments: [bystanderRefId, incomingId]), 1)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testKnownTagRenameCollisionMergesRowsAndAliasesLaterChildren() throws {
        var firstReference = Reference(syncId: "ref-one", title: "One")
        var secondReference = Reference(syncId: "ref-two", title: "Two")
        var laterReference = Reference(syncId: "ref-later", title: "Later")
        try db.saveReference(&firstReference)
        try db.saveReference(&secondReference)
        try db.saveReference(&laterReference)
        var winner = Tag(syncId: "a-winner", name: "Shared", color: "#111111")
        var loser = Tag(syncId: "z-loser", name: "Before rename", color: "#222222")
        try db.saveTag(&winner)
        try db.saveTag(&loser)
        let winnerId = try XCTUnwrap(winner.id)
        let loserId = try XCTUnwrap(loser.id)
        try db.setTags(
            forReference: try XCTUnwrap(firstReference.id),
            tagIds: [winnerId]
        )
        try db.setTags(
            forReference: try XCTUnwrap(secondReference.id),
            tagIds: [loserId]
        )
        try db.dbWriter.write { db in
            try db.execute(sql: """
                UPDATE syncState SET isDirty = 0
                WHERE entityType = 'databaseView'
                """)
        }

        try applyTagUnderRemote(
            tagRecord(syncId: loser.syncId, name: winner.name, color: "#ABCDEF"),
            entityId: loser.syncId
        )

        let laterPivot = ReferenceTag(
            syncId: "\(laterReference.syncId)/\(loser.syncId)",
            referenceId: 0,
            tagId: 0,
            referenceSyncId: laterReference.syncId,
            tagSyncId: loser.syncId
        )
        let laterRecord = makeTestRecord(
            recordType: SyncConstants.RecordType.referenceTag,
            recordName: SyncEntityType.referenceTag.qualifiedRecordName(
                entityId: laterPivot.syncId
            )
        )
        laterPivot.populate(record: laterRecord)
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            XCTAssertTrue(try SyncEntityType.referenceTag.applyRemoteRecord(
                laterRecord,
                entityId: laterPivot.syncId,
                db: db,
                stateStore: self.store
            ))
            try self.store.clearApplyingRemote(db)
        }

        try db.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag"), 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT color FROM tag WHERE syncId = 'a-winner'"),
                "#ABCDEF"
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM referenceTag WHERE tagId = ?
                """, arguments: [winnerId]), 3)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncIdentityAlias
                WHERE entityType = 'tag'
                  AND losingId = 'z-loser' AND winningId = 'a-winner'
                """), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT syncId FROM referenceTag
                WHERE referenceId = ? AND tagId = ?
                """, arguments: [try XCTUnwrap(laterReference.id), winnerId]),
                "ref-later/a-winner")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE entityType = 'referenceTag'
                  AND entityId = 'ref-later/z-loser'
                  AND isPushEligible = 1
                """), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState
                WHERE entityType = 'databaseView' AND isDirty = 1
                """), try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM databaseView"))
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    /// End-to-end, mirroring the wedged mini: a fetched batch carrying the
    /// colliding tag insert AND an unrelated reference deletion must commit as a
    /// whole. Pre-fix the tag UNIQUE collision rolled the batch back, so the
    /// deletion never applied.
    func testMixedBatchNoLongerRollsBackOnTagCollision() async throws {
        let library = makeLibrary()

        var local = Tag(name: "accel", color: "#FF0000")
        try db.saveTag(&local)
        let localTagId = try XCTUnwrap(local.id)
        var doomed = Reference(title: "Doomed")
        try db.saveReference(&doomed)
        let doomedId = try XCTUnwrap(doomed.id)

        let remoteTagId = localTagId + 1000
        let remoteSyncId = String(remoteTagId)
        let tagRec = tagRecord(syncId: remoteSyncId, name: "accel", color: "#AF52DE")
        let deletion = SyncedLibrary.FetchedDeletionInput(
            recordID: CKRecord.ID(
                recordName: SyncEntityType.reference.qualifiedRecordName(entityId: doomed.syncId),
                zoneID: SyncConstants.libraryZoneID),
            recordType: SyncConstants.RecordType.reference)

        await library.applyFetchedRecordsForTest(modifications: [tagRec], deletions: [deletion])

        let (doomedGone, accelId, accelSyncId, fkClean): (Int?, Int64?, String?, Bool) = try await db.dbWriter.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reference WHERE id=?", arguments: [doomedId]),
             try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name='accel'"),
             try String.fetchOne(db, sql: "SELECT syncId FROM tag WHERE name='accel'"),
             try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        XCTAssertEqual(doomedGone, 0, "the reference deletion in the same batch applied (pre-fix: rolled back)")
        XCTAssertEqual(accelId, localTagId, "the local surrogate remains stable")
        XCTAssertEqual(accelSyncId, remoteSyncId)
        XCTAssertTrue(fkClean)
    }

    /// A delete-free reconciliation still has to re-key the losing tag's
    /// derived pivots explicitly while remote-apply triggers are suppressed.
    /// This also pins symmetric cleanup of stale pivot sync state/tombstones.
    func testDeleteFreeBatchCleansLoserPivotsAndTombstones() async throws {
        let library = makeLibrary()

        var ref = Reference(title: "R1")
        try db.saveReference(&ref)
        let refId = try XCTUnwrap(ref.id)
        var local = Tag(name: "accel", color: "#FF0000")
        try db.saveTag(&local)
        let localTagId = try XCTUnwrap(local.id)
        let localSyncId = local.syncId
        try db.setTags(forReference: refId, tagIds: [localTagId])
        let pivotEntityId = "\(ref.syncId)/\(localSyncId)"
        // Seed a stale tombstone for the loser's pivot — the reconcile must clean
        // it symmetrically with the loser tag's tombstone (triggers are suppressed
        // under applyingRemote, so it won't self-clean). Raw insert (not
        // store.upsertTombstone) so the @Sendable async-write closure captures no
        // `self`.
        try await db.dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO tombstone (entityType, entityId, deletedAt, confirmedByServer) VALUES ('referenceTag', ?, ?, 0)",
                arguments: [pivotEntityId, Date()])
        }

        let remoteId = localTagId + 1000
        let remoteSyncId = String(remoteId)
        let record = tagRecord(syncId: remoteSyncId, name: "accel", color: "#AF52DE")
        await library.applyFetchedRecordsForTest(modifications: [record], deletions: [])

        let r: (accelId: Int64?, loserPivots: Int?, newPivots: Int?, fkClean: Bool,
                loserTagState: Int?, loserPivotState: Int?, loserPivotTomb: Int?)
            = try await db.dbWriter.read { db in
            (try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name='accel'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceTag WHERE tagId=?", arguments: [localTagId]),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceTag WHERE referenceId=? AND tagSyncId=?", arguments: [refId, remoteSyncId]),
             try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE entityType='tag' AND entityId=?", arguments: [localSyncId]),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE entityType='referenceTag' AND entityId LIKE ?", arguments: ["%/\(localSyncId)"]),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone WHERE entityType='referenceTag' AND entityId=?", arguments: [pivotEntityId]))
        }
        XCTAssertEqual(r.accelId, localTagId, "the local surrogate remains stable")
        XCTAssertEqual(r.loserPivots, 1, "the pivot retains its local tag FK")
        XCTAssertEqual(r.newPivots, 1, "the pivot adopts the incoming global identity")
        XCTAssertTrue(r.fkClean)
        XCTAssertEqual(r.loserTagState, 0, "loser tag syncState cleaned")
        XCTAssertEqual(r.loserPivotState, 0, "loser pivot syncState cleaned")
        XCTAssertEqual(r.loserPivotTomb, 0, "loser pivot tombstone cleaned (symmetric with the tag tombstone)")
    }

    /// The real batch loop records incoming system fields under the winning
    /// global identity, never under an unrelated local row ID.
    func testOccupiedRowIDBatchRecordsIncomingSystemFields() async throws {
        let library = makeLibrary()

        var loser = Tag(name: "accel", color: "#FF0000")
        try db.saveTag(&loser)
        let loserId = try XCTUnwrap(loser.id)
        let loserSyncId = loser.syncId
        let incomingId = loserId + 1000
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag (id, syncId, name, color, dateModified) VALUES (?,?,?,?,?)",
                           arguments: [incomingId, "bystander-sync", "unrelated", "#00FF00", Date()])
        }

        let remoteSyncId = String(incomingId)
        let record = tagRecord(syncId: remoteSyncId, name: "accel", color: "#AF52DE")
        await library.applyFetchedRecordsForTest(modifications: [record], deletions: [])

        let r: (incomingName: String?, loserGone: Bool, hasSystemFields: Bool, fkClean: Bool)
            = try await db.dbWriter.read { db in
            (try String.fetchOne(db, sql: "SELECT name FROM tag WHERE syncId=?", arguments: [remoteSyncId]),
             try String.fetchOne(db, sql: "SELECT syncId FROM tag WHERE syncId=?", arguments: [loserSyncId]) == nil,
             try Data.fetchOne(db, sql: "SELECT systemFields FROM syncState WHERE entityType='tag' AND entityId=?", arguments: [remoteSyncId]) != nil,
             try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        XCTAssertEqual(r.incomingName, "accel")
        XCTAssertTrue(r.loserGone, "the losing global identity was retired")
        XCTAssertTrue(r.hasSystemFields, "markPulled recorded the incoming record's system fields at incomingId")
        XCTAssertTrue(r.fkClean)
    }

    /// Defense-in-depth: a malformed record with an empty name must be SKIPPED,
    /// not persisted as `""` (which would itself trip `UNIQUE(name)` and wedge a
    /// later batch). No tag row is created; the apply does not throw.
    func testEmptyNameRecordIsSkippedNotPersisted() throws {
        let incomingId = "777"
        let record = tagRecord(syncId: incomingId, name: "", color: "#AF52DE")
        try applyTagUnderRemote(record, entityId: incomingId)
        try db.dbWriter.read { db in
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE syncId=?", arguments: [incomingId]))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE name=''"), 0)
        }
    }

    /// Bool-gate (the markPulled fix): a malformed empty-name record routed
    /// through the REAL apply loop must NOT `markPulled` — else it would clear a
    /// pending local edit's `isDirty` and stamp the malformed record's
    /// systemFields onto a row this device never actually synced. `applyRemoteRecord`
    /// returns `false` for the skip, and the loop gates `markPulled` on it, so the
    /// occupied row keeps its name AND its dirty flag.
    func testEmptyNameRecordDoesNotClobberOccupiedDirtyRow() async throws {
        let library = makeLibrary()

        var local = Tag(name: "real", color: "#FF0000")
        try db.saveTag(&local)
        let id = try XCTUnwrap(local.id)
        let localSyncId = local.syncId
        // Precondition: a pending local edit → dirty syncState for this tag.
        try await db.dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO syncState (entityType, entityId, isDirty) VALUES ('tag', ?, 1) ON CONFLICT(entityType, entityId) DO UPDATE SET isDirty = 1",
                arguments: [localSyncId])
        }

        // An empty-name (malformed) record for the SAME id (same CK identity).
        let record = tagRecord(syncId: localSyncId, name: "", color: "#00FF00")
        await library.applyFetchedRecordsForTest(modifications: [record], deletions: [])

        let r: (name: String?, isDirty: Int?) = try await db.dbWriter.read { db in
            (try String.fetchOne(db, sql: "SELECT name FROM tag WHERE id=?", arguments: [id]),
             try Int.fetchOne(db, sql: "SELECT isDirty FROM syncState WHERE entityType='tag' AND entityId=?", arguments: [localSyncId]))
        }
        XCTAssertEqual(r.name, "real", "malformed empty-name record must not overwrite the occupied row")
        XCTAssertEqual(r.isDirty, 1, "skipped record must NOT markPulled (which would clear the pending local edit)")
    }

    func testReferenceTagIdentityCannotBeReusedForDifferentEndpointPair() async throws {
        let library = makeLibrary()
        var firstReference = Reference(syncId: "reference-one", title: "One")
        var secondReference = Reference(syncId: "reference-two", title: "Two")
        var firstTag = Tag(syncId: "tag-one", name: "One")
        var secondTag = Tag(syncId: "tag-two", name: "Two")
        try db.saveReference(&firstReference)
        try db.saveReference(&secondReference)
        try db.saveTag(&firstTag)
        try db.saveTag(&secondTag)
        let firstReferenceId = try XCTUnwrap(firstReference.id)
        let firstTagId = try XCTUnwrap(firstTag.id)
        let firstReferenceSyncId = firstReference.syncId
        let firstTagSyncId = firstTag.syncId
        let secondReferenceSyncId = secondReference.syncId
        let secondTagSyncId = secondTag.syncId
        let reusedIdentity = "shared-pivot-identity"
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO referenceTag(
                    syncId, referenceId, tagId,
                    referenceSyncId, tagSyncId, dateModified
                ) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    reusedIdentity,
                    firstReferenceId,
                    firstTagId,
                    firstReferenceSyncId,
                    firstTagSyncId,
                    Date(),
                ])
        }

        let incoming = ReferenceTag(
            syncId: reusedIdentity,
            referenceId: 0,
            tagId: 0,
            referenceSyncId: secondReferenceSyncId,
            tagSyncId: secondTagSyncId
        )
        let record = makeTestRecord(
            recordType: SyncConstants.RecordType.referenceTag,
            recordName: "referenceTag:\(reusedIdentity)"
        )
        incoming.populate(record: record)

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [record],
            deletions: []
        )
        XCTAssertTrue(applied)

        try await db.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceTag"), 1)
            let owner = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT referenceSyncId, tagSyncId FROM referenceTag
                WHERE syncId = ?
                """, arguments: [reusedIdentity]))
            XCTAssertEqual(owner["referenceSyncId"] as String?, firstReferenceSyncId)
            XCTAssertEqual(owner["tagSyncId"] as String?, firstTagSyncId)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncOrphan
                WHERE recordName = ?
                """, arguments: ["referenceTag:\(reusedIdentity)"]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE entityType = 'referenceTag' AND entityId = ?
                """, arguments: [reusedIdentity]), 0)
        }
    }

    func testLateUpdateForRetiredTagUpdatesWinnerWithoutResurrection() async throws {
        let library = makeLibrary()
        var winner = Tag(syncId: "a-tag", name: "Shared")
        var loser = Tag(syncId: "z-tag", name: "Before collision")
        try db.saveTag(&winner)
        try db.saveTag(&loser)
        let loserSyncId = loser.syncId

        try applyTagUnderRemote(
            tagRecord(syncId: loserSyncId, name: winner.name, color: "#111111"),
            entityId: loserSyncId
        )
        try await db.dbWriter.write { db in
            try self.store.markTombstoneConfirmed(
                db,
                entityType: .tag,
                entityId: loserSyncId
            )
        }
        let lateRecord = tagRecord(
            syncId: loserSyncId,
            name: "Late renamed value",
            color: "#ABCDEF"
        )
        let applied = await library.applyFetchedRecordsForTest(
            modifications: [lateRecord],
            deletions: []
        )
        XCTAssertTrue(applied)

        try await db.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT name FROM tag WHERE syncId = 'a-tag'
                """), "Late renamed value")
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT color FROM tag WHERE syncId = 'a-tag'
                """), "#ABCDEF")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tag WHERE syncId = 'z-tag'
                """), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT winningId FROM syncIdentityAlias
                WHERE entityType = 'tag' AND losingId = 'z-tag'
                """), "a-tag")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT isDirty FROM syncState
                WHERE entityType = 'tag' AND entityId = 'a-tag'
                """), 1)
            let tombstone = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT confirmedByServer, isPushEligible FROM tombstone
                WHERE entityType = 'tag' AND entityId = 'z-tag'
                """))
            XCTAssertEqual(tombstone["confirmedByServer"] as Int?, 0)
            XCTAssertEqual(tombstone["isPushEligible"] as Int?, 1)
        }
    }

    func testLateRetiredTagWithMissingWinnerIsDeletedAgainWithoutResurrection() async throws {
        let library = makeLibrary()
        var winner = Tag(syncId: "a-tag", name: "Shared")
        var loser = Tag(syncId: "z-tag", name: "Before collision")
        try db.saveTag(&winner)
        try db.saveTag(&loser)
        let loserSyncId = loser.syncId
        try applyTagUnderRemote(
            tagRecord(syncId: loserSyncId, name: winner.name, color: "#111111"),
            entityId: loserSyncId
        )
        try await db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try db.execute(sql: "DELETE FROM tag WHERE syncId = 'a-tag'")
            try self.store.clearApplyingRemote(db)
        }

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [tagRecord(
                syncId: loserSyncId,
                name: "Recreated by old peer",
                color: "#ABCDEF"
            )],
            deletions: []
        )
        XCTAssertTrue(applied)

        try await db.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag"), 0)
            let tombstone = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT confirmedByServer, isPushEligible FROM tombstone
                WHERE entityType = 'tag' AND entityId = 'z-tag'
                """))
            XCTAssertEqual(tombstone["confirmedByServer"] as Int?, 0)
            XCTAssertEqual(tombstone["isPushEligible"] as Int?, 1)
        }
    }
}
#endif
