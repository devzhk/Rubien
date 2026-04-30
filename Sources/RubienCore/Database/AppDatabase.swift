import Combine
import Foundation
import GRDB
import os.log

private let appDatabaseLog = Logger(subsystem: "Rubien", category: "AppDatabase")

/// SQL expression that produces the current time as an ISO-8601 string with
/// millisecond precision. Used both as a column default on `dateModified` /
/// `deletedAt` and inside the sync trigger bodies so a single format is used
/// across schema and triggers.
private let sqlNowISO8601 = "(strftime('%Y-%m-%dT%H:%M:%fZ','now'))"

/// Per-entry outcome from `AppDatabase.classifyImportEntries`. The Zotero importer uses
/// this to decide whether to copy each attachment:
/// - `.fresh`, `.dbDuplicateWithoutPDF` → copy (merge will attach in the latter case);
/// - `.dbDuplicateWithPDF`, `.intraBatchDuplicate` → skip copy to avoid orphaning.
enum ImportClassification: Equatable {
    case fresh
    case dbDuplicateWithPDF
    case dbDuplicateWithoutPDF
    case intraBatchDuplicate
}

public final class AppDatabase: Sendable {
    public let dbWriter: any DatabaseWriter

    public init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // Never wipe the user's live library by default. If a local developer
        // explicitly wants schema-change resets while iterating, they can opt in
        // via SWIFTLIB_RESET_DB_ON_SCHEMA_CHANGE=1 for that launch.
        migrator.eraseDatabaseOnSchemaChange =
            ProcessInfo.processInfo.environment["SWIFTLIB_RESET_DB_ON_SCHEMA_CHANGE"] == "1"
        #endif

        migrator.registerMigration("v1") { db in
            // Tags
            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("color", .text).notNull().defaults(to: "#007AFF")
                t.column("dateModified", .datetime).notNull().defaults(sql: sqlNowISO8601)
            }

