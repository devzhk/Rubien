#if os(macOS)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

/// Tags sync by rowID, but a tag *name* can already exist locally at a DIFFERENT
/// rowID — a peer's delete+recreate this device hasn't applied yet, or
/// independent offline creation. Pre-fix, applying the incoming tag did a plain
/// rowID INSERT that collided on `UNIQUE(name)` and rolled back the WHOLE fetched
/// batch, silently wedging all sync for the device (it applied nothing — not the
/// tag, not unrelated deletions). The fix reconciles by name: adopt the incoming
/// rowID, carry the local tag's pivots across, drop the local row. Sibling of
/// `PropertyDefinitionReconcileTests` (built-ins reconcile by `defaultFieldKey`;
/// tags have no stable secondary key, so they converge on the incoming rowID).
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

    private func tagRecord(id: Int64, name: String, color: String) -> CKRecord {
        Tag.makeRecord(
            recordName: SyncEntityType.tag.qualifiedRecordName(entityId: String(id)),
            tag: Tag(name: name, color: color))
    }

    /// Apply a tag record through the production path under `applyingRemote` (so
    /// the dirty-tracking triggers are suppressed), the way the batch loop does
    /// minus its `markPulled`.
    private func applyTagUnderRemote(_ record: CKRecord, entityId: Int64) throws {
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try SyncEntityType.tag.applyRemoteRecord(record, entityId: String(entityId), db: db)
            try self.store.clearApplyingRemote(db)
        }
    }

    /// A remote tag whose name already exists locally at a different rowID adopts
    /// the incoming rowID, carries the local pivots across, drops the local row,
    /// and cleans the loser's stale sync bookkeeping.
    func testTagNameCollisionAdoptsIncomingRowIDAndRekeysPivots() throws {
        var ref = Reference(title: "R1")
        try db.saveReference(&ref)
        let refId = try XCTUnwrap(ref.id)
        var local = Tag(name: "accel", color: "#FF0000")
        try db.saveTag(&local)
        let localTagId = try XCTUnwrap(local.id)
        try db.setTags(forReference: refId, tagIds: [localTagId])
        // Give the pivot a distinctive timestamp so we can prove the re-key
        // preserves the PIVOT's own dateModified, not the incoming tag's.
        try db.dbWriter.write { db in
            try db.execute(sql: "UPDATE referenceTag SET dateModified = ? WHERE referenceId=? AND tagId=?",
                           arguments: ["2020-01-01 00:00:00.000", refId, localTagId])
        }

        let remoteId = localTagId + 1000          // divergent peer rowID
        let record = tagRecord(id: remoteId, name: "accel", color: "#AF52DE")

        try applyTagUnderRemote(record, entityId: remoteId)

        try db.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE name='accel'"), 1)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name='accel'"), remoteId)
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE id=?", arguments: [localTagId]))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT color FROM tag WHERE id=?", arguments: [remoteId]), "#AF52DE")
            // pivot followed the tag onto the incoming rowID; none left behind; FK clean.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceTag WHERE referenceId=? AND tagId=?", arguments: [refId, remoteId]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceTag WHERE tagId=?", arguments: [localTagId]), 0)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            // The loser was deleted under applyingRemote (cleanup trigger
            // suppressed) — its stale syncState must be cleaned explicitly.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE entityType='tag' AND entityId=?", arguments: [String(localTagId)]), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE entityType='referenceTag' AND entityId LIKE ?", arguments: ["%/\(localTagId)"]), 0)
            // Finding 1: the re-keyed pivot is dirtied by hand (the dirty trigger
            // is suppressed under applyingRemote), so the local association pushes.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT isDirty FROM syncState WHERE entityType='referenceTag' AND entityId=?", arguments: ["\(refId)/\(remoteId)"]), 1)
            // Finding 3: the re-keyed pivot keeps its OWN dateModified, not the tag's.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT CAST(dateModified AS TEXT) FROM referenceTag WHERE referenceId=? AND tagId=?", arguments: [refId, remoteId]), "2020-01-01 00:00:00.000")
        }
    }

    /// Double divergence (the deferred A-pks corner): the incoming rowID is ALSO
    /// already occupied locally by an unrelated tag. Per the chosen design
    /// (Option A), the reconcile does NOT guard this — it OVERWRITES the occupant,
    /// exactly as the existing plain-rowID upsert already does on any rowID
    /// collision today (no new data-loss class). The bystander tag is lost and its
    /// references silently re-label (no *reference* is ever deleted); crucially the
    /// apply must NOT throw/wedge, and `markPulled(incomingId)` stays correct
    /// because the incoming record really is applied at incomingId. Pins that
    /// behavior against a future regression that re-adds a guard or reintroduces a
    /// wedge.
    func testIncomingRowIDOccupiedOverwritesOccupant() throws {
        // Loser: local `accel` (the colliding name) carrying its own reference.
        var loserRef = Reference(title: "LoserRef")
        try db.saveReference(&loserRef)
        let loserRefId = try XCTUnwrap(loserRef.id)
        var loser = Tag(name: "accel", color: "#FF0000")
        try db.saveTag(&loser)
        let loserId = try XCTUnwrap(loser.id)
        try db.setTags(forReference: loserRefId, tagIds: [loserId])

        let incomingId = loserId + 1000
        // Bystander: an unrelated tag already sits at the incoming rowID (forced
        // id), carrying its own reference — the overwrite silently re-labels it.
        var bystanderRef = Reference(title: "BystanderRef")
        try db.saveReference(&bystanderRef)
        let bystanderRefId = try XCTUnwrap(bystanderRef.id)
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag (id, name, color, dateModified) VALUES (?,?,?,?)",
                           arguments: [incomingId, "unrelated", "#00FF00", Date()])
        }
        try db.setTags(forReference: bystanderRefId, tagIds: [incomingId])

        let record = tagRecord(id: incomingId, name: "accel", color: "#AF52DE")
        // Must NOT throw — overwriting the occupant is the accepted A-pks behavior
        // (same as today's plain-rowID upsert), not a wedge.
        try applyTagUnderRemote(record, entityId: incomingId)

        try db.dbWriter.read { db in
            // Exactly one `accel`, at the incoming rowID, with the incoming color;
            // the occupant `unrelated` is overwritten (gone); the loser row is gone.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE name='accel'"), 1)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name='accel'"), incomingId)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE name='unrelated'"), 0)
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE id=?", arguments: [loserId]))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT color FROM tag WHERE id=?", arguments: [incomingId]), "#AF52DE")
            // Both references now resolve to the incoming tag: the loser's ref was
            // re-keyed across, the bystander's ref was silently re-labeled (the
            // documented A-pks cost). No pivots left on the loser; FK clean.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceTag WHERE referenceId=? AND tagId=?", arguments: [loserRefId, incomingId]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceTag WHERE referenceId=? AND tagId=?", arguments: [bystanderRefId, incomingId]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceTag WHERE tagId=?", arguments: [loserId]), 0)
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
        let tagRec = tagRecord(id: remoteTagId, name: "accel", color: "#AF52DE")
        let deletion = SyncedLibrary.FetchedDeletionInput(
            recordID: CKRecord.ID(
                recordName: SyncEntityType.reference.qualifiedRecordName(entityId: String(doomedId)),
                zoneID: SyncConstants.libraryZoneID),
            recordType: SyncConstants.RecordType.reference)

        await library.applyFetchedRecordsForTest(modifications: [tagRec], deletions: [deletion])

        let (doomedGone, accelId, fkClean): (Int?, Int64?, Bool) = try await db.dbWriter.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reference WHERE id=?", arguments: [doomedId]),
             try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name='accel'"),
             try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        XCTAssertEqual(doomedGone, 0, "the reference deletion in the same batch applied (pre-fix: rolled back)")
        XCTAssertEqual(accelId, remoteTagId, "tag reconciled to the incoming rowID")
        XCTAssertTrue(fkClean)
    }

    /// Delete-free batch → the FK-OFF orphan-tolerance branch
    /// (`SyncedLibrary` splits on `deletions.isEmpty`), where `ON DELETE CASCADE`
    /// does NOT fire, so the reconcile's explicit pivot `DELETE` is the only thing
    /// cleaning the loser's children. Test #3 carries a deletion and only exercises
    /// the FK-ON branch, so this path was otherwise untested. Also pins the
    /// symmetric `referenceTag` *tombstone* cleanup (pre-seeded stale tombstone).
    func testDeleteFreeBatchCleansLoserPivotsAndTombstones() async throws {
        let library = makeLibrary()

        var ref = Reference(title: "R1")
        try db.saveReference(&ref)
        let refId = try XCTUnwrap(ref.id)
        var local = Tag(name: "accel", color: "#FF0000")
        try db.saveTag(&local)
        let localTagId = try XCTUnwrap(local.id)
        try db.setTags(forReference: refId, tagIds: [localTagId])
        let pivotEntityId = "\(refId)/\(localTagId)"
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
        let record = tagRecord(id: remoteId, name: "accel", color: "#AF52DE")
        await library.applyFetchedRecordsForTest(modifications: [record], deletions: [])

        let r: (accelId: Int64?, loserPivots: Int?, newPivots: Int?, fkClean: Bool,
                loserTagState: Int?, loserPivotState: Int?, loserPivotTomb: Int?)
            = try await db.dbWriter.read { db in
            (try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name='accel'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceTag WHERE tagId=?", arguments: [localTagId]),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM referenceTag WHERE referenceId=? AND tagId=?", arguments: [refId, remoteId]),
             try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE entityType='tag' AND entityId=?", arguments: [String(localTagId)]),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncState WHERE entityType='referenceTag' AND entityId LIKE ?", arguments: ["%/\(localTagId)"]),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone WHERE entityType='referenceTag' AND entityId=?", arguments: [pivotEntityId]))
        }
        XCTAssertEqual(r.accelId, remoteId, "reconciled onto the incoming rowID")
        XCTAssertEqual(r.loserPivots, 0, "loser pivots cleaned in the FK-OFF window (no cascade fires there)")
        XCTAssertEqual(r.newPivots, 1, "pivot re-keyed to the incoming rowID")
        XCTAssertTrue(r.fkClean)
        XCTAssertEqual(r.loserTagState, 0, "loser tag syncState cleaned")
        XCTAssertEqual(r.loserPivotState, 0, "loser pivot syncState cleaned")
        XCTAssertEqual(r.loserPivotTomb, 0, "loser pivot tombstone cleaned (symmetric with the tag tombstone)")
    }

    /// Occupied incoming rowID driven through the REAL apply loop, so the
    /// unconditional `markPulled` (`SyncedLibrary.swift:909`) runs. Under Option A
    /// the incoming record genuinely lands at `incomingId` (overwriting the
    /// occupant), so `markPulled` records the incoming system fields against the
    /// row that truly holds them — the exact property the rejected guard-skip
    /// would have violated (it would have left the occupant resident while
    /// markPulled stamped the incoming tag's change-tag onto it).
    func testOccupiedRowIDBatchRecordsIncomingSystemFields() async throws {
        let library = makeLibrary()

        var loser = Tag(name: "accel", color: "#FF0000")
        try db.saveTag(&loser)
        let loserId = try XCTUnwrap(loser.id)
        let incomingId = loserId + 1000
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO tag (id, name, color, dateModified) VALUES (?,?,?,?)",
                           arguments: [incomingId, "unrelated", "#00FF00", Date()])
        }

        let record = tagRecord(id: incomingId, name: "accel", color: "#AF52DE")
        await library.applyFetchedRecordsForTest(modifications: [record], deletions: [])

        let r: (incomingName: String?, loserGone: Bool, hasSystemFields: Bool, fkClean: Bool)
            = try await db.dbWriter.read { db in
            (try String.fetchOne(db, sql: "SELECT name FROM tag WHERE id=?", arguments: [incomingId]),
             try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE id=?", arguments: [loserId]) == nil,
             try Data.fetchOne(db, sql: "SELECT systemFields FROM syncState WHERE entityType='tag' AND entityId=?", arguments: [String(incomingId)]) != nil,
             try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        XCTAssertEqual(r.incomingName, "accel", "Option A: incoming overwrote the occupant at incomingId")
        XCTAssertTrue(r.loserGone, "loser row removed (name freed)")
        XCTAssertTrue(r.hasSystemFields, "markPulled recorded the incoming record's system fields at incomingId")
        XCTAssertTrue(r.fkClean)
    }

    /// Defense-in-depth: a malformed record with an empty name must be SKIPPED,
    /// not persisted as `""` (which would itself trip `UNIQUE(name)` and wedge a
    /// later batch). No tag row is created; the apply does not throw.
    func testEmptyNameRecordIsSkippedNotPersisted() throws {
        let incomingId: Int64 = 777
        let record = tagRecord(id: incomingId, name: "", color: "#AF52DE")
        try applyTagUnderRemote(record, entityId: incomingId)
        try db.dbWriter.read { db in
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE id=?", arguments: [incomingId]))
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
        // Precondition: a pending local edit → dirty syncState for this tag.
        try await db.dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO syncState (entityType, entityId, isDirty) VALUES ('tag', ?, 1) ON CONFLICT(entityType, entityId) DO UPDATE SET isDirty = 1",
                arguments: [String(id)])
        }

        // An empty-name (malformed) record for the SAME id (same CK identity).
        let record = tagRecord(id: id, name: "", color: "#00FF00")
        await library.applyFetchedRecordsForTest(modifications: [record], deletions: [])

        let r: (name: String?, isDirty: Int?) = try await db.dbWriter.read { db in
            (try String.fetchOne(db, sql: "SELECT name FROM tag WHERE id=?", arguments: [id]),
             try Int.fetchOne(db, sql: "SELECT isDirty FROM syncState WHERE entityType='tag' AND entityId=?", arguments: [String(id)]))
        }
        XCTAssertEqual(r.name, "real", "malformed empty-name record must not overwrite the occupied row")
        XCTAssertEqual(r.isDirty, 1, "skipped record must NOT markPulled (which would clear the pending local edit)")
    }
}
#endif
