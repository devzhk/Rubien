#if os(macOS)
import Foundation
import ArgumentParser
import RubienCore
import RubienSync
import GRDB

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Inspect iCloud sync state.",
        subcommands: [StatusCommand.self, AcknowledgeWriterUpgradeCommand.self]
    )
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print sync state as JSON."
    )

    @Flag(
        name: .long,
        help: "Check dirty PDF cache rows against files in the active library."
    )
    var checkPdfFiles = false

    func run() throws {
        let defaults = UserDefaults.standard

        // DB may not exist in a fresh environment (no library created yet).
        // In that case we return zeroed-out counts rather than failing.
        let dirtyByType: [String: Int]
        let confirmed: Int
        let unconfirmed: Int
        let baselineState: String
        let pdfBackfillRemaining: Int
        let identityDiagnostics: [String: Any]
        let pdfMaterializationDiagnostics: [String: Any]?

        // The explicit filesystem audit must fail closed: returning a clean
        // zero-count object when the library cannot be opened would make the
        // recovery command actively misleading.
        let pool: DatabasePool?
        if checkPdfFiles {
            pool = try makePool()
        } else {
            pool = try? makePool()
        }
        if let pool {
            dirtyByType = (try? pool.read { db in
                var counts: [String: Int] = [:]
                for type in SyncEntityType.allCases {
                    let n = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM syncState WHERE entityType = ? AND isDirty = 1",
                        arguments: [type.rawValue]
                    ) ?? 0
                    counts[type.rawValue] = n
                }
                return counts
            }) ?? [:]

            let tombstoneCounts = try? pool.read { db -> (Int, Int) in
                let c = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone WHERE confirmedByServer = 1") ?? 0
                let u = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone WHERE confirmedByServer = 0") ?? 0
                return (c, u)
            }
            confirmed = tombstoneCounts?.0 ?? 0
            unconfirmed = tombstoneCounts?.1 ?? 0

            baselineState = (try? pool.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM syncSession WHERE key='baselineState'")
                    ?? "pending"
            }) ?? "pending"

            // Counts dirty referencePDF syncState rows — what's actually
            // in flight to CloudKit. pdfUploadQueue empties at drainer
            // hand-off, so reading from there would bottom out long
            // before the upload completes (matches dirtyByEntityType).
            pdfBackfillRemaining = (try? pool.read { db in
                try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM syncState WHERE entityType='referencePDF' AND isDirty=1") ?? 0
            }) ?? 0
            identityDiagnostics = (try? pool.read { db in
                try Self.jsonObject(
                    SyncIdentityDiagnostics.read(from: db)
                )
            }) ?? Self.identityFallback
            if checkPdfFiles {
                pdfMaterializationDiagnostics = try Self.jsonObject(
                    try PDFMaterializationDiagnostics.read(
                        from: pool,
                        pdfStorageURL: AppDatabase.pdfStorageURL
                    )
                )
            } else {
                pdfMaterializationDiagnostics = nil
            }
        } else {
            dirtyByType = [:]
            confirmed = 0
            unconfirmed = 0
            baselineState = "pending"
            pdfBackfillRemaining = 0
            identityDiagnostics = Self.identityFallback
            pdfMaterializationDiagnostics = nil
        }

        let sidecarPath = AppDatabase.syncEngineStateURL
        let sidecarExists = FileManager.default.fileExists(atPath: sidecarPath.path)
        let sidecarMtime: String?
        if sidecarExists,
           let attrs = try? FileManager.default.attributesOfItem(atPath: sidecarPath.path),
           let date = attrs[.modificationDate] as? Date {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            sidecarMtime = fmt.string(from: date)
        } else {
            sidecarMtime = nil
        }

        let lockFile = SyncFileLock.defaultURL
        let appLockHeld: Bool
        if FileManager.default.fileExists(atPath: lockFile.path),
           let lock = try? SyncFileLock(fileURL: lockFile) {
            let acquired = (try? lock.tryLockExclusive()) ?? false
            if acquired { try? lock.unlock() }
            appLockHeld = !acquired
        } else {
            appLockHeld = false
        }

        // JSONSerialization rejects Optional<T>.none — a bare `sidecarMtime`
        // bound as Any would serialize as the string "nil" or throw,
        // depending on the Swift runtime. Use NSNull explicitly for
        // absent optionals so the contract stays stable.
        let syncEngineState: [String: Any] = [
            "sidecarPath": sidecarPath.path,
            "sidecarExists": sidecarExists,
            "sidecarLastModified": sidecarMtime.map { $0 as Any } ?? NSNull()
        ]

        let output: [String: Any] = [
            "enabled": defaults.bool(forKey: "rubien.sync.enabled"),
            "containerIdentifier": SyncConstants.containerIdentifier,
            "entitlementPresent": Bundle.main.object(
                forInfoDictionaryKey: "com.apple.developer.icloud-container-identifiers"
            ) != nil,
            "iCloudAccountAvailable": FileManager.default.ubiquityIdentityToken != nil,
            "appLockHeld": appLockHeld,
            "baselineState": baselineState,
            "dirtyByEntityType": dirtyByType,
            "tombstoneCount": ["confirmed": confirmed, "unconfirmed": unconfirmed],
            "pdfBackfillRemaining": pdfBackfillRemaining,
            "identity": identityDiagnostics,
            "pdfMaterialization": pdfMaterializationDiagnostics
                ?? NSNull(),
            "syncEngineState": syncEngineState,
            "schemaVersion": AppDatabase.currentSchemaVersion
        ]

        let data = try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func jsonObject<T: Encodable>(
        _ value: T
    ) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
            ?? [:]
    }

    private func makePool() throws -> DatabasePool {
        let url = AppDatabase.syncEngineStateURL
            .deletingLastPathComponent()
            .appendingPathComponent("library.sqlite")
        return try DatabasePool(path: url.path)
    }

    /// Conservative output for a missing or pre-v13 library. Keeping the
    /// target schema visible while reporting the gate as required lets an
    /// upgrade diagnostic remain machine-readable before migration runs.
    private static var identityFallback: [String: Any] {
        [
            "identitySchemaVersion": SyncIdentityDiagnostics.identitySchemaVersion,
            "identityCountsByEntityType": [:],
            "quarantinedRecordCount": 0,
            "unresolvedGlobalForeignKeyCount": 0,
            "invalidRemoteRecordCount": 0,
            "ineligibleLegacyTombstoneCount": 0,
            "fullHistoryReplayPending": true,
            "writerUpgradeRequired": true,
            "blockedSaveCount": 0,
            "blockedDeleteCount": 0,
            "contradictoryIntentCount": 0,
            "pushInFlightCount": 0,
            "removableOrphanSyncStateCount": 0,
            "preservedOrphanSyncStateCount": 0,
            "unpublishedLiveEntityCount": 0,
            "missingPDFCacheUploadCount": 0,
            "stalePDFIdentityCount": 0,
            "ambiguousPDFIdentityCount": 0,
            "writerUpgradeAcknowledgedAt": NSNull(),
            "writerUpgradeAcknowledgedSchemaVersion": NSNull(),
        ]
    }
}

