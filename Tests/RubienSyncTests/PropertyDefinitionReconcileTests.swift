#if os(macOS)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

/// Built-in `PropertyDefinition`s are seeded independently on every device, so
/// their rowIDs diverge ("Last Read" is id 29 on a fresh library, 339 on an
/// older one). Syncing them by rowID makes a peer's `INSERT` collide on
/// `UNIQUE(name)`, rolling back the whole fetched batch (dropping custom defs,
/// their property values, and references in that batch). The fix reconciles
/// built-ins by the stable `defaultFieldKey`, updating the local row in place.
final class PropertyDefinitionReconcileTests: XCTestCase {
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

    /// A remote built-in ("Last Read") arrives at a rowID that differs from the
    /// local seed. It must update the local row in place (matched by
    /// defaultFieldKey) rather than INSERT a colliding name.
    func testBuiltinReconcilesByDefaultFieldKeyKeepingLocalRowID() throws {
        let localId = try db.dbWriter.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'")
        }
        let localId2 = try XCTUnwrap(localId)
        let remoteId = localId2 + 1000          // simulate the divergent peer rowID (e.g. 339)

        let def = PropertyDefinition(
            id: remoteId, name: "Last Read", type: .date, options: [],
            sortOrder: 99, isDefault: true, defaultFieldKey: "lastReadAt", isVisible: false
        )
        let record = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: String(remoteId)),
            definition: def
        )

        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try SyncEntityType.propertyDefinition.applyRemoteRecord(record, entityId: String(remoteId), db: db)
            try self.store.clearApplyingRemote(db)
        }

        try db.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM propertyDefinition WHERE name='Last Read'"), 1)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'"), localId2)
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM propertyDefinition WHERE id=?", arguments: [remoteId]))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT sortOrder FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'"), 99)
        }
    }

    /// A peer record carrying a defaultFieldKey but isDefault=0 must still
    /// reconcile by defaultFieldKey (no UNIQUE(name) crash, no rowID insert) and
    /// must NOT poison the local built-in's flag — isDefault stays true.
    func testPeerRecordWithDefaultFieldKeyButIsDefaultFalseStillReconciles() throws {
        let localId = try XCTUnwrap(try db.dbWriter.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'") })
        let remoteId = localId + 1000
        let def = PropertyDefinition(
            id: remoteId, name: "Last Read", type: .date, options: [],
            sortOrder: 7, isDefault: false, defaultFieldKey: "lastReadAt", isVisible: false)  // poisoned flag
        let record = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: String(remoteId)),
            definition: def)
        // Poison the LOCAL flag too — else the test is vacuous against the old
        // `AND isDefault=1` gate, which would still match the seeded isDefault=1
        // row and appear to pass. With both sides isDefault=0, only the gate-less
        // match-by-defaultFieldKey can find the row and restore isDefault=true.
        try db.dbWriter.write { db in
            try db.execute(sql: "UPDATE propertyDefinition SET isDefault = 0 WHERE defaultFieldKey = 'lastReadAt'")
        }
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try SyncEntityType.propertyDefinition.applyRemoteRecord(record, entityId: String(remoteId), db: db)
            try self.store.clearApplyingRemote(db)
        }
        try db.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM propertyDefinition WHERE name='Last Read'"), 1)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'"), localId)
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT isDefault FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'"), true)
        }
    }

    /// A custom def (defaultFieldKey == nil) still inserts at the remote rowID.
    func testCustomDefinitionInsertsByRowID() throws {
        let def = PropertyDefinition(
            id: 237, name: "Method", type: .singleSelect, options: [],
            sortOrder: 50, isDefault: false, defaultFieldKey: nil, isVisible: true
        )
        let record = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: "237"),
            definition: def
        )
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try SyncEntityType.propertyDefinition.applyRemoteRecord(record, entityId: "237", db: db)
            try self.store.clearApplyingRemote(db)
        }
        try db.dbWriter.read { db in
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM propertyDefinition WHERE name='Method'"), 237)
        }
    }

    /// A remote delete must never drop a local built-in (defense-in-depth for the
    /// reconcile's entityId↔localId mismatch). Custom-def deletes still work.
    func testRemoteDeleteNeverDropsLocalBuiltin() throws {
        let builtinId = try XCTUnwrap(try db.dbWriter.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'") })
        // Worst case: the delete keys on the local built-in's own id.
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try SyncEntityType.propertyDefinition.applyRemoteDelete(entityId: String(builtinId), db: db)
            try self.store.clearApplyingRemote(db)
        }
        XCTAssertEqual(try db.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'") }, 1,
            "remote delete must not drop a local built-in")

        // A custom def still deletes normally.
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO propertyDefinition (id, name, type, optionsJSON, sortOrder, isDefault, isVisible) VALUES (500, 'Custom', 'singleSelect', '[]', 99, 0, 1)")
            try self.store.setApplyingRemote(db)
            try SyncEntityType.propertyDefinition.applyRemoteDelete(entityId: "500", db: db)
            try self.store.clearApplyingRemote(db)
        }
        XCTAssertEqual(try db.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM propertyDefinition WHERE id=500") }, 0,
            "custom-def remote delete still works")
    }

    /// End-to-end: a fetched batch mixing the divergent built-in + a custom def +
    /// a reference must commit as a whole (pre-fix it rolled back on the built-in
    /// UNIQUE collision, dropping the custom def and the reference with it).
    func testMixedBatchNoLongerRollsBackOnBuiltinCollision() async throws {
        let library = makeLibrary()

        let localLastReadOpt = try await db.dbWriter.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'") }
        let localLastRead = try XCTUnwrap(localLastReadOpt)

        let builtin = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: String(localLastRead + 1000)),
            definition: PropertyDefinition(id: localLastRead + 1000, name: "Last Read", type: .date, options: [],
                sortOrder: 99, isDefault: true, defaultFieldKey: "lastReadAt", isVisible: false))
        let custom = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: "237"),
            definition: PropertyDefinition(id: 237, name: "Method", type: .singleSelect, options: [],
                sortOrder: 50, isDefault: false, defaultFieldKey: nil, isVisible: true))
        let ref = Reference.makeRecord(
            recordName: SyncEntityType.reference.qualifiedRecordName(entityId: "5"),
            reference: Reference(title: "R5"))

        await library.applyFetchedRecordsForTest(modifications: [builtin, custom, ref], deletions: [])

        let (methodId, refCount, fkClean): (Int64?, Int?, Bool) = try await db.dbWriter.read { db in
            (try Int64.fetchOne(db, sql: "SELECT id FROM propertyDefinition WHERE name='Method'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reference WHERE id=5"),
             try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        XCTAssertEqual(methodId, 237)
        XCTAssertEqual(refCount, 1)            // ref survived the batch
        XCTAssertTrue(fkClean)
    }
}
#endif
