#if os(macOS)
import CloudKit
import GRDB
import XCTest
@testable import RubienCore
@testable import RubienSync

/// Deterministic convergence coverage for logical rows that can be created
/// independently under different global identities.
final class IdentityReconciliationTests: XCTestCase {
    private var stateURLs: [URL] = []

    override func tearDown() {
        for url in stateURLs { try? FileManager.default.removeItem(at: url) }
        stateURLs = []
        super.tearDown()
    }

    private func makeLibrary(_ database: AppDatabase) -> SyncedLibrary {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).engine-state")
        stateURLs.append(stateURL)
        return SyncedLibrary(
            appDatabase: database,
            stateFileURL: stateURL,
            pdfAssetSyncEnabledProvider: { true }
        )
    }

    private func propertyValueRecord(
        syncId: String,
        referenceSyncId: String,
        propertySyncId: String,
        value: String
    ) -> CKRecord {
        PropertyValue.makeRecord(
            recordName: SyncEntityType.propertyValue.qualifiedRecordName(
                entityId: syncId
            ),
            propertyValue: PropertyValue(
                syncId: syncId,
                referenceId: 0,
                referenceSyncId: referenceSyncId,
                propertyId: 0,
                propertySyncId: propertySyncId,
                value: value
            )
        )
    }

    private func assertPropertyValueConverges(
        firstSyncId: String,
        secondSyncId: String
    ) async throws {
        let database = try AppDatabase(DatabaseQueue())
        let library = makeLibrary(database)
        var reference = Reference(syncId: "reference-global", title: "Parent")
        try database.saveReference(&reference)
        var property = PropertyDefinition(
            syncId: "property-global",
            name: "Custom field",
            type: .string
        )
        try database.savePropertyDefinition(&property)

        let firstApplied = await library.applyFetchedRecordsForTest(
            modifications: [propertyValueRecord(
                syncId: firstSyncId,
                referenceSyncId: reference.syncId,
                propertySyncId: property.syncId,
                value: "first"
            )],
            deletions: []
        )
        XCTAssertTrue(firstApplied)
        let secondApplied = await library.applyFetchedRecordsForTest(
            modifications: [propertyValueRecord(
                syncId: secondSyncId,
                referenceSyncId: reference.syncId,
                propertySyncId: property.syncId,
                value: "second"
            )],
            deletions: []
        )
        XCTAssertTrue(secondApplied)

        let derived = "\(reference.syncId)/\(property.syncId)"
        let state: (
            count: Int,
            syncId: String?,
            value: String?,
            loserStateCount: Int,
            loserTombstoneCount: Int,
            winnerTombstoneCount: Int
        ) = try await database.dbWriter.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT syncId, value FROM propertyValue")
            return (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM propertyValue") ?? -1,
                row?["syncId"],
                row?["value"],
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM syncState
                    WHERE entityType = 'propertyValue' AND entityId = ?
                    """, arguments: [derived]) ?? -1,
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM tombstone
                    WHERE entityType = 'propertyValue' AND entityId = ?
                      AND isPushEligible = 1
                    """, arguments: [derived]) ?? -1,
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM tombstone
                    WHERE entityType = 'propertyValue' AND entityId = '900'
                    """) ?? -1
            )
        }
        XCTAssertEqual(state.count, 1)
        XCTAssertEqual(state.syncId, "900", "canonical decimal legacy identity wins")
        XCTAssertEqual(state.value, "second", "latest applied scalar is preserved")
        XCTAssertEqual(state.loserStateCount, 0)
        XCTAssertEqual(state.loserTombstoneCount, 1)
        XCTAssertEqual(state.winnerTombstoneCount, 0)
    }

    func testPropertyValueLegacyAndDerivedConvergeInBothArrivalOrders() async throws {
        let derived = "reference-global/property-global"
        try await assertPropertyValueConverges(
            firstSyncId: "900",
            secondSyncId: derived
        )
        try await assertPropertyValueConverges(
            firstSyncId: derived,
            secondSyncId: "900"
        )
    }

    func testDefaultViewUUIDCollisionKeepsLexicalWinnerAndRetiresFetchedLoser() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let library = makeLibrary(database)
        let local: (id: Int64, syncId: String) = try await database.dbWriter.read { db in
            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT id, syncId FROM databaseView WHERE isDefault = 1"
            ))
            return (row["id"], row["syncId"])
        }
        let incomingSyncId = "zzzz-default-view"
        XCTAssertEqual(
            SyncIdentifier.preferred(local.syncId, incomingSyncId),
            local.syncId
        )
        let incoming = DatabaseView(
            syncId: incomingSyncId,
            name: "Remote Default",
            isDefault: true
        )
        let record = DatabaseView.makeRecord(
            recordName: SyncEntityType.databaseView.qualifiedRecordName(
                entityId: incomingSyncId
            ),
            view: incoming
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [record],
            deletions: []
        )
        XCTAssertTrue(applied)

        let state: (Int, Int64?, String?, String?, Int, Int) = try await database.dbWriter.read { db in
            return (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM databaseView WHERE isDefault = 1") ?? -1,
                try Int64.fetchOne(db, sql: "SELECT id FROM databaseView WHERE isDefault = 1"),
                try String.fetchOne(db, sql: "SELECT syncId FROM databaseView WHERE isDefault = 1"),
                try String.fetchOne(db, sql: "SELECT name FROM databaseView WHERE isDefault = 1"),
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM syncState
                    WHERE entityType = 'databaseView' AND entityId = ?
                    """, arguments: [incomingSyncId]) ?? -1,
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM tombstone
                    WHERE entityType = 'databaseView' AND entityId = ?
                      AND isPushEligible = 1
                    """, arguments: [incomingSyncId]) ?? -1
            )
        }
        XCTAssertEqual(state.0, 1)
        XCTAssertEqual(state.1, local.id, "local surrogate row remains stable")
        XCTAssertEqual(state.2, local.syncId)
        XCTAssertEqual(state.3, "Remote Default")
        XCTAssertEqual(state.4, 0, "retired fetched identity has no live state")
        XCTAssertEqual(state.5, 1, "fetched loser is deleted by exact identity")
    }

    func testDefaultViewDecimalIdentityAdoptsWithoutTombstoningUnsyncedLocalUUID() async throws {
        let database = try AppDatabase(DatabaseQueue())
        let library = makeLibrary(database)
        let local: (id: Int64, syncId: String) = try await database.dbWriter.read { db in
            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT id, syncId FROM databaseView WHERE isDefault = 1"
            ))
            return (row["id"], row["syncId"])
        }
        let incoming = DatabaseView(
            syncId: "42",
            name: "Legacy Default",
            isDefault: true
        )
        let record = DatabaseView.makeRecord(
            recordName: "databaseView:42",
            view: incoming
        )

        let applied = await library.applyFetchedRecordsForTest(
            modifications: [record],
            deletions: []
        )
        XCTAssertTrue(applied)

        let state: (Int64?, String?, Int, Int) = try await database.dbWriter.read { db in
            return (
                try Int64.fetchOne(db, sql: "SELECT id FROM databaseView WHERE isDefault = 1"),
                try String.fetchOne(db, sql: "SELECT syncId FROM databaseView WHERE isDefault = 1"),
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM syncState
                    WHERE entityType = 'databaseView' AND entityId = ?
                    """, arguments: [local.syncId]) ?? -1,
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM tombstone
                    WHERE entityType = 'databaseView' AND entityId = ?
                    """, arguments: [local.syncId]) ?? -1
            )
        }
        XCTAssertEqual(state.0, local.id)
        XCTAssertEqual(state.1, "42")
        XCTAssertEqual(state.2, 0)
        XCTAssertEqual(state.3, 0, "a never-observed local UUID is not deleted remotely")
    }

    func testAliasRecordingFlattensChainsAndRejectsCyclesAndExcessDepth() throws {
        let database = try AppDatabase(DatabaseQueue())
        try database.dbWriter.write { db in
            try SyncIdentityAliasStore.record(
                entityType: .tag,
                losingId: "alias-a",
                winningId: "alias-b",
                db: db
            )
            try SyncIdentityAliasStore.record(
                entityType: .tag,
                losingId: "alias-b",
                winningId: "alias-c",
                db: db
            )
            XCTAssertEqual(
                try SyncIdentityAliasStore.resolve(
                    entityType: .tag,
                    identity: "alias-a",
                    db: db
                ),
                "alias-c"
            )
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT winningId FROM syncIdentityAlias
                WHERE entityType = 'tag' AND losingId = 'alias-a'
                """), "alias-c")

            XCTAssertThrowsError(try SyncIdentityAliasStore.record(
                entityType: .tag,
                losingId: "alias-c",
                winningId: "alias-a",
                db: db
            )) { error in
                XCTAssertEqual(
                    error as? SyncIdentityAliasStore.ResolutionError,
                    .cycle(entityType: "tag", identity: "alias-c")
                )
            }

            try db.execute(sql: "DELETE FROM syncIdentityAlias")
            for index in 0 ... 32 {
                try db.execute(sql: """
                    INSERT INTO syncIdentityAlias(
                        entityType, losingId, winningId, createdAt
                    ) VALUES('tag', ?, ?, ?)
                    """, arguments: [
                        "depth-\(index)", "depth-\(index + 1)", Date(),
                    ])
            }
            XCTAssertThrowsError(try SyncIdentityAliasStore.resolve(
                entityType: .tag,
                identity: "depth-0",
                db: db
            )) { error in
                XCTAssertEqual(
                    error as? SyncIdentityAliasStore.ResolutionError,
                    .depthExceeded(entityType: "tag", identity: "depth-0")
                )
            }
        }
    }
}
#endif