struct AcknowledgeWriterUpgradeCommand: ParsableCommand {
    static let confirmationText = "ALL-WRITERS-UPGRADED"
    static let configuration = CommandConfiguration(
        commandName: "acknowledge-writer-upgrade",
        abstract: "Release v12-readable outbound sync work after every writable Mac is upgraded or offline."
    )

    @Option(
        name: .long,
        help: "Must be exactly \"ALL-WRITERS-UPGRADED\"."
    )
    var confirm: String

    func run() throws {
        guard confirm == Self.confirmationText else {
            throw ValidationError(
                "Refusing to release legacy-addressable writes. Pass --confirm \(Self.confirmationText) only after every writable Mac has v13 or is offline."
            )
        }

        let lock = try SyncFileLock(fileURL: SyncFileLock.defaultURL)
        guard try lock.tryLockExclusive() else {
            throw ValidationError(
                "Rubien is currently syncing. Quit the app, run this acknowledgement, then reopen it so released work is enqueued safely."
            )
        }
        defer { try? lock.unlock() }

        let pool = try makePool()
        try pool.write { db in
            let hasV13 = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM grdb_migrations WHERE identifier = 'v13'
                )
                """) ?? false
            guard hasV13 else {
                throw ValidationError(
                    "The library has not completed its v13 identity migration. Open it with the matching Rubien app before acknowledging the writer upgrade."
                )
            }
            try SyncStateStore().acknowledgeWriterUpgrade(db)
        }
        let output: [String: Any] = [
            "acknowledged": true,
            "identitySchemaVersion": SyncIdentityDiagnostics.identitySchemaVersion,
            "schemaVersion": AppDatabase.currentSchemaVersion,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func makePool() throws -> DatabasePool {
        let url = AppDatabase.syncEngineStateURL
            .deletingLastPathComponent()
            .appendingPathComponent("library.sqlite")
        return try DatabasePool(path: url.path)
    }
}
#endif
