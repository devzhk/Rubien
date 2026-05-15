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
        subcommands: [StatusCommand.self]
    )
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print sync state as JSON."
    )

    func run() throws {
        let defaults = UserDefaults.standard

        // DB may not exist in a fresh environment (no library created yet).
        // In that case we return zeroed-out counts rather than failing.
        let dirtyByType: [String: Int]
        let confirmed: Int
        let unconfirmed: Int
        let baselineState: String
        let pdfBackfillRemaining: Int

        if let pool = try? makePool() {
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
        } else {
            dirtyByType = [:]
            confirmed = 0
            unconfirmed = 0
            baselineState = "pending"
            pdfBackfillRemaining = 0
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

    private func makePool() throws -> DatabasePool {
        let url = AppDatabase.syncEngineStateURL
            .deletingLastPathComponent()
            .appendingPathComponent("library.sqlite")
        return try DatabasePool(path: url.path)
    }
}
#endif
