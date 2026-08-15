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
        let remoteId = localId2 + 1000          // simulate a legacy peer identity (e.g. 339)

        let def = PropertyDefinition(
            id: remoteId, syncId: String(remoteId), name: "Last Read", type: .date, options: [],
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
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT syncId FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'"), String(remoteId))
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
            id: remoteId, syncId: String(remoteId), name: "Last Read", type: .date, options: [],
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
            id: 237, syncId: "237", name: "Method", type: .singleSelect, options: [],
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
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT syncId FROM propertyDefinition WHERE name='Method'"), "237")
        }
    }

    func testKnownCustomDefinitionRenameCollisionMergesExistingRows() throws {
        var winner = PropertyDefinition(
            syncId: "a-property",
            name: "Shared custom field",
            type: .string
        )
        var loser = PropertyDefinition(
            syncId: "z-property",
            name: "Before rename",
            type: .string
        )
        try db.savePropertyDefinition(&winner)
        try db.savePropertyDefinition(&loser)
        try db.dbWriter.write { db in
            try db.execute(sql: """
                UPDATE syncState SET isDirty = 0
                WHERE entityType = 'databaseView'
                """)
        }
        let incoming = PropertyDefinition(
            syncId: loser.syncId,
            name: winner.name,
            type: .url,
            sortOrder: 77
        )
        let record = PropertyDefinition.makeRecord(
            recordName: "propertyDefinition:\(loser.syncId)",
            definition: incoming
        )

        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            XCTAssertTrue(try SyncEntityType.propertyDefinition.applyRemoteRecord(
                record,
                entityId: loser.syncId,
                db: db,
                stateStore: self.store
            ))
            try self.store.clearApplyingRemote(db)
        }

        try db.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM propertyDefinition
                WHERE syncId IN ('a-property', 'z-property')
                """), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT syncId FROM propertyDefinition
                WHERE name = 'Shared custom field'
                """), "a-property")
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT type FROM propertyDefinition WHERE syncId = 'a-property'
                """), PropertyType.url.rawValue)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncIdentityAlias
                WHERE entityType = 'propertyDefinition'
                  AND losingId = 'z-property' AND winningId = 'a-property'
                """), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncState
                WHERE entityType = 'databaseView' AND isDirty = 1
                """), try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM databaseView"))
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    /// A remote delete must never drop a local built-in (defense-in-depth for the
    /// reconcile's entityId↔localId mismatch). Custom-def deletes still work.
    func testRemoteDeleteNeverDropsLocalBuiltin() throws {
        let builtinSyncId = try XCTUnwrap(try db.dbWriter.read {
            try String.fetchOne($0, sql: "SELECT syncId FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'") })
        // Worst case: the delete keys on the local built-in's own identity.
        try db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            try SyncEntityType.propertyDefinition.applyRemoteDelete(entityId: builtinSyncId, db: db)
            try self.store.clearApplyingRemote(db)
        }
        XCTAssertEqual(try db.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'") }, 1,
            "remote delete must not drop a local built-in")

        // A custom def still deletes normally.
        try db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO propertyDefinition (id, syncId, name, type, optionsJSON, sortOrder, isDefault, isVisible) VALUES (500, '500', 'Custom', 'singleSelect', '[]', 99, 0, 1)")
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
            definition: PropertyDefinition(id: localLastRead + 1000, syncId: String(localLastRead + 1000), name: "Last Read", type: .date, options: [],
                sortOrder: 99, isDefault: true, defaultFieldKey: "lastReadAt", isVisible: false))
        let custom = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: "237"),
            definition: PropertyDefinition(id: 237, syncId: "237", name: "Method", type: .singleSelect, options: [],
                sortOrder: 50, isDefault: false, defaultFieldKey: nil, isVisible: true))
        let ref = Reference.makeRecord(
            recordName: SyncEntityType.reference.qualifiedRecordName(entityId: "5"),
            reference: Reference(syncId: "5", title: "R5"))

        await library.applyFetchedRecordsForTest(modifications: [builtin, custom, ref], deletions: [])

        let (methodSyncId, refCount, fkClean): (String?, Int?, Bool) = try await db.dbWriter.read { db in
            (try String.fetchOne(db, sql: "SELECT syncId FROM propertyDefinition WHERE name='Method'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reference WHERE syncId='5'"),
             try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        XCTAssertEqual(methodSyncId, "237")
        XCTAssertEqual(refCount, 1)            // ref survived the batch
        XCTAssertTrue(fkClean)
    }

    func testLatePropertyValueCanonicalizesAliasedParentIdentities() async throws {
        let library = makeLibrary()
        var reference = Reference(syncId: "reference-winner", title: "Paper")
        var property = PropertyDefinition(
            syncId: "property-winner",
            name: "Late value",
            type: .string
        )
        try db.saveReference(&reference)
        try db.savePropertyDefinition(&property)
        let referenceId = try XCTUnwrap(reference.id)
        let propertyId = try XCTUnwrap(property.id)
        let referenceSyncId = reference.syncId
        let propertySyncId = property.syncId
        let losingReference = "reference-loser"
        let losingProperty = "property-loser"
        let observedIdentity = "\(losingReference)/\(losingProperty)"
        let canonicalIdentity = "\(referenceSyncId)/\(propertySyncId)"
        try await db.dbWriter.write { db in
            try SyncIdentityAliasStore.record(
                entityType: .reference,
                losingId: losingReference,
                winningId: referenceSyncId,
                db: db
            )
            try SyncIdentityAliasStore.record(
                entityType: .propertyDefinition,
                losingId: losingProperty,
                winningId: propertySyncId,
                db: db
            )
        }
        let incoming = PropertyValue(
            syncId: observedIdentity,
            referenceId: 0,
            referenceSyncId: losingReference,
            propertyId: 0,
            propertySyncId: losingProperty,
            value: "arrived late"
        )
        let record = PropertyValue.makeRecord(
            recordName: "propertyValue:\(observedIdentity)",
            propertyValue: incoming
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [record],
            deletions: []
        )
        XCTAssertTrue(applied)

        try await db.dbWriter.read { db in
            let stored = try XCTUnwrap(PropertyValue.fetchOne(
                db,
                sql: "SELECT * FROM propertyValue WHERE syncId = ?",
                arguments: [canonicalIdentity]
            ))
            XCTAssertEqual(stored.referenceId, referenceId)
            XCTAssertEqual(stored.propertyId, propertyId)
            XCTAssertEqual(stored.referenceSyncId, referenceSyncId)
            XCTAssertEqual(stored.propertySyncId, propertySyncId)
            XCTAssertEqual(stored.value, "arrived late")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT isDirty FROM syncState
                WHERE entityType = 'propertyValue' AND entityId = ?
                """, arguments: [canonicalIdentity]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT isPushEligible FROM tombstone
                WHERE entityType = 'propertyValue' AND entityId = ?
                """, arguments: [observedIdentity]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM propertyValue WHERE syncId = ?
                """, arguments: [observedIdentity]), 0)
        }
    }

    func testPropertyValueIdentityCannotBeReusedForDifferentEndpointPair() async throws {
        let library = makeLibrary()
        var firstReference = Reference(syncId: "reference-one", title: "One")
        var secondReference = Reference(syncId: "reference-two", title: "Two")
        var firstProperty = PropertyDefinition(
            syncId: "property-one",
            name: "First property",
            type: .string
        )
        var secondProperty = PropertyDefinition(
            syncId: "property-two",
            name: "Second property",
            type: .string
        )
        try db.saveReference(&firstReference)
        try db.saveReference(&secondReference)
        try db.savePropertyDefinition(&firstProperty)
        try db.savePropertyDefinition(&secondProperty)
        let firstReferenceId = try XCTUnwrap(firstReference.id)
        let secondReferenceId = try XCTUnwrap(secondReference.id)
        let firstPropertyId = try XCTUnwrap(firstProperty.id)
        let secondPropertyId = try XCTUnwrap(secondProperty.id)
        let firstReferenceSyncId = firstReference.syncId
        let secondReferenceSyncId = secondReference.syncId
        let firstPropertySyncId = firstProperty.syncId
        let secondPropertySyncId = secondProperty.syncId
        let reusedIdentity = "shared-property-value"
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO propertyValue(
                    syncId, referenceId, referenceSyncId,
                    propertyId, propertySyncId, value, dateModified
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    reusedIdentity,
                    firstReferenceId, firstReferenceSyncId,
                    firstPropertyId, firstPropertySyncId,
                    "keep me", Date(),
                ])
        }
        let incoming = PropertyValue(
            syncId: reusedIdentity,
            referenceId: 0,
            referenceSyncId: secondReferenceSyncId,
            propertyId: 0,
            propertySyncId: secondPropertySyncId,
            value: "must quarantine"
        )
        let record = PropertyValue.makeRecord(
            recordName: "propertyValue:\(reusedIdentity)",
            propertyValue: incoming
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [record],
            deletions: []
        )
        XCTAssertTrue(applied)

        try await db.dbWriter.read { db in
            let owner = try XCTUnwrap(PropertyValue.fetchOne(
                db,
                sql: "SELECT * FROM propertyValue WHERE syncId = ?",
                arguments: [reusedIdentity]
            ))
            XCTAssertEqual(owner.referenceId, firstReferenceId)
            XCTAssertEqual(owner.propertyId, firstPropertyId)
            XCTAssertEqual(owner.value, "keep me")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM propertyValue
                WHERE referenceId = ? AND propertyId = ?
                """, arguments: [secondReferenceId, secondPropertyId]), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncOrphan WHERE recordName = ?
                """, arguments: ["propertyValue:\(reusedIdentity)"]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tombstone
                WHERE entityType = 'propertyValue' AND entityId = ?
                """, arguments: [reusedIdentity]), 0)
        }
    }

    func testLateUpdateForRetiredDefinitionUpdatesWinnerWithoutResurrection() async throws {
        let library = makeLibrary()
        var winner = PropertyDefinition(
            syncId: "a-property",
            name: "Shared definition",
            type: .string
        )
        var loser = PropertyDefinition(
            syncId: "z-property",
            name: "Before collision",
            type: .string
        )
        try db.savePropertyDefinition(&winner)
        try db.savePropertyDefinition(&loser)
        let collision = PropertyDefinition.makeRecord(
            recordName: "propertyDefinition:\(loser.syncId)",
            definition: PropertyDefinition(
                syncId: loser.syncId,
                name: winner.name,
                type: .string
            )
        )
        let loserSyncId = loser.syncId
        try await db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            XCTAssertTrue(try SyncEntityType.propertyDefinition.applyRemoteRecord(
                collision,
                entityId: loserSyncId,
                db: db,
                stateStore: self.store
            ))
            try self.store.clearApplyingRemote(db)
        }

        let late = PropertyDefinition.makeRecord(
            recordName: "propertyDefinition:\(loser.syncId)",
            definition: PropertyDefinition(
                syncId: loser.syncId,
                name: "Late renamed definition",
                type: .url,
                sortOrder: 88
            )
        )
        let applied = await library.applyFetchedRecordsForTest(
            modifications: [late],
            deletions: []
        )
        XCTAssertTrue(applied)

        try await db.dbWriter.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM propertyDefinition WHERE syncId IN ('a-property', 'z-property')"),
                1
            )
            let stored = try XCTUnwrap(PropertyDefinition.fetchOne(
                db,
                sql: "SELECT * FROM propertyDefinition WHERE syncId = 'a-property'"
            ))
            XCTAssertEqual(stored.name, "Late renamed definition")
            XCTAssertEqual(stored.type, .url)
            XCTAssertEqual(stored.sortOrder, 88)
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT winningId FROM syncIdentityAlias
                WHERE entityType = 'propertyDefinition'
                  AND losingId = 'z-property'
                """), "a-property")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT isDirty FROM syncState
                WHERE entityType = 'propertyDefinition'
                  AND entityId = 'a-property'
                """), 1)
        }
    }

    func testLateRetiredDefinitionWithMissingWinnerIsDeletedAgainWithoutResurrection() async throws {
        let library = makeLibrary()
        var winner = PropertyDefinition(
            syncId: "a-property",
            name: "Shared definition",
            type: .string
        )
        var loser = PropertyDefinition(
            syncId: "z-property",
            name: "Before collision",
            type: .string
        )
        try db.savePropertyDefinition(&winner)
        try db.savePropertyDefinition(&loser)
        let collision = PropertyDefinition.makeRecord(
            recordName: "propertyDefinition:\(loser.syncId)",
            definition: PropertyDefinition(
                syncId: loser.syncId,
                name: winner.name,
                type: .string
            )
        )
        let loserSyncId = loser.syncId
        try await db.dbWriter.write { db in
            try self.store.setApplyingRemote(db)
            XCTAssertTrue(try SyncEntityType.propertyDefinition.applyRemoteRecord(
                collision,
                entityId: loserSyncId,
                db: db,
                stateStore: self.store
            ))
            try db.execute(
                sql: "DELETE FROM propertyDefinition WHERE syncId = 'a-property'"
            )
            try self.store.clearApplyingRemote(db)
        }
        let late = PropertyDefinition.makeRecord(
            recordName: "propertyDefinition:\(loserSyncId)",
            definition: PropertyDefinition(
                syncId: loserSyncId,
                name: "Recreated by old peer",
                type: .url
            )
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [late],
            deletions: []
        )
        XCTAssertTrue(applied)

        try await db.dbWriter.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM propertyDefinition
                    WHERE syncId IN ('a-property', 'z-property')
                    """),
                0
            )
            let tombstone = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT confirmedByServer, isPushEligible FROM tombstone
                WHERE entityType = 'propertyDefinition'
                  AND entityId = 'z-property'
                """))
            XCTAssertEqual(tombstone["confirmedByServer"] as Int?, 0)
            XCTAssertEqual(tombstone["isPushEligible"] as Int?, 1)
        }
    }
}
#endif