            // References
            try db.create(table: "reference") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("authors", .text).notNull().defaults(to: "")
                t.column("authorsNormalized", .text).notNull().defaults(to: "")
                t.column("year", .integer)
                t.column("journal", .text)
                t.column("volume", .text)
                t.column("issue", .text)
                t.column("pages", .text)
                t.column("doi", .text)
                t.column("url", .text)
                t.column("abstract", .text)
                t.column("dateAdded", .datetime).notNull()
                t.column("dateModified", .datetime).notNull()
                t.column("pdfPath", .text)
                t.column("notes", .text)
                t.column("webContent", .text)
                t.column("siteName", .text)
                t.column("favicon", .text)
                t.column("referenceType", .text).notNull().defaults(to: "Journal Article")
                t.column("metadataSource", .text)
                t.column("verificationStatus", .text).notNull().defaults(to: VerificationStatus.legacy.rawValue)
                t.column("acceptedByRuleID", .text)
                t.column("recordKey", .text)
                t.column("verificationSourceURL", .text)
                t.column("evidenceBundleHash", .text)
                t.column("verifiedAt", .datetime)
                t.column("reviewedBy", .text)
                t.column("readingStatus", .text).notNull().defaults(to: ReadingStatus.unread.rawValue)
                // Extended metadata (P0)
                t.column("publisher", .text)
                t.column("publisherPlace", .text)
                t.column("edition", .text)
                t.column("editors", .text)
                t.column("isbn", .text)
                t.column("issn", .text)
                t.column("accessedDate", .text)
                t.column("issuedMonth", .integer)
                t.column("issuedDay", .integer)
                // Extended metadata (P1)
                t.column("translators", .text)
                t.column("eventTitle", .text)
                t.column("eventPlace", .text)
                t.column("genre", .text)
                t.column("institution", .text)
                t.column("number", .text)
                t.column("collectionTitle", .text)
                t.column("numberOfPages", .text)
                // Extended metadata (P2)
                t.column("language", .text)
                t.column("pmid", .text)
                t.column("pmcid", .text)
            }

            // Reference indexes
            try db.create(index: "reference_year", on: "reference", columns: ["year"])
            try db.create(index: "reference_dateAdded", on: "reference", columns: ["dateAdded"])
            try db.create(index: "reference_doi", on: "reference", columns: ["doi"])
            try db.create(index: "reference_referenceType", on: "reference", columns: ["referenceType"])
            try db.create(index: "reference_authorsNormalized", on: "reference", columns: ["authorsNormalized"])
            try db.create(index: "reference_verificationStatus", on: "reference", columns: ["verificationStatus"])
            try db.create(index: "reference_readingStatus", on: "reference", columns: ["readingStatus"])
            try db.create(index: "reference_recordKey", on: "reference", columns: ["recordKey"])
            try db.create(index: "reference_evidenceBundleHash", on: "reference", columns: ["evidenceBundleHash"])
            try db.create(index: "reference_metadataSource", on: "reference", columns: ["metadataSource"])
            try db.create(index: "reference_isbn", on: "reference", columns: ["isbn"])
            try db.create(index: "reference_issn", on: "reference", columns: ["issn"])
            try db.create(index: "reference_pmid", on: "reference", columns: ["pmid"])
            try db.create(index: "reference_pmcid", on: "reference", columns: ["pmcid"])

            // FTS5 Full-Text Search virtual table (synced with reference)
            try db.create(virtualTable: "referenceFts", using: FTS5()) { t in
                t.synchronize(withTable: "reference")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("authorsNormalized")
                t.column("journal")
                t.column("abstract")
                t.column("notes")
                t.column("webContent")
                t.column("siteName")
                t.column("doi")
                t.column("publisher")
                t.column("isbn")
                t.column("issn")
                t.column("institution")
            }

            // Reference-Tag pivot table
            try db.create(table: "referenceTag") { t in
                t.column("referenceId", .integer).notNull().references("reference", onDelete: .cascade)
                t.column("tagId", .integer).notNull().references("tag", onDelete: .cascade)
                t.column("dateModified", .datetime).notNull().defaults(sql: sqlNowISO8601)
                t.primaryKey(["referenceId", "tagId"])
            }
            try db.create(index: "referenceTag_tagId", on: "referenceTag", columns: ["tagId"])

            // PDF annotations
            try db.create(table: "pdfAnnotation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("referenceId", .integer).notNull().references("reference", onDelete: .cascade)
                t.column("type", .text).notNull().defaults(to: "highlight")
                t.column("selectedText", .text)
                t.column("noteText", .text)
                t.column("color", .text).notNull().defaults(to: "#FFDE59")
                t.column("pageIndex", .integer).notNull()
                t.column("boundsX", .double).notNull()
                t.column("boundsY", .double).notNull()
                t.column("boundsWidth", .double).notNull()
                t.column("boundsHeight", .double).notNull()
                t.column("rectsData", .text).notNull().defaults(to: "[]")
                t.column("dateCreated", .datetime).notNull()
                t.column("dateModified", .datetime).notNull().defaults(sql: sqlNowISO8601)
            }
            try db.create(index: "pdfAnnotation_referenceId", on: "pdfAnnotation", columns: ["referenceId"])
            try db.create(index: "pdfAnnotation_pageIndex", on: "pdfAnnotation", columns: ["pageIndex"])

            // Web annotations
            try db.create(table: "webAnnotation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("referenceId", .integer).notNull().references("reference", onDelete: .cascade)
                t.column("type", .text).notNull().defaults(to: AnnotationType.highlight.rawValue)
                t.column("selectedText", .text).notNull()
                t.column("noteText", .text)
                t.column("color", .text).notNull().defaults(to: "#FFDE59")
                t.column("anchorText", .text).notNull()
                t.column("prefixText", .text)
                t.column("suffixText", .text)
                t.column("dateCreated", .datetime).notNull()
                t.column("dateModified", .datetime).notNull().defaults(sql: sqlNowISO8601)
            }
            try db.create(index: "webAnnotation_referenceId", on: "webAnnotation", columns: ["referenceId"])
            try db.create(index: "webAnnotation_dateCreated", on: "webAnnotation", columns: ["dateCreated"])

            // Metadata intake pipeline
            try db.create(table: "metadataIntake") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceKind", .text).notNull()
                t.column("verificationStatus", .text).notNull()
                t.column("title", .text).notNull()
                t.column("originalInput", .text)
                t.column("sourceURL", .text)
                t.column("pdfPath", .text)
                t.column("seedJSON", .text)
                t.column("fallbackReferenceJSON", .text)
                t.column("currentReferenceJSON", .text)
                t.column("candidatesJSON", .text)
                t.column("statusMessage", .text)
                t.column("linkedReferenceId", .integer).references("reference", onDelete: .setNull)
                t.column("evidenceBundleHash", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "metadataIntake_verificationStatus", on: "metadataIntake", columns: ["verificationStatus"])
            try db.create(index: "metadataIntake_linkedReferenceId", on: "metadataIntake", columns: ["linkedReferenceId"])
            try db.create(index: "metadataIntake_updatedAt", on: "metadataIntake", columns: ["updatedAt"])

            try db.create(table: "metadataEvidence") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("intakeId", .integer).references("metadataIntake", onDelete: .cascade)
                t.column("referenceId", .integer).references("reference", onDelete: .cascade)
                t.column("bundleHash", .text).notNull()
                t.column("source", .text).notNull()
                t.column("recordKey", .text)
                t.column("sourceURL", .text)
                t.column("fetchMode", .text).notNull()
                t.column("payloadJSON", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "metadataEvidence_bundleHash", on: "metadataEvidence", columns: ["bundleHash"])
            try db.create(index: "metadataEvidence_intakeId", on: "metadataEvidence", columns: ["intakeId"])
            try db.create(index: "metadataEvidence_referenceId", on: "metadataEvidence", columns: ["referenceId"])

            // Database views
            try db.create(table: "databaseView") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("icon", .text).notNull().defaults(to: "tablecells")
                t.column("scopeJSON", .text).notNull().defaults(to: #"{"all":{}}"#)
                t.column("columnsJSON", .text).notNull().defaults(to: "[]")
                t.column("filtersJSON", .text).notNull().defaults(to: "[]")
                t.column("sortsJSON", .text).notNull().defaults(to: "[]")
                t.column("groupByJSON", .text)
                t.column("columnWrapsJSON", .text).notNull().defaults(to: "[]")
                t.column("isDefault", .boolean).notNull().defaults(to: false)
                t.column("displayOrder", .integer).notNull().defaults(to: 0)
                t.column("dateCreated", .datetime).notNull()
                t.column("dateModified", .datetime).notNull()
            }

            let defaultColumnsJSON = (try? String(
                data: JSONEncoder().encode(ColumnConfig.defaultColumns),
                encoding: .utf8
            )) ?? "[]"
            let defaultSortsJSON = (try? String(
                data: JSONEncoder().encode([ViewSort.defaultSort]),
                encoding: .utf8
            )) ?? "[]"

            try db.execute(sql: """
                INSERT INTO databaseView (name, icon, scopeJSON, columnsJSON, filtersJSON, sortsJSON, columnWrapsJSON, isDefault, displayOrder, dateCreated, dateModified)
                VALUES ('All References', 'books.vertical', '{"all":{}}', ?, '[]', ?, '[]', 1, 0, datetime('now'), datetime('now'))
                """, arguments: [defaultColumnsJSON, defaultSortsJSON])

            // Custom properties
            try db.create(table: "propertyDefinition") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("type", .text).notNull().defaults(to: "string")
                t.column("optionsJSON", .text).notNull().defaults(to: "[]")
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isDefault", .boolean).notNull().defaults(to: false)
                t.column("defaultFieldKey", .text)
                t.column("isVisible", .boolean).notNull().defaults(to: true)
                t.column("dateModified", .datetime).notNull().defaults(sql: sqlNowISO8601)
            }

            try db.create(table: "propertyValue") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("referenceId", .integer).notNull()
                    .references("reference", onDelete: .cascade)
                t.column("propertyId", .integer).notNull()
                    .references("propertyDefinition", onDelete: .cascade)
                t.column("value", .text)
                t.column("dateModified", .datetime).notNull().defaults(sql: sqlNowISO8601)
                t.uniqueKey(["referenceId", "propertyId"])
            }
            try db.create(indexOn: "propertyValue", columns: ["referenceId"])

            // Seed default properties
            let typeOptions: [SelectOption] = [
                .init(value: "Journal Article", color: "#007AFF"),
                .init(value: "Book", color: "#34C759"),
                .init(value: "Book Section", color: "#00C7BE"),
                .init(value: "Conference Paper", color: "#AF52DE"),
                .init(value: "Preprint", color: "#5AC8FA"),
                .init(value: "Thesis", color: "#FF9500"),
                .init(value: "Report", color: "#A2845E"),
                .init(value: "Web Page", color: "#30B0C7"),
                .init(value: "Dataset", color: "#FFCC00"),
                .init(value: "Software", color: "#BF5AF2"),
                .init(value: "Patent", color: "#FF6482"),
                .init(value: "Magazine Article", color: "#64D2FF"),
                .init(value: "Newspaper Article", color: "#8E8E93"),
                .init(value: "Standard", color: "#FF2D55"),
                .init(value: "Manuscript", color: "#A2845E"),
                .init(value: "Interview", color: "#FF3B30"),
                .init(value: "Presentation", color: "#007AFF"),
                .init(value: "Blog Post", color: "#34C759"),
                .init(value: "Forum Post", color: "#5AC8FA"),
                .init(value: "Legal Case", color: "#8E8E93"),
                .init(value: "Legislation", color: "#FF9500"),
                .init(value: "Other", color: "#8E8E93"),
            ]
            let typeOptionsJSON = (try? String(data: JSONEncoder().encode(typeOptions), encoding: .utf8)) ?? "[]"

            let statusOptions: [SelectOption] = [
                .init(value: "Unread", color: "#8E8E93"),
                .init(value: "Reading", color: "#007AFF"),
                .init(value: "Skimmed", color: "#FF9500"),
                .init(value: "Read", color: "#34C759"),
            ]
            let statusOptionsJSON = (try? String(data: JSONEncoder().encode(statusOptions), encoding: .utf8)) ?? "[]"

            // 6 visible defaults
            let visibleDefaults: [(name: String, type: String, optionsJSON: String, fieldKey: String)] = [
                ("Type", "singleSelect", typeOptionsJSON, "referenceType"),
                ("Status", "singleSelect", statusOptionsJSON, "readingStatus"),
                ("Tags", "multiSelect", "[]", "tags"),
                ("Year", "number", "[]", "year"),
                ("DOI", "url", "[]", "doi"),
                ("URL", "url", "[]", "url"),
            ]

            for (index, def) in visibleDefaults.enumerated() {
                try db.execute(sql: """
                    INSERT INTO propertyDefinition (name, type, optionsJSON, sortOrder, isDefault, defaultFieldKey, isVisible)
                    VALUES (?, ?, ?, ?, 1, ?, 1)
                    """, arguments: [def.name, def.type, def.optionsJSON, index, def.fieldKey])
            }

            // Hidden defaults (auto-populated by resolvers / importers)
            let hiddenDefaults: [(name: String, type: String, fieldKey: String)] = [
                ("Journal", "string", "journal"),
                ("Volume", "string", "volume"),
                ("Issue", "string", "issue"),
                ("Pages", "string", "pages"),
                ("Publisher", "string", "publisher"),
                ("Place", "string", "publisherPlace"),
                ("Edition", "string", "edition"),
                ("ISBN", "string", "isbn"),
                ("ISSN", "string", "issn"),
                ("Editors", "string", "editors"),
                ("Translators", "string", "translators"),
                ("Accessed Date", "string", "accessedDate"),
                ("Event", "string", "eventTitle"),
                ("Event Place", "string", "eventPlace"),
                ("Genre", "string", "genre"),
                ("Institution", "string", "institution"),
                ("Number", "string", "number"),
                ("Series", "string", "collectionTitle"),
                ("Pages Count", "string", "numberOfPages"),
                ("Language", "string", "language"),
                ("PMID", "string", "pmid"),
                ("PMCID", "string", "pmcid"),
            ]

            for (index, def) in hiddenDefaults.enumerated() {
                try db.execute(sql: """
                    INSERT INTO propertyDefinition (name, type, optionsJSON, sortOrder, isDefault, defaultFieldKey, isVisible)
                    VALUES (?, ?, '[]', ?, 1, ?, 0)
                    """, arguments: [def.name, def.type, visibleDefaults.count + index, def.fieldKey])
            }

            // MARK: - Sync bookkeeping
            // Tombstones track deletions so we can propagate them to CloudKit later.
            // entityType is the table name; entityId is the row's PK as TEXT (Int64
            // stringified until A-pks migrates to UUIDs).
            // `confirmedByServer` distinguishes tombstones the server has
            // acknowledged (safe to GC on the 30-day window) from pending
            // local deletes that still need to round-trip. Dropping an
            // unacknowledged tombstone too early can cause a later server
            // modification of the same recordID to resurrect the deleted
            // row locally — "delete beats edit" only works if the tombstone
            // marker is alive when the edit pull arrives.
            try db.create(table: "tombstone") { t in
                t.column("entityType", .text).notNull()
                t.column("entityId", .text).notNull()
                t.column("deletedAt", .datetime).notNull().defaults(sql: sqlNowISO8601)
                t.column("confirmedByServer", .integer).notNull().defaults(to: 0)
                t.primaryKey(["entityType", "entityId"])
            }
            try db.create(index: "tombstone_deletedAt", on: "tombstone", columns: ["deletedAt"])

            // syncState tracks which rows are dirty (need pushing) and caches the
            // last-known CKRecord system fields blob per row for optimistic concurrency.
            //
            // `pushInFlight` closes a TOCTOU window on `isDirty`: when the engine
            // builds a push batch, we stamp pushInFlight=1. If a local edit
            // fires the trigger mid-flight, the ON CONFLICT upsert clears
            // pushInFlight back to 0. On successful push ack, we only set
            // isDirty=0 if pushInFlight is still 1 — else a fresh edit has
            // landed and must be re-pushed.
            try db.create(table: "syncState") { t in
                t.column("entityType", .text).notNull()
                t.column("entityId", .text).notNull()
                t.column("systemFields", .blob)
                t.column("lastPushedAt", .datetime)
                t.column("isDirty", .integer).notNull().defaults(to: 1)
                t.column("pushInFlight", .integer).notNull().defaults(to: 0)
                t.primaryKey(["entityType", "entityId"])
            }
            try db.create(index: "syncState_isDirty", on: "syncState", columns: ["isDirty"])

            // syncSession is a scratch table for session-scoped flags the triggers
            // consult. The pull handler inserts ('applyingRemote','1') at the start of
            // its transaction so triggers don't re-dirty rows they're applying from the
            // cloud. Rows live only for the duration of that transaction.
            try db.create(table: "syncSession") { t in
                t.column("key", .text).notNull().primaryKey()
                t.column("value", .text).notNull()
            }

            // MARK: - Dirty-tracking triggers
            // One set per synced table. Triggers skip firing during remote apply
            // (when syncSession has an 'applyingRemote' row). Deletes produce a
            // tombstone and remove the corresponding syncState row. SQLite doesn't
            // support AFTER INSERT OR UPDATE in a single trigger, so INSERT and
            // UPDATE are emitted as two identical triggers from one template.
            let applyingRemoteGuard =
                "WHEN (SELECT value FROM syncSession WHERE key='applyingRemote') IS NULL"
            for table in self.syncedTables {
                let newKey = self.pkExpression(table: table, prefix: "NEW")
                let oldKey = self.pkExpression(table: table, prefix: "OLD")
                // A local edit that fires mid-push must also clear
                // pushInFlight so the matching save-ack won't clobber the
                // new isDirty=1 (see `pushInFlight` doc above).
                let markDirtyBody = """
                    INSERT INTO syncState(entityType, entityId, isDirty, pushInFlight)
                        VALUES('\(table)', \(newKey), 1, 0)
                        ON CONFLICT(entityType, entityId)
                            DO UPDATE SET isDirty = 1, pushInFlight = 0;
                    """

                for (suffix, event) in [("ai", "INSERT"), ("au", "UPDATE")] {
                    try db.execute(sql: """
                        CREATE TRIGGER \(table)_\(suffix) AFTER \(event) ON \(table)
                            \(applyingRemoteGuard)
                        BEGIN
                            \(markDirtyBody)
                        END;
                        """)
                }

                try db.execute(sql: """
                    CREATE TRIGGER \(table)_ad AFTER DELETE ON \(table)
                        \(applyingRemoteGuard)
                    BEGIN
                        INSERT INTO tombstone(entityType, entityId, deletedAt)
                            VALUES('\(table)', \(oldKey), \(sqlNowISO8601))
                            ON CONFLICT(entityType, entityId)
                                DO UPDATE SET deletedAt = excluded.deletedAt;
                        DELETE FROM syncState
                            WHERE entityType='\(table)' AND entityId=\(oldKey);
                    END;
                    """)
            }
        }

        migrator.registerMigration("v2") { db in
            // Per-device PDF cache. NOT in syncedTables — no triggers, no CKRecord.
            try db.create(table: "pdfCache") { t in
                t.column("referenceId", .integer)
                    .primaryKey()
                    .references("reference", onDelete: .cascade)
                t.column("localFilename", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("assetVersion", .integer).notNull().defaults(to: 1)
                t.column("materializedAt", .datetime)
                t.column("lastOpenedAt", .datetime).notNull().defaults(sql: sqlNowISO8601)
            }
            try db.create(index: "pdfCache_lastOpenedAt", on: "pdfCache", columns: ["lastOpenedAt"])

            // Per-device "yet to push" queue. Drained by PDFUploadQueue actor.
            try db.create(table: "pdfUploadQueue") { t in
                t.column("referenceId", .integer)
                    .primaryKey()
                    .references("reference", onDelete: .cascade)
                t.column("localFilename", .text).notNull()
                t.column("queuedAt", .datetime).notNull().defaults(sql: sqlNowISO8601)
            }
            try db.create(index: "pdfUploadQueue_queuedAt", on: "pdfUploadQueue", columns: ["queuedAt"])

            // Backfill existing pdfPath into the new tables. Hash is "pending"
            // — recomputed lazily on first read or upload to keep launch fast.
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                SELECT id, pdfPath, 'pending', 1, dateModified, dateModified
                FROM reference
                WHERE pdfPath IS NOT NULL AND pdfPath != ''
            """)
            try db.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                SELECT id, pdfPath, dateModified
                FROM reference
                WHERE pdfPath IS NOT NULL AND pdfPath != ''
            """)

            // Drop the now-orphan column. SQLite 3.35+ supports this directly.
            // macOS 14 ships SQLite 3.41+; we're well past the support floor.
            try db.execute(sql: "ALTER TABLE reference DROP COLUMN pdfPath")
        }

        return migrator
    }

    /// Test-only: applies the v2 schema/backfill steps to an arbitrary
    /// queue that already carries a v1-shaped `reference` table. Used by
    /// `MigrationV2Tests` to verify backfill without driving the full
    /// AppDatabase init path.
    public static func runV2MigrationForTesting(on queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v2") { db in
            try db.create(table: "pdfCache") { t in
                t.column("referenceId", .integer).primaryKey()
                t.column("localFilename", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("assetVersion", .integer).notNull().defaults(to: 1)
                t.column("materializedAt", .datetime)
                t.column("lastOpenedAt", .datetime).notNull().defaults(sql: "(datetime('now'))")
            }
            try db.create(table: "pdfUploadQueue") { t in
                t.column("referenceId", .integer).primaryKey()
                t.column("localFilename", .text).notNull()
                t.column("queuedAt", .datetime).notNull().defaults(sql: "(datetime('now'))")
            }
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                SELECT id, pdfPath, 'pending', 1, dateModified, dateModified
                FROM reference WHERE pdfPath IS NOT NULL AND pdfPath != ''
            """)
            try db.execute(sql: """
                INSERT INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                SELECT id, pdfPath, dateModified
                FROM reference WHERE pdfPath IS NOT NULL AND pdfPath != ''
            """)
        }
        try migrator.migrate(queue)
    }

    /// Tables whose rows sync to CloudKit. Order is not significant here; pull-side
    /// FK ordering is handled by the sync engine.
    private var syncedTables: [String] {
        [
            "reference",
            "tag",
            "referenceTag",
            "pdfAnnotation",
            "webAnnotation",
            "metadataIntake",
            "metadataEvidence",
            "propertyDefinition",
            "propertyValue",
            "databaseView",
        ]
    }

    /// The primary-key expression used inside triggers. `referenceTag` is a pivot with a
    /// composite key; its synthesized entityId is `referenceId<sep>tagId`. `prefix` is
    /// either "NEW" (INSERT/UPDATE) or "OLD" (DELETE).
    ///
    /// The separator literal `/` here must stay in lockstep with
    /// `SyncConstants.pivotSeparator` in the RubienSync target — they form a
    /// cross-layer contract (SQL trigger output vs Swift-side recordName
    /// builder). RubienCore can't import RubienSync, so the constant can't
    /// be shared; this comment is the only enforcement.
    private func pkExpression(table: String, prefix: String) -> String {
        switch table {
        case "referenceTag":
            return "\(prefix).referenceId || '/' || \(prefix).tagId"
        default:
            return "\(prefix).id"
        }
    }
}

// MARK: - Database Access
extension AppDatabase {
    public static let shared = makeShared()

    /// Shared App Group identifier. Both `Rubien.app` (sandboxed) and the
    /// bundled `rubien-cli` helper claim this entitlement so they read/write
    /// the same `library.sqlite` under `~/Library/Group Containers/`. SPM
    /// dev builds (no entitlement) fall through to `.applicationSupportDirectory`.
    static let appGroupID = "9TXK4V3SS8.com.rubien.shared"

    private static let storageRootLeaf = "Rubien"
    private static let libraryFilename = "library.sqlite"
    private static let syncEngineStateFilename = "sync-engine-state.bin"

    /// Memoized once-per-process storage root. `containerURL` access state
    /// doesn't flip mid-process (the entitlement is baked into the launched
    /// binary), so the expensive write-probe in `canAccessGroupContainer`
    /// runs exactly once instead of on every `pdfStorageURL` / subdir access.
    private static let baseRoot: URL = preferredStorageRoot(named: storageRootLeaf)

    /// Cached `RUBIEN_LIBRARY_ROOT` value (nil when unset/blank). Reading once
    /// lets `makeShared()` cheaply gate legacy migration on "did the caller
    /// pick this dir on purpose?" — otherwise an empty override target would
    /// silently absorb data from the legacy roots in `defaultLegacyRoots()`.
    private static let explicitStorageRoot: URL? = {
        guard let raw = ProcessInfo.processInfo.environment["RUBIEN_LIBRARY_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }()

    private static func preferredStorageRoot(named leaf: String) -> URL {
        let fm = FileManager.default

        // 0) Explicit override — path used verbatim, `leaf` NOT appended.
        //    Sandbox redirects override paths inside the GUI's container; only
        //    the non-sandboxed CLI / SPM dev builds escape that.
        if let override = explicitStorageRoot {
            return ensureDirectory(override, fallbackLeaf: leaf)
        }

        // 1) App Group container (signed builds with the entitlement).
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
           canAccessGroupContainer(group) {
            return ensureDirectory(group.appendingPathComponent(leaf, isDirectory: true), fallbackLeaf: leaf)
        }

        // 2) Application Support (unsandboxed, or sandboxed without App Group).
        //    On a sandboxed process macOS auto-redirects this to the per-app
        //    container; on an unsandboxed process it resolves to
        //    ~/Library/Application Support/. Either is fine — the migration
        //    helper in makeShared() handles catching up old installs.
        if let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return ensureDirectory(appSupport.appendingPathComponent(leaf, isDirectory: true), fallbackLeaf: leaf)
        }

        // 3) Temp dir — last-resort so the app doesn't crash with no DB path.
        return fm.temporaryDirectory.appendingPathComponent(leaf, isDirectory: true)
    }

    /// On macOS, `containerURL(forSecurityApplicationGroupIdentifier:)` can
    /// return a non-nil URL even when the container is not actually accessible
    /// (entitlement invalidated, profile mismatch, cert revoked). Guard with an
    /// actual write probe so we fall back to ~/Library/Application Support/ in
    /// those cases instead of stranding data at an unreachable path.
    private static func canAccessGroupContainer(_ url: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            let sentinel = url.appendingPathComponent(".rubien-access-probe")
            try Data().write(to: sentinel, options: .atomic)
            try? fm.removeItem(at: sentinel)
            return true
        } catch {
            appDatabaseLog.info("App Group container not writable: \(error.localizedDescription, privacy: .public) — falling back to Application Support")
            return false
        }
    }

    private static func ensureDirectory(_ url: URL, fallbackLeaf: String) -> URL {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            appDatabaseLog.error("Failed to create directory at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return FileManager.default.temporaryDirectory.appendingPathComponent(fallbackLeaf, isDirectory: true)
        }
    }

    private static func makeShared() -> AppDatabase {
        let dirURL = baseRoot
        // Skip legacy migration when the caller pointed us at an explicit dir;
        // they want isolation, not "and then we copied your old library in too."
        if explicitStorageRoot == nil {
            migrateLegacyLibraryIfNeeded(destination: dirURL)
        }

        do {
            let dbURL = dirURL.appendingPathComponent(libraryFilename)
            var config = Configuration()
            #if DEBUG
            if RubienCoreDebugLogging.sqlTrace {
                config.prepareDatabase { db in
                    db.trace { print("SQL: \($0)") }
                }
            }
            #endif
            let dbPool = try DatabasePool(path: dbURL.path, configuration: config)

            return try AppDatabase(dbPool)
        } catch {
            appDatabaseLog.error("Primary database setup failed at \(dirURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            do {
                return try AppDatabase(DatabaseQueue(path: ":memory:"))
            } catch {
                preconditionFailure("Unable to initialize in-memory database fallback: \(error)")
            }
        }
    }

    // MARK: Legacy library migration

    /// Sidecar entries that must move together with `library.sqlite`. Order
    /// matters on copy: everything else first, `library.sqlite` **last**, so a
    /// fully-populated staging directory is a reliable completion signal.
    private static let migrationEntries: [String] = [
        "\(libraryFilename)-wal",
        "\(libraryFilename)-shm",
        syncEngineStateFilename,
        "PDFs",
        "MetadataArtifacts",
        libraryFilename,
    ]

    /// Default legacy roots scanned by `migrateLegacyLibraryIfNeeded` when no
    /// explicit list is provided. Exposed `internal` for tests.
    static func defaultLegacyRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [
            // Old sandbox per-app container (before App Group adoption).
            home.appendingPathComponent("Library/Containers/com.rubien.app/Data/Library/Application Support/Rubien"),
            // Old unsandboxed path (SPM dev builds, ad-hoc signed builds).
            home.appendingPathComponent("Library/Application Support/Rubien"),
        ]
    }

    /// One-shot migration from legacy library locations to the current
    /// `preferredStorageRoot`. Idempotent: if the destination already contains
    /// `library.sqlite`, no-op. Handles every transition direction (dev →
    /// sandbox, sandbox → App Group, App Group → unsandbox after developer
    /// program drop) because the destination-exists guard short-circuits once
    /// a move has succeeded, and the source-delete step only runs after the
    /// destination is fully populated.
    ///
    /// Copy-then-delete rather than move: an interrupted migration always
    /// leaves the authoritative library at the source, so the next launch can
    /// retry without data loss. The PID-scoped `.migrating-<pid>` scratch dir
    /// is the only artifact of a partial run; `defer`-cleanup removes it.
    ///
    /// Exposed `internal` (via the injectable `legacyRoots` parameter) for
    /// tests; production call sites pass `nil` to use `defaultLegacyRoots()`.
    static func migrateLegacyLibraryIfNeeded(destination: URL, legacyRoots: [URL]? = nil) {
        let fm = FileManager.default
        let dstLibrary = destination.appendingPathComponent(libraryFilename)
        if fm.fileExists(atPath: dstLibrary.path) { return }

        let roots = legacyRoots ?? defaultLegacyRoots()

        for root in roots {
            let srcLibrary = root.appendingPathComponent(libraryFilename)
            // Don't migrate from yourself.
            if root.standardizedFileURL == destination.standardizedFileURL { continue }
            guard fm.fileExists(atPath: srcLibrary.path) else { continue }

            // PID-scoped staging so concurrent processes (e.g. app + CLI
            // launched in the same second) don't stomp each other's work.
            let staging = destination.appendingPathComponent(
                ".migrating-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            defer { try? fm.removeItem(at: staging) }
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)

                try checkpointSourceWAL(at: srcLibrary)
                try copyMigrationEntries(from: root, into: staging)

                // promoteStaging returns false if another process beat us to
                // it (destination library.sqlite already exists). In that
                // case we just bail quietly — the other process's migration
                // is authoritative.
                guard try promoteStaging(staging, to: destination) else {
                    appDatabaseLog.info("Migration race: another process completed the migration first")
                    return
                }

                verifyIntegrity(at: dstLibrary)
                deleteSourceEntries(from: root)

                appDatabaseLog.info("Migrated Rubien library from \(root.path, privacy: .public) to \(destination.path, privacy: .public)")
                return
            } catch {
                appDatabaseLog.error("Migration from \(root.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public) — source left untouched, will retry next launch")
                // Try the next legacy root.
            }
        }
    }

    private static func checkpointSourceWAL(at sqliteURL: URL) throws {
        // Open briefly, checkpoint, close. Folds any outstanding WAL content
        // back into library.sqlite so the copy below is authoritative even
        // if the old app crashed mid-write.
        let pool = try DatabasePool(path: sqliteURL.path)
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    private static func copyMigrationEntries(from source: URL, into staging: URL) throws {
        let fm = FileManager.default
        for name in migrationEntries {
            let src = source.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = staging.appendingPathComponent(name)
            try fm.copyItem(at: src, to: dst)
        }
    }

    /// Promotes staged files to their final destination. Returns `false` if
    /// another process won the race (destination `library.sqlite` already
    /// exists at promotion time, or appears between the pre-check and the
    /// final `moveItem`). Returns `true` on successful promotion.
    ///
    /// The pre-check + moveItem sequence is not atomic — two processes could
    /// both pass the pre-check and then race at the moveItem call. That's
    /// handled explicitly rather than surfaced as a generic migration error,
    /// so the log output stays clean for the common concurrent-launch case.
    private static func promoteStaging(_ staging: URL, to destination: URL) throws -> Bool {
        let fm = FileManager.default
        let finalLibrary = destination.appendingPathComponent(libraryFilename)

        // Early race check: if another process already wrote library.sqlite,
        // we lost — bail without disturbing its work.
        if fm.fileExists(atPath: finalLibrary.path) {
            return false
        }

        for name in migrationEntries {
            let staged = staging.appendingPathComponent(name)
            guard fm.fileExists(atPath: staged.path) else { continue }
            let final = destination.appendingPathComponent(name)
            // Sidecar entries (PDFs/, MetadataArtifacts/, wal/shm) may
            // already exist at the destination from a prior partial-but-
            // not-library run; clear those. library.sqlite is handled by
            // the late race check below.
            if name != libraryFilename {
                try? fm.removeItem(at: final)
            }
            do {
                try fm.moveItem(at: staged, to: final)
            } catch {
                // Late race check: if another process wrote library.sqlite
                // between the pre-check and this moveItem, treat the whole
                // promotion as a clean lost-race rather than a failure.
                if name == libraryFilename,
                   fm.fileExists(atPath: finalLibrary.path) {
                    return false
                }
                throw error
            }
        }
        return true
    }

    private static func verifyIntegrity(at sqliteURL: URL) {
        do {
            let pool = try DatabasePool(path: sqliteURL.path)
            try pool.read { db in
                let result = try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? ""
                if result != "ok" {
                    appDatabaseLog.error("Integrity check on migrated library reported: \(result, privacy: .public)")
                }
            }
        } catch {
            appDatabaseLog.error("Integrity check on migrated library failed to run: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func deleteSourceEntries(from root: URL) {
        let fm = FileManager.default
        for name in migrationEntries {
            let path = root.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) {
                do {
                    try fm.removeItem(at: path)
                } catch {
                    appDatabaseLog.info("Leftover source entry \(path.path, privacy: .public) could not be deleted: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// PDF storage directory
    public static var pdfStorageURL: URL {
        ensureDirectory(baseRoot.appendingPathComponent("PDFs", isDirectory: true), fallbackLeaf: "PDFs")
    }

    public static var metadataArtifactsURL: URL {
        ensureDirectory(baseRoot.appendingPathComponent("MetadataArtifacts", isDirectory: true), fallbackLeaf: "MetadataArtifacts")
    }

    /// Sidecar file for `CKSyncEngine.State` serialization. Lives under the
    /// same `Rubien/` directory as `library.sqlite` so all app state moves
    /// together if the user ever reassigns Application Support. Kept outside
    /// the DB so `sync reset` is a single file delete.
    public static var syncEngineStateURL: URL {
        baseRoot.appendingPathComponent(syncEngineStateFilename)
    }
}

// MARK: - Reference CRUD
extension AppDatabase {
    public func saveReference(_ reference: inout Reference) throws {
        try dbWriter.write { db in
            try normalizeForDirectLibrarySave(&reference)

            if reference.id == nil {
                try ensureLibraryReady(reference)
            }

            if reference.id == nil,
               let match = try findDuplicateReferenceID(for: reference, db: db),
               var existing = try Reference.fetchOne(db, id: match.id) {
                existing = mergedReference(existing: existing, incoming: reference)
                try existing.save(db)
                reference = existing
            } else {
                try reference.save(db)
            }
        }
    }

    public func updateReferenceWebContent(id: Int64, webContent: String?) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE reference SET webContent = ?, dateModified = ? WHERE id = ?",
                arguments: [webContent, Date(), id]
            )
        }
    }

    /// Attach the freshly-imported PDF filenames (one per row, nil when no PDF was
    /// copied) to their corresponding pdfCache + pdfUploadQueue rows. Idempotent
    /// per-row: skips rows that already carry a cache entry, so a re-import of the
    /// same Zotero folder doesn't orphan the prior PDF. Used by
    /// `ZoteroFolderImporter` after `batchImportReferences` returns the row IDs.
    func attachImportedPDFs(rowIds: [Int64], filenames: [String?]) throws {
        precondition(rowIds.count == filenames.count,
                     "attachImportedPDFs: rowIds and filenames must align 1:1")
        try dbWriter.write { db in
            for (id, filename) in zip(rowIds, filenames) {
                guard let filename else { continue }
                let alreadyCached = try Bool.fetchOne(db, sql: """
                    SELECT 1 FROM pdfCache WHERE referenceId = ? LIMIT 1
                """, arguments: [id]) ?? false
                if alreadyCached { continue }
                let now = Date()
                try db.execute(sql: """
                    INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                    VALUES(?, ?, 'pending', 1, ?, ?)
                """, arguments: [id, filename, now, now])
                try db.execute(sql: """
                    INSERT OR REPLACE INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
                    VALUES(?, ?, ?)
                """, arguments: [id, filename, now])
            }
        }
    }

    /// Resolve a Reference's local PDF filename via the cache. Returns nil
    /// if this device has never seen the asset (no `pdfCache` row) OR if the
    /// row exists but the file isn't materialized locally (caller should
    /// treat the latter as "needs download").
    ///
    /// Sync companion to `PDFAssetCache.pathFor(referenceId:)` — for places
    /// where threading async/await through is awkward (e.g., a SwiftUI view
    /// init that synchronously needs to know whether to render a "PDF" chip).
    /// Compose with `pdfStorageURL` to get the full URL, or use
    /// `PDFAssetCache.pathFor(referenceId:)` for an async lookup that also
    /// checks file existence.
    ///
    /// Note: a non-nil return only confirms the cache row is marked
    /// materialized, not that the file is currently reachable on disk. For
    /// open-the-file paths, go through `PDFAssetCache.pathFor(referenceId:)`,
    /// which also checks existence.
    public func pdfFilename(for referenceId: Int64) throws -> String? {
        try dbWriter.read { db in
            try String.fetchOne(db, sql: """
                SELECT localFilename FROM pdfCache
                WHERE referenceId = ? AND materializedAt IS NOT NULL
            """, arguments: [referenceId])
        }
    }

    /// All Reference IDs that have a cached PDF on this device. Used by the
    /// view pipeline to populate `PipelineContext.pdfAttachedRefIds` so the
    /// `.pdfAttached` filter/group/sort built-in keeps working post-B8 without
    /// `Reference.pdfPath`.
    public func pdfAttachedReferenceIDs() throws -> Set<Int64> {
        try dbWriter.read { db in
            let ids = try Int64.fetchAll(db, sql: """
                SELECT referenceId FROM pdfCache
            """)
            return Set(ids)
        }
    }

    /// Insert a pdfCache + pdfUploadQueue row for a freshly-imported PDF, but
    /// only when the row has no cache entry yet (preserves an existing PDF
    /// during merge). Caller-provided transaction so the cache write is
    /// atomic with the surrounding Reference write. Used by
    /// `persistMetadataResolution` and `confirmMetadataIntake`; the import
    /// pipeline (`ZoteroFolderImporter`) goes through the public
    /// `attachImportedPDFs` instead because it owns its own transaction.
    private func attachPDFInTransaction(
        referenceId: Int64,
        filename: String,
        db: Database
    ) throws {
        let alreadyCached = try Bool.fetchOne(db, sql: """
            SELECT 1 FROM pdfCache WHERE referenceId = ? LIMIT 1
        """, arguments: [referenceId]) ?? false
        guard !alreadyCached else { return }
        let now = Date()
        try db.execute(sql: """
            INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
            VALUES(?, ?, 'pending', 1, ?, ?)
        """, arguments: [referenceId, filename, now, now])
        try db.execute(sql: """
            INSERT OR REPLACE INTO pdfUploadQueue(referenceId, localFilename, queuedAt)
            VALUES(?, ?, ?)
        """, arguments: [referenceId, filename, now])
    }

    public func deleteReferences(ids: [Int64]) throws {
        try dbWriter.write { db in
            _ = try Reference.deleteAll(db, ids: ids)
        }
    }

    /// Collect associated PDF filenames inside the same transaction so callers can
    /// safely delete files only after the database delete succeeds. Reads
    /// `pdfCache.localFilename` (the post-B8 source of truth); the FK cascade
    /// from `reference` deletes the matching `pdfCache` row, but we capture the
    /// filename first so the caller can remove the on-disk file.
    public func deleteReferencesReturningPDFPaths(ids: [Int64]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        return try dbWriter.write { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let filenames = try String.fetchAll(
                db,
                sql: "SELECT localFilename FROM pdfCache WHERE referenceId IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            _ = try Reference.deleteAll(db, ids: ids)
            return filenames
        }
    }

    public func fetchAllReferences(limit: Int = 0) throws -> [Reference] {
        try dbWriter.read { db in
            if limit > 0 {
                return try Reference.order(Reference.Columns.dateAdded.desc).limit(limit).fetchAll(db)
            }
            return try Reference.order(Reference.Columns.dateAdded.desc).fetchAll(db)
        }
    }

    public func fetchReferences(ids: [Int64]) throws -> [Reference] {
        guard !ids.isEmpty else { return [] }
        return try dbWriter.read { db in
            try Reference
                .filter(ids.contains(Reference.Columns.id))
                .fetchAll(db)
        }
    }

    public func fetchWebContent(id: Int64) throws -> String? {
        try dbWriter.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT webContent FROM reference WHERE id = ?",
                arguments: [id]
            )
            let webContent: String? = row?["webContent"]
            return webContent
        }
    }

    public func hasWebContent(id: Int64) throws -> Bool {
        try dbWriter.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT webContent
                    FROM reference
                    WHERE id = ?
                    LIMIT 1
                    """,
                arguments: [id]
            )
            let value: String? = row?["webContent"]
            return !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    public func fetchReferences(tagId: Int64) throws -> [Reference] {
        try dbWriter.read { db in
            let request = Reference
                .joining(required: Reference.referenceTagPivot
                    .filter(ReferenceTag.Columns.tagId == tagId))
                .order(Reference.Columns.dateAdded.desc)
            return try request.fetchAll(db)
        }
    }

    /// FTS5 full-text search with prefix matching — "smi" matches "Smith"
    public func searchReferences(query: String, limit: Int = 20) throws -> [Reference] {
        return try dbWriter.read { db in
            var filter = ReferenceFilter()
            filter.keyword = query
            return try fetchReferences(db: db, scope: .all, filter: filter, limit: limit)
        }
    }

    /// Batch import — uses single transaction for maximum speed
    /// 10,000 records in ~200ms on Apple Silicon
    public func batchImportReferences(_ references: [Reference]) throws -> Int {
        try batchImportReferences(references, stamping: nil).count
    }

    /// Batch import with optional per-reference property stamping inside the same transaction.
    /// Returns the count and the row IDs of every processed entry (existing row's ID on merge,
    /// newly-inserted ID on fresh insert).
    public func batchImportReferences(
        _ references: [Reference],
        stamping target: ZoteroImportPropertyTarget?
    ) throws -> (count: Int, ids: [Int64]) {
        guard !references.isEmpty else { return (0, []) }
        return try dbWriter.write { db in
            var ids: [Int64] = []
            ids.reserveCapacity(references.count)
            for var ref in references {
                try normalizeForDirectLibrarySave(&ref)
                try ensureLibraryReady(ref)
                if let match = try findDuplicateReferenceID(for: ref, db: db),
                   var existing = try Reference.fetchOne(db, id: match.id) {
                    existing = mergedReference(existing: existing, incoming: ref)
                    try existing.save(db)
                    if let existingId = existing.id { ids.append(existingId) }
                } else {
                    try ref.insert(db)
                    if let newId = ref.id { ids.append(newId) }
                }
            }
            if let target {
                try applyPropertyValueInTransaction(
                    referenceIds: ids,
                    propertyId: target.propertyId,
                    value: target.value,
                    db: db
                )
            }
            return (ids.count, ids)
        }
    }

    public func saveMetadataIntake(_ intake: inout MetadataIntake) throws {
        try dbWriter.write { db in
            intake.updatedAt = Date()
            if intake.createdAt > intake.updatedAt {
                intake.createdAt = intake.updatedAt
            }
            try intake.save(db)
        }
    }

    public func deleteMetadataIntake(id: Int64) throws {
        try dbWriter.write { db in
            _ = try MetadataIntake.deleteOne(db, id: id)
        }
    }

    public func fetchPendingMetadataIntakes() throws -> [MetadataIntake] {
        try dbWriter.read { db in
            try MetadataIntake
                .filter(
                    [VerificationStatus.seedOnly.rawValue,
                     VerificationStatus.candidate.rawValue,
                     VerificationStatus.blocked.rawValue,
                     VerificationStatus.rejectedAmbiguous.rawValue]
                        .contains(MetadataIntake.Columns.verificationStatus)
                )
                .order(MetadataIntake.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    public func saveMetadataEvidence(_ evidence: inout MetadataEvidence) throws {
        try dbWriter.write { db in
            try evidence.save(db)
        }
    }

    public func persistMetadataResolution(
        _ result: MetadataResolutionResult,
        options: MetadataPersistenceOptions
    ) throws -> MetadataPersistenceResult {
        try dbWriter.write { db in
            switch result {
            case .verified(var envelope):
                try ensureLibraryReady(envelope.reference)
                try saveResolvedReference(
                    &envelope.reference,
                    linkedReferenceId: options.linkedReferenceId,
                    db: db
                )
                // Attach the import-time PDF (post-B8: lives in pdfCache, not
                // on Reference itself). Skipped if the row already has a cache
                // entry — preserves prior attachments on merge.
                if let preferredPDFPath = options.preferredPDFPath?.rubien_nilIfBlank,
                   let savedId = envelope.reference.id {
                    try attachPDFInTransaction(
                        referenceId: savedId,
                        filename: preferredPDFPath,
                        db: db
                    )
                }

                if let existingIntakeId = options.existingIntakeId,
                   var existingIntake = try MetadataIntake.fetchOne(db, id: existingIntakeId) {
                    existingIntake.verificationStatus = envelope.reference.verificationStatus
                    existingIntake.linkedReferenceId = envelope.reference.id
                    existingIntake.currentReferenceJSON = MetadataVerificationCodec.encodeToJSONString(envelope.reference)
                    existingIntake.evidenceBundleHash = envelope.reference.evidenceBundleHash
                    existingIntake.statusMessage = envelope.reference.verificationStatus.displayName
                    existingIntake.updatedAt = Date()
                    try existingIntake.save(db)
                }

                try upsertEvidence(bundle: envelope.evidence, intakeId: options.existingIntakeId, referenceId: envelope.reference.id, db: db)
                return .verified(envelope.reference)

            case .candidate(let envelope):
                var intake = buildMetadataIntake(
                    status: .candidate,
                    message: envelope.message,
                    seed: envelope.seed,
                    fallbackReference: envelope.fallbackReference,
                    currentReference: envelope.currentReference,
                    candidates: envelope.candidates,
                    evidence: envelope.evidence,
                    options: options
                )
                try intake.save(db)
                try upsertEvidence(bundle: envelope.evidence, intakeId: intake.id, referenceId: nil, db: db)
                return .intake(intake)

            case .blocked(let envelope):
                var intake = buildMetadataIntake(
                    status: .blocked,
                    message: envelope.message,
                    seed: envelope.seed,
                    fallbackReference: envelope.fallbackReference,
                    currentReference: envelope.currentReference,
                    candidates: envelope.candidates,
                    evidence: envelope.evidence,
                    options: options
                )
                try intake.save(db)
                try upsertEvidence(bundle: envelope.evidence, intakeId: intake.id, referenceId: nil, db: db)
                return .intake(intake)

            case .seedOnly(let envelope):
                var intake = buildMetadataIntake(
                    status: .seedOnly,
                    message: envelope.message,
                    seed: envelope.seed,
                    fallbackReference: envelope.fallbackReference,
                    currentReference: envelope.currentReference,
                    candidates: [],
                    evidence: envelope.evidence,
                    options: options
                )
                try intake.save(db)
                try upsertEvidence(bundle: envelope.evidence, intakeId: intake.id, referenceId: nil, db: db)
                return .intake(intake)

            case .rejected(let envelope):
                var intake = buildMetadataIntake(
                    status: .rejectedAmbiguous,
                    message: envelope.message,
                    seed: envelope.seed,
                    fallbackReference: envelope.fallbackReference,
                    currentReference: envelope.currentReference,
                    candidates: [],
                    evidence: envelope.evidence,
                    options: options
                )
                try intake.save(db)
                try upsertEvidence(bundle: envelope.evidence, intakeId: intake.id, referenceId: nil, db: db)
                return .intake(intake)
            }
        }
    }

    public func confirmMetadataIntake(
        _ intake: MetadataIntake,
        reviewedBy: String?
    ) throws -> Reference {
        guard var reference = intake.bestAvailableReference else {
            throw NSError(
                domain: "Rubien.MetadataIntake",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Pending intake has no metadata snapshot to confirm."]
            )
        }

        reference = MetadataVerifier.manuallyVerified(reference, reviewedBy: reviewedBy)

        try dbWriter.write { db in
            try normalizeForDirectLibrarySave(&reference)
            try ensureLibraryReady(reference)
            try saveResolvedReference(
                &reference,
                linkedReferenceId: intake.linkedReferenceId,
                db: db
            )

            // Carry forward the intake's PDF (post-B8: pdfCache). The intake
            // table still keeps its own pdfPath column — that's its handoff
            // medium during candidate review; we promote it to the cache when
            // the user confirms.
            if let pdfPath = intake.pdfPath?.rubien_nilIfBlank,
               let savedId = reference.id {
                try attachPDFInTransaction(
                    referenceId: savedId,
                    filename: pdfPath,
                    db: db
                )
            }

            if var storedIntake = try MetadataIntake.fetchOne(db, id: intake.id) {
                storedIntake.verificationStatus = .verifiedManual
                storedIntake.linkedReferenceId = reference.id
                storedIntake.currentReferenceJSON = MetadataVerificationCodec.encodeToJSONString(reference)
                storedIntake.updatedAt = Date()
                storedIntake.statusMessage = "Manually confirmed and added to library"
                try storedIntake.save(db)
            }
        }

        return reference
    }

    public func fetchReferences(
        scope: ReferenceScope,
        filter: ReferenceFilter,
        limit: Int = 0
    ) throws -> [Reference] {
        try dbWriter.read { db in
            try fetchReferences(db: db, scope: scope, filter: filter, limit: limit)
        }
    }

    public func referenceCount() throws -> Int {
        try dbWriter.read { db in
            try Reference.fetchCount(db)
        }
    }

    private func databaseQuestionMarks(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private func normalizedDOI(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    private func normalizedPMID(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    private func normalizedPMCID(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw.uppercased()
    }

    private func normalizedISBN(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: #"[^0-9Xx]"#, with: "", options: .regularExpression).uppercased()
        guard normalized.count == 10 || normalized.count == 13 else { return nil }
        return normalized
    }

    private func normalizedISSN(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: #"[^0-9Xx]"#, with: "", options: .regularExpression).uppercased()
        guard normalized.count == 8 else { return nil }
        return normalized
    }

    private func normalizeForDedup(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let folded = (raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return folded
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedTitleKey(_ value: String?) -> String? {
        guard let normalized = normalizeForDedup(value) else { return nil }
        return normalized
            .replacingOccurrences(of: #"[[:punct:]\p{P}\p{S}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeForDirectLibrarySave(_ reference: inout Reference) throws {
        guard reference.id == nil,
              !reference.verificationStatus.isLibraryReady,
              reference.metadataSource == nil else {
            return
        }

        reference = MetadataVerifier.manuallyVerified(reference, reviewedBy: "direct-save")
    }

    private func ensureLibraryReady(_ reference: Reference) throws {
        guard reference.verificationStatus.isLibraryReady else {
            throw NSError(
                domain: "Rubien.AppDatabase",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Only verifiedAuto or verifiedManual references can be written to the main library."]
            )
        }
    }

    private func buildMetadataIntake(
        status: VerificationStatus,
        message: String,
        seed: MetadataResolutionSeed?,
        fallbackReference: Reference?,
        currentReference: Reference?,
        candidates: [MetadataCandidate],
        evidence: EvidenceBundle?,
        options: MetadataPersistenceOptions
    ) -> MetadataIntake {
        let title = currentReference?.title.rubien_nilIfBlank
            ?? fallbackReference?.title.rubien_nilIfBlank
            ?? seed?.title.rubien_nilIfBlank
            ?? options.originalInput?.rubien_nilIfBlank
            ?? "Untitled pending metadata"

        return MetadataIntake(
            id: options.existingIntakeId,
            sourceKind: options.sourceKind,
            verificationStatus: status,
            title: title,
            originalInput: options.originalInput,
            sourceURL: currentReference?.verificationSourceURL
                ?? currentReference?.url
                ?? fallbackReference?.url
                ?? seed?.sourceURL,
            pdfPath: options.preferredPDFPath?.rubien_nilIfBlank,
            seedJSON: MetadataVerificationCodec.encodeToJSONString(seed),
            fallbackReferenceJSON: MetadataVerificationCodec.encodeToJSONString(fallbackReference),
            currentReferenceJSON: MetadataVerificationCodec.encodeToJSONString(currentReference),
            candidatesJSON: MetadataVerificationCodec.encodeToJSONString(candidates),
            statusMessage: message,
            linkedReferenceId: options.linkedReferenceId,
            evidenceBundleHash: evidence?.bundleHash
        )
    }

    private func saveResolvedReference(
        _ reference: inout Reference,
        linkedReferenceId: Int64?,
        db: Database
    ) throws {
        if let linkedReferenceId,
           var linkedReference = try Reference.fetchOne(db, id: linkedReferenceId) {
            linkedReference = mergedReference(existing: linkedReference, incoming: reference)
            try linkedReference.save(db)
            reference = linkedReference
            return
        }

        if reference.id == nil,
           let match = try findDuplicateReferenceID(for: reference, db: db),
           var existing = try Reference.fetchOne(db, id: match.id) {
            existing = mergedReference(existing: existing, incoming: reference)
            try existing.save(db)
            reference = existing
            return
        }

        try reference.save(db)
    }

    private func upsertEvidence(
        bundle: EvidenceBundle?,
        intakeId: Int64?,
        referenceId: Int64?,
        db: Database
    ) throws {
        guard let bundle,
              let bundleHash = bundle.bundleHash,
              let payloadJSON = MetadataVerificationCodec.encodeToJSONString(bundle) else {
            return
        }

        if var existing = try MetadataEvidence
            .filter(MetadataEvidence.Columns.bundleHash == bundleHash)
            .fetchOne(db) {
            existing.intakeId = intakeId ?? existing.intakeId
            existing.referenceId = referenceId ?? existing.referenceId
            existing.payloadJSON = payloadJSON
            try existing.save(db)
            return
        }

        var evidence = MetadataEvidence(
            intakeId: intakeId,
            referenceId: referenceId,
            bundleHash: bundleHash,
            source: bundle.source,
            recordKey: bundle.recordKey,
            sourceURL: bundle.sourceURL,
            fetchMode: bundle.fetchMode,
            payloadJSON: payloadJSON
        )
        try evidence.save(db)
    }

    /// Outcome of a single-entry duplicate lookup: the matched row's id and — because
    /// callers (classifier, merge path) immediately want to know — its current `pdfPath`.
    struct DuplicateMatch {
        let id: Int64
        let pdfPath: String?
    }

    func findDuplicateReferenceID(for reference: Reference, db: Database) throws -> DuplicateMatch? {
        // Per-strategy: SELECT the matched reference row + its cache filename
        // (via LEFT JOIN on pdfCache). Post-B8 the "does the row already have a
        // PDF" hint that callers want lives in pdfCache, not on `reference`.
        // LEFT JOIN means rows with no cache entry come back with NULL p.
        let baseSelect = "SELECT r.id AS id, c.localFilename AS p"

        if let doi = normalizedDOI(reference.doi),
           let row = try Row.fetchOne(
            db,
            sql: "\(baseSelect), r.title AS title FROM reference r LEFT JOIN pdfCache c ON c.referenceId = r.id WHERE lower(r.doi) = ? LIMIT 1",
            arguments: [doi]
           ) {
            return DuplicateMatch(id: row["id"], pdfPath: row["p"])
        }

        if let pmid = normalizedPMID(reference.pmid),
           let row = try Row.fetchOne(
            db,
            sql: "\(baseSelect), r.title AS title FROM reference r LEFT JOIN pdfCache c ON c.referenceId = r.id WHERE r.pmid = ? LIMIT 1",
            arguments: [pmid]
           ) {
            return DuplicateMatch(id: row["id"], pdfPath: row["p"])
        }

        if let pmcid = normalizedPMCID(reference.pmcid),
           let row = try Row.fetchOne(
            db,
            sql: "\(baseSelect), r.title AS title FROM reference r LEFT JOIN pdfCache c ON c.referenceId = r.id WHERE upper(r.pmcid) = ? LIMIT 1",
            arguments: [pmcid]
           ) {
            return DuplicateMatch(id: row["id"], pdfPath: row["p"])
        }

        if let isbn = normalizedISBN(reference.isbn),
           let row = try Row.fetchOne(
            db,
            sql: "\(baseSelect), r.title AS title FROM reference r LEFT JOIN pdfCache c ON c.referenceId = r.id WHERE replace(replace(upper(r.isbn), '-', ''), ' ', '') = ? LIMIT 1",
            arguments: [isbn]
           ) {
            return DuplicateMatch(id: row["id"], pdfPath: row["p"])
        }

        if let url = reference.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty,
           let row = try Row.fetchOne(
            db,
            sql: "\(baseSelect), r.title AS title FROM reference r LEFT JOIN pdfCache c ON c.referenceId = r.id WHERE r.url = ? LIMIT 1",
            arguments: [url]
           ) {
            return DuplicateMatch(id: row["id"], pdfPath: row["p"])
        }

        if let issn = normalizedISSN(reference.issn),
           let normalizedTitle = normalizedTitleKey(reference.title), !normalizedTitle.isEmpty,
           let year = reference.year {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    \(baseSelect), r.title AS title
                    FROM reference r LEFT JOIN pdfCache c ON c.referenceId = r.id
                    WHERE replace(replace(upper(r.issn), '-', ''), ' ', '') = ?
                      AND r.year = ?
                    LIMIT 20
                    """,
                arguments: [issn, year]
            )
            if let row = rows.first(where: { normalizedTitleKey(($0["title"] as String?)) == normalizedTitle }) {
                return DuplicateMatch(id: row["id"], pdfPath: row["p"])
            }
        }

        if let normalizedTitle = normalizedTitleKey(reference.title), !normalizedTitle.isEmpty,
           let year = reference.year,
           let normalizedAuthors = normalizeForDedup(reference.authorsNormalized), !normalizedAuthors.isEmpty {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    \(baseSelect), r.title AS title
                    FROM reference r LEFT JOIN pdfCache c ON c.referenceId = r.id
                    WHERE r.year = ?
                      AND lower(trim(r.authorsNormalized)) = ?
                    LIMIT 50
                    """,
                arguments: [year, normalizedAuthors]
            )
            if let row = rows.first(where: { normalizedTitleKey(($0["title"] as String?)) == normalizedTitle }) {
                return DuplicateMatch(id: row["id"], pdfPath: row["p"])
            }
        }

        return nil
    }

    /// Batched classifier for import pipelines. For each incoming reference it decides
    /// whether it duplicates an existing library row (and whether that row already has a
    /// `pdfPath`) or duplicates an earlier entry within the same batch. Runs at most one
    /// `IN (...)` query per identifier strategy (DOI, PMID, PMCID, ISBN, URL), falling
    /// back to per-entry `findDuplicateReferenceID` only for title-key strategies 6–7.
    ///
    /// Read-only and advisory; `batchImportReferences` re-runs dedup in its write
    /// transaction and remains the authoritative source of truth.
    func classifyImportEntries(_ references: [Reference]) throws -> [ImportClassification] {
        guard !references.isEmpty else { return [] }
        return try dbWriter.read { db in
            var doiKeys = Set<String>()
            var pmidKeys = Set<String>()
            var pmcidKeys = Set<String>()
            var isbnKeys = Set<String>()
            var urlKeys = Set<String>()

            for ref in references {
                if let v = normalizedDOI(ref.doi) { doiKeys.insert(v) }
                if let v = normalizedPMID(ref.pmid) { pmidKeys.insert(v) }
                if let v = normalizedPMCID(ref.pmcid) { pmcidKeys.insert(v) }
                if let v = normalizedISBN(ref.isbn) { isbnKeys.insert(v) }
                if let raw = ref.url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                    urlKeys.insert(raw)
                }
            }

            var doiMap: [String: String?] = [:]
            var pmidMap: [String: String?] = [:]
            var pmcidMap: [String: String?] = [:]
            var isbnMap: [String: String?] = [:]
            var urlMap: [String: String?] = [:]

            // The `p` column carries the cached PDF filename via LEFT JOIN on
            // pdfCache (post-B8). NULL means "row exists, no PDF cached on
            // this device" — the .dbDuplicateWithoutPDF branch below treats
            // that as "safe to copy + merge will adopt".
            try fetchIdentifierMatches(
                db: db,
                sqlTemplate: "SELECT lower(r.doi) AS k, c.localFilename AS p FROM reference r LEFT JOIN pdfCache c ON c.referenceId = r.id WHERE lower(r.doi) IN (%@)",
                keys: Array(doiKeys),
                into: &doiMap
            )
            try fetchIdentifierMatches(
                db: db,
                sqlTemplate: "SELECT r.pmid AS k, c.localFilename AS p FROM reference r LEFT JOIN pdfCache c ON c.referenceId = r.id WHERE r.pmid IN (%@)",
                keys: Array(pmidKeys),
                into: &pmidMap
            )
            try fetchIdentifierMatches(
                db: db,
                sqlTemplate: "SELECT upper(r.pmcid) AS k, c.localFilename AS p FROM reference r LEFT JOIN pdfCache c ON c.referenceId = r.id WHERE upper(r.pmcid) IN (%@)",
                keys: Array(pmcidKeys),
                into: &pmcidMap
            )
            try fetchIdentifierMatches(
                db: db,
                sqlTemplate: "SELECT replace(replace(upper(r.isbn), '-', ''), ' ', '') AS k, c.localFilename AS p FROM reference r LEFT JOIN pdfCache c ON c.referenceId = r.id WHERE replace(replace(upper(r.isbn), '-', ''), ' ', '') IN (%@)",
                keys: Array(isbnKeys),
                into: &isbnMap
            )
            try fetchIdentifierMatches(
                db: db,
                sqlTemplate: "SELECT r.url AS k, c.localFilename AS p FROM reference r LEFT JOIN pdfCache c ON c.referenceId = r.id WHERE r.url IN (%@)",
                keys: Array(urlKeys),
                into: &urlMap
            )

            // Track identifiers already claimed by earlier entries in this batch so
            // later occurrences become `.intraBatchDuplicate` (skip copy).
            var claimedDoi = Set<String>()
            var claimedPmid = Set<String>()
            var claimedPmcid = Set<String>()
            var claimedIsbn = Set<String>()
            var claimedUrl = Set<String>()

            var result: [ImportClassification] = []
            result.reserveCapacity(references.count)

            for ref in references {
                let doi = normalizedDOI(ref.doi)
                let pmid = normalizedPMID(ref.pmid)
                let pmcid = normalizedPMCID(ref.pmcid)
                let isbn = normalizedISBN(ref.isbn)
                let url: String? = {
                    let trimmed = ref.url?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (trimmed?.isEmpty == false) ? trimmed : nil
                }()

                var intraBatch = false
                if let doi, claimedDoi.contains(doi) { intraBatch = true }
                else if let pmid, claimedPmid.contains(pmid) { intraBatch = true }
                else if let pmcid, claimedPmcid.contains(pmcid) { intraBatch = true }
                else if let isbn, claimedIsbn.contains(isbn) { intraBatch = true }
                else if let url, claimedUrl.contains(url) { intraBatch = true }

                if let doi { claimedDoi.insert(doi) }
                if let pmid { claimedPmid.insert(pmid) }
                if let pmcid { claimedPmcid.insert(pmcid) }
                if let isbn { claimedIsbn.insert(isbn) }
                if let url { claimedUrl.insert(url) }

                if intraBatch {
                    result.append(.intraBatchDuplicate)
                    continue
                }

                var dbMatched = false
                var dbExistingPDF: String? = nil
                func apply(_ key: String?, in map: [String: String?]) {
                    guard !dbMatched, let key, let pdf = map[key] else { return }
                    dbMatched = true
                    dbExistingPDF = pdf
                }
                apply(doi, in: doiMap)
                apply(pmid, in: pmidMap)
                apply(pmcid, in: pmcidMap)
                apply(isbn, in: isbnMap)
                apply(url, in: urlMap)

                if dbMatched {
                    result.append(dbExistingPDF != nil ? .dbDuplicateWithPDF : .dbDuplicateWithoutPDF)
                    continue
                }

                // Strategies 1–5 didn't match. Fall back to per-entry title-key lookup
                // (strategies 6–7) — rare in practice for Zotero exports, so this
                // doesn't warrant a second batching pass.
                if let fallback = try findDuplicateReferenceID(for: ref, db: db) {
                    result.append(fallback.pdfPath != nil ? .dbDuplicateWithPDF : .dbDuplicateWithoutPDF)
                    continue
                }

                result.append(.fresh)
            }

            return result
        }
    }

    /// Chunked `IN (...)` lookup that populates `map[key] = pdfPath` for every row that
    /// matches one of the incoming identifiers. `map[key] = nil` means "matched, no PDF"
    /// (distinguishable from "not in map" via `map[key]` returning `Optional<String?>`).
    /// Chunk size 500 matches the convention used by `fetchPropertyValues(forReferences:)`.
    private func fetchIdentifierMatches(
        db: Database,
        sqlTemplate: String,
        keys: [String],
        into map: inout [String: String?]
    ) throws {
        guard !keys.isEmpty else { return }
        let chunkSize = 500
        for start in stride(from: 0, to: keys.count, by: chunkSize) {
            let slice = Array(keys[start..<min(start + chunkSize, keys.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let sql = sqlTemplate.replacingOccurrences(of: "%@", with: placeholders)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(slice))
            for row in rows {
                let key: String = row["k"]
                let pdf: String? = row["p"]
                // Prefer a match that has a pdfPath over one that doesn't, in case
                // multiple library rows somehow share the same normalized identifier.
                if let existing = map[key], existing != nil { continue }
                map[key] = pdf
            }
        }
    }

    private func mergedReference(existing: Reference, incoming: Reference) -> Reference {
        func preferred(_ incoming: String?, over existing: String?) -> String? {
            let candidate = incoming?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let candidate, !candidate.isEmpty { return candidate }
            return existing
        }

        func preferredLongest(_ incoming: String?, over existing: String?) -> String? {
            let lhs = incoming?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = existing?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (lhs?.isEmpty == false ? lhs : nil, rhs?.isEmpty == false ? rhs : nil) {
            case let (l?, r?): return l.count >= r.count ? l : r
            case let (l?, nil): return l
            case let (nil, r?): return r
            default: return nil
            }
        }

        var merged = existing
        merged.title = preferred(incoming.title, over: existing.title) ?? existing.title
        merged.authors = incoming.authors.isEmpty ? existing.authors : incoming.authors
        merged.year = incoming.year ?? existing.year
        merged.journal = preferred(incoming.journal, over: existing.journal)
        merged.volume = preferred(incoming.volume, over: existing.volume)
        merged.issue = preferred(incoming.issue, over: existing.issue)
        merged.pages = preferred(incoming.pages, over: existing.pages)
        merged.doi = preferred(incoming.doi, over: existing.doi)
        merged.url = preferred(incoming.url, over: existing.url)
        merged.abstract = preferredLongest(incoming.abstract, over: existing.abstract)
        merged.notes = preferredLongest(incoming.notes, over: existing.notes)
        merged.webContent = preferredLongest(incoming.webContent, over: existing.webContent)
        merged.siteName = preferred(incoming.siteName, over: existing.siteName)
        merged.favicon = preferred(incoming.favicon, over: existing.favicon)
        if existing.referenceType == .other || existing.referenceType == .webpage {
            merged.referenceType = incoming.referenceType
        }
        merged.metadataSource = incoming.metadataSource ?? existing.metadataSource
        merged.verificationStatus = incoming.verificationStatus.isLibraryReady ? incoming.verificationStatus : existing.verificationStatus
        merged.acceptedByRuleID = preferred(incoming.acceptedByRuleID, over: existing.acceptedByRuleID)
        merged.recordKey = preferred(incoming.recordKey, over: existing.recordKey)
        merged.verificationSourceURL = preferred(incoming.verificationSourceURL, over: existing.verificationSourceURL)
        merged.evidenceBundleHash = preferred(incoming.evidenceBundleHash, over: existing.evidenceBundleHash)
        merged.verifiedAt = incoming.verifiedAt ?? existing.verifiedAt
        merged.reviewedBy = preferred(incoming.reviewedBy, over: existing.reviewedBy)
        merged.publisher = preferred(incoming.publisher, over: existing.publisher)
        merged.publisherPlace = preferred(incoming.publisherPlace, over: existing.publisherPlace)
        merged.edition = preferred(incoming.edition, over: existing.edition)
        merged.editors = preferred(incoming.editors, over: existing.editors)
        merged.isbn = preferred(incoming.isbn, over: existing.isbn)
        merged.issn = preferred(incoming.issn, over: existing.issn)
        merged.accessedDate = preferred(incoming.accessedDate, over: existing.accessedDate)
        merged.issuedMonth = incoming.issuedMonth ?? existing.issuedMonth
        merged.issuedDay = incoming.issuedDay ?? existing.issuedDay
        merged.translators = preferred(incoming.translators, over: existing.translators)
        merged.eventTitle = preferred(incoming.eventTitle, over: existing.eventTitle)
        merged.eventPlace = preferred(incoming.eventPlace, over: existing.eventPlace)
        merged.genre = preferred(incoming.genre, over: existing.genre)
        merged.institution = preferred(incoming.institution, over: existing.institution)
        merged.number = preferred(incoming.number, over: existing.number)
        merged.collectionTitle = preferred(incoming.collectionTitle, over: existing.collectionTitle)
        merged.numberOfPages = preferred(incoming.numberOfPages, over: existing.numberOfPages)
        merged.language = preferred(incoming.language, over: existing.language)
        merged.pmid = preferred(incoming.pmid, over: existing.pmid)
        merged.pmcid = preferred(incoming.pmcid, over: existing.pmcid)
        merged.dateAdded = existing.dateAdded
        merged.dateModified = Date()
        return merged
    }
}

// MARK: - Tag CRUD
extension AppDatabase {
    public func saveTag(_ tag: inout Tag) throws {
        try dbWriter.write { db in
            try tag.save(db)
        }
    }

    public func deleteTag(id: Int64) throws {
        try dbWriter.write { db in
            _ = try Tag.deleteOne(db, id: id)
        }
    }

    public func fetchAllTags() throws -> [Tag] {
        try dbWriter.read { db in
            try Tag.order(Tag.Columns.name).fetchAll(db)
        }
    }

    public func fetchTags(forReference refId: Int64) throws -> [Tag] {
        try dbWriter.read { db in
            let request = Tag
                .joining(required: Tag.referenceTagPivot
                    .filter(ReferenceTag.Columns.referenceId == refId))
            return try request.fetchAll(db)
        }
    }

    public func setTags(forReference refId: Int64, tagIds: [Int64]) throws {
        try dbWriter.write { db in
            try ReferenceTag.filter(ReferenceTag.Columns.referenceId == refId).deleteAll(db)
            for tagId in tagIds {
                let pivot = ReferenceTag(referenceId: refId, tagId: tagId)
                try pivot.insert(db)
            }
        }
    }
}

// MARK: - DatabaseView CRUD
extension AppDatabase {
    public func saveDatabaseView(_ view: inout DatabaseView) throws {
        try dbWriter.write { db in
            view.dateModified = Date()
            try view.save(db)
        }
    }

    public func deleteDatabaseView(id: Int64) throws {
        try dbWriter.write { db in
            _ = try DatabaseView.deleteOne(db, id: id)
        }
    }

    public func fetchAllDatabaseViews() throws -> [DatabaseView] {
        try dbWriter.read { db in
            try DatabaseView.order(DatabaseView.Columns.displayOrder).fetchAll(db)
        }
    }

    public func fetchDatabaseView(id: Int64) throws -> DatabaseView? {
        try dbWriter.read { db in
            try DatabaseView.fetchOne(db, id: id)
        }
    }

    public func fetchDefaultDatabaseView() throws -> DatabaseView? {
        try dbWriter.read { db in
            try DatabaseView.filter(DatabaseView.Columns.isDefault == true).fetchOne(db)
        }
    }

    public func observeDatabaseViews() -> AnyPublisher<[DatabaseView], Error> {
        observePublisher { db in
            try DatabaseView.order(DatabaseView.Columns.displayOrder).fetchAll(db)
        }
    }
}

// MARK: - PDF Annotation CRUD
extension AppDatabase {
    public func saveAnnotation(_ annotation: inout PDFAnnotationRecord) throws {
        try dbWriter.write { db in
            try annotation.save(db)
        }
    }

    public func saveAnnotations(_ annotations: inout [PDFAnnotationRecord]) throws {
        guard !annotations.isEmpty else { return }
        try dbWriter.write { db in
            for index in annotations.indices {
                try annotations[index].save(db)
            }
        }
    }

    public func deleteAnnotation(id: Int64) throws {
        try dbWriter.write { db in
            _ = try PDFAnnotationRecord.deleteOne(db, id: id)
        }
    }

    public func fetchAnnotations(referenceId: Int64) throws -> [PDFAnnotationRecord] {
        try dbWriter.read { db in
            try PDFAnnotationRecord
                .filter(PDFAnnotationRecord.Columns.referenceId == referenceId)
                .order(PDFAnnotationRecord.Columns.pageIndex)
                .order(PDFAnnotationRecord.Columns.dateCreated)
                .fetchAll(db)
        }
    }

    public func observeAnnotations(referenceId: Int64) -> AnyPublisher<[PDFAnnotationRecord], Error> {
        observePublisher { db in
            try PDFAnnotationRecord
                .filter(PDFAnnotationRecord.Columns.referenceId == referenceId)
                .order(PDFAnnotationRecord.Columns.pageIndex)
                .order(PDFAnnotationRecord.Columns.dateCreated)
                .fetchAll(db)
        }
    }

    public func annotationCount(referenceId: Int64) throws -> Int {
        try dbWriter.read { db in
            try PDFAnnotationRecord
                .filter(PDFAnnotationRecord.Columns.referenceId == referenceId)
                .fetchCount(db)
        }
    }
}

// MARK: - Web Annotation CRUD
extension AppDatabase {
    public func saveWebAnnotation(_ annotation: inout WebAnnotationRecord) throws {
        try dbWriter.write { db in
            try annotation.save(db)
        }
    }

    public func deleteWebAnnotation(id: Int64) throws {
        try dbWriter.write { db in
            _ = try WebAnnotationRecord.deleteOne(db, id: id)
        }
    }

    public func fetchWebAnnotations(referenceId: Int64) throws -> [WebAnnotationRecord] {
        try dbWriter.read { db in
            try WebAnnotationRecord
                .filter(WebAnnotationRecord.Columns.referenceId == referenceId)
                .order(WebAnnotationRecord.Columns.dateCreated)
                .fetchAll(db)
        }
    }

    public func observeWebAnnotations(referenceId: Int64) -> AnyPublisher<[WebAnnotationRecord], Error> {
        observePublisher { db in
            try WebAnnotationRecord
                .filter(WebAnnotationRecord.Columns.referenceId == referenceId)
                .order(WebAnnotationRecord.Columns.dateCreated)
                .fetchAll(db)
        }
    }

    public func webAnnotationCount(referenceId: Int64) throws -> Int {
        try dbWriter.read { db in
            try WebAnnotationRecord
                .filter(WebAnnotationRecord.Columns.referenceId == referenceId)
                .fetchCount(db)
        }
    }
}

// MARK: - Observation with GRDBQuery

/// Describes the active sidebar filter so the database layer can build
/// the correct query without loading every row into memory first.
public enum ReferenceScope: Sendable {
    case all
    case tag(Int64)
}

/// Structured search predicates that can be pushed down to SQL.
public struct ReferenceFilter: Sendable {
    public enum KeywordOperator: String, Sendable {
        case and
        case or
    }

    public var keyword: String = ""
    public var author: String = ""
    public var yearFrom: Int? = nil
    public var yearTo: Int? = nil
    public var journal: String = ""
    public var referenceType: ReferenceType? = nil
    public var titleOnly: Bool = false
    public var hasPDF: Bool? = nil
    public var readingStatus: ReadingStatus? = nil

    /// FTS5 columns to constrain the keyword search to. Empty means "all
    /// indexed columns" (the existing default behavior). When non-empty,
    /// each token is wrapped as `(col1:"tok" OR col2:"tok" ...)`.
    /// Allowed values mirror the `referenceFts` virtual table columns: title,
    /// authorsNormalized, journal, abstract, notes, webContent, siteName,
    /// doi, publisher, isbn, issn, institution.
    public var keywordFields: [String] = []

    /// How to combine multiple tokens within the keyword query (AND across
    /// tokens — every token must match somewhere — vs OR — any token).
    /// Default `.and` matches the legacy behavior.
    public var keywordOperator: KeywordOperator = .and

    public var isEmpty: Bool {
        keyword.isEmpty && author.isEmpty && yearFrom == nil
            && yearTo == nil && journal.isEmpty && referenceType == nil
            && !titleOnly && hasPDF == nil
            && readingStatus == nil
    }

    public init() {}
}

/// Single source of truth for the `referenceFts` columns exposed to
/// `ReferenceFilter.keywordFields`. Each entry is `(public, canonical)` —
/// the public name is what callers type at the CLI/MCP boundary; the
/// canonical name is what FTS5 sees. Order is the user-facing display order.
/// Adding a new searchable column = one entry here; everything below derives.
private let referenceFTSColumns: [(public: String, canonical: String)] = [
    ("title", "title"),
    ("abstract", "abstract"),
    ("notes", "notes"),
    ("authors", "authorsNormalized"),
    ("journal", "journal"),
    ("doi", "doi"),
    ("publisher", "publisher"),
    ("isbn", "isbn"),
    ("issn", "issn"),
    ("institution", "institution"),
    ("webContent", "webContent"),
    ("siteName", "siteName")
]

private let referenceFTSColumnAllowlist: Set<String> = Set(referenceFTSColumns.map(\.canonical))

private let referenceFTSColumnAliases: [String: String] = {
    var dict: [String: String] = ["author": "authorsNormalized"]   // historical singular alias
    for (publicName, canonical) in referenceFTSColumns where publicName != canonical {
        dict[publicName] = canonical
    }
    return dict
}()

extension ReferenceFilter {
    /// Caller-facing list of accepted column names for `keywordFields`,
    /// derived from `referenceFTSColumns` (single source of truth). Surface
    /// this in CLI/MCP help text.
    public static let allowedKeywordFieldNames: [String] = referenceFTSColumns.map(\.public)

    public enum KeywordFieldValidationError: Error, CustomStringConvertible, Equatable {
        case unknownColumn(String)

        public var description: String {
            switch self {
            case .unknownColumn(let value): return "unknown-column: \(value)"
            }
        }
    }

    /// Strict validator: resolves aliases, dedupes, and **throws** on any name
    /// that's not in the allowlist. Use this at the CLI/MCP boundary so a typo
    /// like `--in titel` errors out instead of silently widening the search to
    /// all columns. Empty input returns `[]` (the "search every column"
    /// signal — explicitly meaningful, not an error).
    public static func validatedKeywordFields(_ raw: [String]) throws -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in raw {
            let trimmed = r.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let canonical = referenceFTSColumnAliases[trimmed] ?? trimmed
            guard referenceFTSColumnAllowlist.contains(canonical) else {
                throw KeywordFieldValidationError.unknownColumn(trimmed)
            }
            if seen.insert(canonical).inserted { out.append(canonical) }
        }
        return out
    }
}

/// Lenient internal sanitizer used by the FTS query builder as a defense-in-
/// depth filter. Callers at the boundary should use
/// `ReferenceFilter.validatedKeywordFields(_:)` to surface typed errors; this
/// silently drops unknowns so an internally-stamped filter never produces a
/// malformed `MATCH` expression.
fileprivate func sanitizedFTSFields(_ raw: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for r in raw {
        let trimmed = r.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let resolved = referenceFTSColumnAliases[trimmed] ?? trimmed
        guard referenceFTSColumnAllowlist.contains(resolved) else { continue }
        if seen.insert(resolved).inserted { out.append(resolved) }
    }
    return out
}

extension AppDatabase {
    /// Wraps a fetch closure in a publisher that emits on:
    /// - in-process commits (via `ValueObservation` on `dbWriter`)
    /// - cross-process change notifications (via `LibraryChangeBroadcaster`)
    ///
    /// The cross-process branch is debounced 50ms to coalesce bursts (e.g. an
    /// `import` writing many rows in one transaction notifies once, but a
    /// shell loop calling `rubien-cli` repeatedly is dampened to one re-fetch
    /// per burst window).
    fileprivate func observePublisher<T: Sendable>(
        scheduling: some ValueObservationScheduler = .immediate,
        fetch: @escaping @Sendable (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        let live = ValueObservation
            .tracking(fetch)
            .publisher(in: dbWriter, scheduling: scheduling)

        let nudged = LibraryChangeBroadcaster.shared.events
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .setFailureType(to: Error.self)
            .flatMap { [dbWriter] _ in dbWriter.readPublisher(value: fetch) }

        return live.merge(with: nudged).eraseToAnyPublisher()
    }

    public func observeReferences() -> AnyPublisher<[Reference], Error> {
        observePublisher { db in
            try Reference.order(Reference.Columns.dateAdded.desc).fetchAll(db)
        }
    }

    /// Observe references with scope + filter pushed down to SQLite.
    /// - Parameters:
    ///   - scope:  Sidebar selection (all / collection / tag).
    ///   - filter: Structured predicates (keyword FTS, author, year, journal, type).
    ///   - limit:  Maximum rows to return (0 = unlimited).
    public func observeReferences(
        scope: ReferenceScope,
        filter: ReferenceFilter,
        limit: Int = 200
    ) -> AnyPublisher<[Reference], Error> {
        // The live `ValueObservation` here uses `.async(onQueue: .main)`
        // (heavier query than the other observers — pushed off the writer
        // queue). The call site in `LibraryViewModel.rebuildReferenceObserver`
        // does not apply its own `.receive(on:)`, so we explicitly land the
        // merged stream — including the off-main `readPublisher` branch —
        // on main here.
        return observePublisher(scheduling: .async(onQueue: .main)) { [self] db in
            try self.fetchReferences(
                db: db,
                scope: scope,
                filter: filter,
                limit: limit,
                selectedColumns: Reference.lightColumns
            )
        }
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
    }

    // Internal helper used by both the publisher and direct fetch paths.
    private func fetchReferences(
        db: Database,
        scope: ReferenceScope,
        filter: ReferenceFilter,
        limit: Int,
        selectedColumns: [any SQLSelectable]? = nil
    ) throws -> [Reference] {
        let sanitizedKeywordTokens = filter.keyword
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { token in
                token
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "(", with: "")
                    .replacingOccurrences(of: ")", with: "")
            }
            .filter { !$0.isEmpty }

        // ── 1. Build base request from scope ──────────────────────────────
        var request: QueryInterfaceRequest<Reference>
        switch scope {
        case .all:
            request = Reference.all()
        case .tag(let tid):
            request = Reference
                .joining(required: Reference.referenceTagPivot
                    .filter(ReferenceTag.Columns.tagId == tid))
        }

        // ── 2. Apply SQL-level predicates ─────────────────────────────────
        if !sanitizedKeywordTokens.isEmpty {
            if filter.titleOnly {
                for token in sanitizedKeywordTokens {
                    request = request.filter(Reference.Columns.title.like("%\(token)%"))
                }
            } else {
                let ftsQuery: String
                let fields = sanitizedFTSFields(filter.keywordFields)
                let combinator = filter.keywordOperator == .or ? " OR " : " AND "
                if fields.isEmpty {
                    // Legacy default: all indexed columns, AND across tokens with prefix match.
                    // Honor `keywordOperator` if explicitly set to .or.
                    ftsQuery = sanitizedKeywordTokens.map { "\"\($0)\" *" }
                        .joined(separator: combinator)
                } else {
                    // Column-qualified: each token expanded to (f1:"tok" OR f2:"tok" ...)*,
                    // then groups joined by `combinator`.
                    ftsQuery = sanitizedKeywordTokens.map { token in
                        let perField = fields.map { "\($0):\"\(token)\" *" }.joined(separator: " OR ")
                        return "(\(perField))"
                    }.joined(separator: combinator)
                }
                request = request.filter(
                    sql: "id IN (SELECT rowid FROM referenceFts WHERE referenceFts MATCH ?)",
                    arguments: [ftsQuery]
                )
            }
        }
        if !filter.author.isEmpty {
            request = request.filter(
                Reference.Columns.authorsNormalized.like("%\(filter.author.lowercased())%")
            )
        }
        if let yf = filter.yearFrom {
            request = request.filter(Reference.Columns.year >= yf)
        }
        if let yt = filter.yearTo {
            request = request.filter(Reference.Columns.year <= yt)
        }
        if !filter.journal.isEmpty {
            request = request.filter(
                Reference.Columns.journal.like("%\(filter.journal)%")
            )
        }
        if let type = filter.referenceType {
            request = request.filter(Reference.Columns.referenceType == type.rawValue)
        }
        if let hasPDF = filter.hasPDF {
            // Post-B8: PDF presence lives on pdfCache (per-device), not on
            // Reference. EXISTS / NOT EXISTS subquery against pdfCache is the
            // straight rewrite of the prior `pdfPath IS [NOT] NULL`.
            let predicate = SQL(sql: hasPDF
                ? "EXISTS (SELECT 1 FROM pdfCache WHERE pdfCache.referenceId = reference.id)"
                : "NOT EXISTS (SELECT 1 FROM pdfCache WHERE pdfCache.referenceId = reference.id)")
            request = request.filter(literal: predicate)
        }
        if let rs = filter.readingStatus {
            request = request.filter(Reference.Columns.readingStatus == rs.rawValue)
        }

        // ── 3. Order + limit ──────────────────────────────────────────────
        request = request.order(Reference.Columns.dateAdded.desc)
        if limit > 0 {
            request = request.limit(limit)
        }

        if let selectedColumns {
            request = request.select(selectedColumns)
        }

        return try request.fetchAll(db)
    }

    public func observePendingMetadataIntakes() -> AnyPublisher<[MetadataIntake], Error> {
        observePublisher { db in
            try MetadataIntake
                .filter(
                    [VerificationStatus.seedOnly.rawValue,
                     VerificationStatus.candidate.rawValue,
                     VerificationStatus.blocked.rawValue,
                     VerificationStatus.rejectedAmbiguous.rawValue]
                        .contains(MetadataIntake.Columns.verificationStatus)
                )
                .order(MetadataIntake.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    public func observeTags() -> AnyPublisher<[Tag], Error> {
        observePublisher { db in
            try Tag.order(Tag.Columns.name).fetchAll(db)
        }
    }

    public func observeReferenceTagMappings() -> AnyPublisher<[Int64: [Tag]], Error> {
        observePublisher { db in
            try Self.loadReferenceTagMappings(db)
        }
    }

    public func fetchReferenceTagMappings() throws -> [Int64: [Tag]] {
        try dbWriter.read { db in
            try Self.loadReferenceTagMappings(db)
        }
    }

    private static func loadReferenceTagMappings(_ db: Database) throws -> [Int64: [Tag]] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT rt.referenceId, t.id, t.name, t.color
            FROM referenceTag rt
            JOIN tag t ON t.id = rt.tagId
            ORDER BY t.name
            """)
        var map: [Int64: [Tag]] = [:]
        for row in rows {
            let refId: Int64 = row["referenceId"]
            let tag = Tag(id: row["id"], name: row["name"], color: row["color"])
            map[refId, default: []].append(tag)
        }
        return map
    }
}

// MARK: - Property Definition CRUD
extension AppDatabase {
    public func fetchAllPropertyDefinitions() throws -> [PropertyDefinition] {
        try dbWriter.read { db in
            try PropertyDefinition
                .order(PropertyDefinition.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    public func fetchVisiblePropertyDefinitions() throws -> [PropertyDefinition] {
        try dbWriter.read { db in
            try PropertyDefinition
                .filter(PropertyDefinition.Columns.isVisible == true)
                .order(PropertyDefinition.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    public func savePropertyDefinition(_ prop: inout PropertyDefinition) throws {
        try dbWriter.write { db in
            try prop.save(db)
        }
    }

    public func deletePropertyDefinition(id: Int64) throws {
        try dbWriter.write { db in
            // Guard: never delete default properties
            if let prop = try PropertyDefinition.fetchOne(db, id: id), prop.isDefault {
                return
            }
            // Delete associated values first
            try PropertyValue
                .filter(PropertyValue.Columns.propertyId == id)
                .deleteAll(db)
            _ = try PropertyDefinition.deleteOne(db, id: id)
        }
    }

    public func reorderProperties(_ orderedIds: [Int64]) throws {
        try dbWriter.write { db in
            for (index, propId) in orderedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE propertyDefinition SET sortOrder = ? WHERE id = ?",
                    arguments: [index, propId]
                )
            }
        }
    }

    public func togglePropertyVisibility(id: Int64, visible: Bool) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE propertyDefinition SET isVisible = ? WHERE id = ?",
                arguments: [visible, id]
            )
        }
    }

    public func observePropertyDefinitions() -> AnyPublisher<[PropertyDefinition], Error> {
        observePublisher { db in
            try PropertyDefinition
                .order(PropertyDefinition.Columns.sortOrder)
                .fetchAll(db)
        }
    }
}

// MARK: - Property Value CRUD
extension AppDatabase {
    public func fetchPropertyValues(forReference refId: Int64) throws -> [PropertyValue] {
        try dbWriter.read { db in
            try PropertyValue
                .filter(PropertyValue.Columns.referenceId == refId)
                .fetchAll(db)
        }
    }

    public func setPropertyValue(referenceId: Int64, propertyId: Int64, value: String?) throws {
        try dbWriter.write { db in
            if let existing = try PropertyValue
                .filter(PropertyValue.Columns.referenceId == referenceId)
                .filter(PropertyValue.Columns.propertyId == propertyId)
                .fetchOne(db) {
                if let value {
                    var updated = existing
                    updated.value = value
                    try updated.update(db)
                } else {
                    _ = try existing.delete(db)
                }
            } else if let value {
                var pv = PropertyValue(referenceId: referenceId, propertyId: propertyId, value: value)
                try pv.insert(db)
            }
        }
    }

    public func fetchAllPropertyValues() throws -> [Int64: [Int64: String]] {
        try dbWriter.read { db in
            let rows = try PropertyValue.fetchAll(db)
            var map: [Int64: [Int64: String]] = [:]
            for row in rows {
                if let val = row.value {
                    map[row.referenceId, default: [:]][row.propertyId] = val
                }
            }
            return map
        }
    }

    public func fetchPropertyValues(forReferences refIds: [Int64]) throws -> [Int64: [Int64: String]] {
        guard !refIds.isEmpty else { return [:] }
        // SQLite caps host parameters at 999 on older builds (32 766 on newer). Chunk
        // the IN-list so unfiltered `list` / `export` over a large library can't
        // exceed the limit and throw mid-read.
        let chunkSize = 500
        return try dbWriter.read { db in
            var map: [Int64: [Int64: String]] = [:]
            for start in stride(from: 0, to: refIds.count, by: chunkSize) {
                let slice = Array(refIds[start..<min(start + chunkSize, refIds.count)])
                let rows = try PropertyValue
                    .filter(slice.contains(PropertyValue.Columns.referenceId))
                    .fetchAll(db)
                for row in rows {
                    if let val = row.value {
                        map[row.referenceId, default: [:]][row.propertyId] = val
                    }
                }
            }
            return map
        }
    }

    public func observeAllPropertyValues() -> AnyPublisher<[Int64: [Int64: String]], Error> {
        observePublisher { db in
            let rows = try PropertyValue.fetchAll(db)
            var map: [Int64: [Int64: String]] = [:]
            for row in rows {
                if let val = row.value {
                    map[row.referenceId, default: [:]][row.propertyId] = val
                }
            }
            return map
        }
    }
}
