import Foundation
import GRDB
import os.log

private let appDatabaseLog = Logger(subsystem: "Rubien", category: "AppDatabase")

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
                INSERT INTO databaseView (name, icon, scopeJSON, columnsJSON, filtersJSON, sortsJSON, isDefault, displayOrder, dateCreated, dateModified)
                VALUES ('All References', 'books.vertical', '{"all":{}}', ?, '[]', ?, 1, 0, datetime('now'), datetime('now'))
                """, arguments: [defaultColumnsJSON, defaultSortsJSON])

            // Custom properties
            try db.create(table: "propertyDefinition") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("type", .text).notNull().defaults(to: "string")
                t.column("optionsJSON", .text).notNull().defaults(to: "[]")
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isDefault", .boolean).notNull().defaults(to: false)
                t.column("defaultFieldKey", .text)
                t.column("isVisible", .boolean).notNull().defaults(to: true)
            }

            try db.create(table: "propertyValue") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("referenceId", .integer).notNull()
                    .references("reference", onDelete: .cascade)
                t.column("propertyId", .integer).notNull()
                    .references("propertyDefinition", onDelete: .cascade)
                t.column("value", .text)
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
        }

        return migrator
    }
}

// MARK: - Database Access
extension AppDatabase {
    public static let shared = makeShared()

    private static func preferredStorageRoot(named leaf: String) -> URL {
        let fm = FileManager.default
        let candidates: [URL] = [
            (try? fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )),
            fm.temporaryDirectory.appendingPathComponent("RubienFallback", isDirectory: true),
        ].compactMap { $0 }

        for base in candidates {
            let dirURL = base.appendingPathComponent(leaf, isDirectory: true)
            do {
                try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
                return dirURL
            } catch {
                appDatabaseLog.error("Failed to create directory at \(dirURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return fm.temporaryDirectory.appendingPathComponent(leaf, isDirectory: true)
    }

    private static func makeShared() -> AppDatabase {
        let dirURL = preferredStorageRoot(named: "Rubien")
        do {
            let dbURL = dirURL.appendingPathComponent("library.sqlite")
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

    /// PDF storage directory
    public static var pdfStorageURL: URL {
        preferredStorageRoot(named: "Rubien/PDFs")
    }

    public static var metadataArtifactsURL: URL {
        preferredStorageRoot(named: "Rubien/MetadataArtifacts")
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
               let duplicateId = try findDuplicateReferenceID(for: reference, db: db),
               var existing = try Reference.fetchOne(db, id: duplicateId) {
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

    public func deleteReferences(ids: [Int64]) throws {
        try dbWriter.write { db in
            _ = try Reference.deleteAll(db, ids: ids)
        }
    }

    /// Collect associated PDF paths inside the same transaction so callers can
    /// safely delete files only after the database delete succeeds.
    public func deleteReferencesReturningPDFPaths(ids: [Int64]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        return try dbWriter.write { db in
            let references = try Reference
                .filter(ids.contains(Reference.Columns.id))
                .fetchAll(db)
            let pdfPaths = references.compactMap(\.pdfPath)
            _ = try Reference.deleteAll(db, ids: ids)
            return pdfPaths
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
        guard !references.isEmpty else { return 0 }
        return try dbWriter.write { db in
            var count = 0
            for var ref in references {
                try normalizeForDirectLibrarySave(&ref)
                try ensureLibraryReady(ref)
                if let duplicateId = try findDuplicateReferenceID(for: ref, db: db),
                   var existing = try Reference.fetchOne(db, id: duplicateId) {
                    existing = mergedReference(existing: existing, incoming: ref)
                    try existing.save(db)
                } else {
                    try ref.insert(db)
                }
                count += 1
            }
            return count
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
                if let preferredPDFPath = options.preferredPDFPath?.rubien_nilIfBlank,
                   envelope.reference.pdfPath == nil {
                    envelope.reference.pdfPath = preferredPDFPath
                }
                try ensureLibraryReady(envelope.reference)
                try saveResolvedReference(
                    &envelope.reference,
                    linkedReferenceId: options.linkedReferenceId,
                    db: db
                )

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
                userInfo: [NSLocalizedDescriptionKey: "当前待验证条目缺少可确认的元数据快照。"]
            )
        }

        reference = MetadataVerifier.manuallyVerified(reference, reviewedBy: reviewedBy)
        if let pdfPath = intake.pdfPath?.rubien_nilIfBlank, reference.pdfPath == nil {
            reference.pdfPath = pdfPath
        }

        try dbWriter.write { db in
            try normalizeForDirectLibrarySave(&reference)
            try ensureLibraryReady(reference)
            try saveResolvedReference(
                &reference,
                linkedReferenceId: intake.linkedReferenceId,
                db: db
            )

            if var storedIntake = try MetadataIntake.fetchOne(db, id: intake.id) {
                storedIntake.verificationStatus = .verifiedManual
                storedIntake.linkedReferenceId = reference.id
                storedIntake.currentReferenceJSON = MetadataVerificationCodec.encodeToJSONString(reference)
                storedIntake.updatedAt = Date()
                storedIntake.statusMessage = "人工确认入库"
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
                userInfo: [NSLocalizedDescriptionKey: "只有 verifiedAuto 或 verifiedManual 条目可写入正式资料库。"]
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
            ?? "待验证元数据"

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
            pdfPath: options.preferredPDFPath?.rubien_nilIfBlank ?? fallbackReference?.pdfPath ?? currentReference?.pdfPath,
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
           let duplicateId = try findDuplicateReferenceID(for: reference, db: db),
           var existing = try Reference.fetchOne(db, id: duplicateId) {
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

    private func findDuplicateReferenceID(for reference: Reference, db: Database) throws -> Int64? {
        if let doi = normalizedDOI(reference.doi),
           let id = try Int64.fetchOne(db, sql: "SELECT id FROM reference WHERE lower(doi) = ? LIMIT 1", arguments: [doi]) {
            return id
        }

        if let pmid = normalizedPMID(reference.pmid),
           let id = try Int64.fetchOne(db, sql: "SELECT id FROM reference WHERE pmid = ? LIMIT 1", arguments: [pmid]) {
            return id
        }

        if let pmcid = normalizedPMCID(reference.pmcid),
           let id = try Int64.fetchOne(db, sql: "SELECT id FROM reference WHERE upper(pmcid) = ? LIMIT 1", arguments: [pmcid]) {
            return id
        }

        if let isbn = normalizedISBN(reference.isbn),
           let id = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM reference WHERE replace(replace(upper(isbn), '-', ''), ' ', '') = ? LIMIT 1",
            arguments: [isbn]
           ) {
            return id
        }

        if let url = reference.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty,
           let id = try Int64.fetchOne(db, sql: "SELECT id FROM reference WHERE url = ? LIMIT 1", arguments: [url]) {
            return id
        }

        if let issn = normalizedISSN(reference.issn),
           let normalizedTitle = normalizedTitleKey(reference.title), !normalizedTitle.isEmpty,
           let year = reference.year {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title
                    FROM reference
                    WHERE replace(replace(upper(issn), '-', ''), ' ', '') = ?
                      AND year = ?
                    LIMIT 20
                    """,
                arguments: [issn, year]
            )
            if let match = rows.first(where: { normalizedTitleKey(($0["title"] as String?)) == normalizedTitle }) {
                return match["id"]
            }
        }

        if let normalizedTitle = normalizedTitleKey(reference.title), !normalizedTitle.isEmpty,
           let year = reference.year,
           let normalizedAuthors = normalizeForDedup(reference.authorsNormalized), !normalizedAuthors.isEmpty {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title
                    FROM reference
                    WHERE year = ?
                      AND lower(trim(authorsNormalized)) = ?
                    LIMIT 50
                    """,
                arguments: [year, normalizedAuthors]
            )
            if let match = rows.first(where: { normalizedTitleKey(($0["title"] as String?)) == normalizedTitle }) {
                return match["id"]
            }
        }

        return nil
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
        merged.pdfPath = preferred(incoming.pdfPath, over: existing.pdfPath)
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
        ValueObservation
            .tracking { db in
                try DatabaseView.order(DatabaseView.Columns.displayOrder).fetchAll(db)
            }
            .publisher(in: dbWriter, scheduling: .immediate)
            .eraseToAnyPublisher()
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
        ValueObservation
            .tracking { db in
                try PDFAnnotationRecord
                    .filter(PDFAnnotationRecord.Columns.referenceId == referenceId)
                    .order(PDFAnnotationRecord.Columns.pageIndex)
                    .order(PDFAnnotationRecord.Columns.dateCreated)
                    .fetchAll(db)
            }
            .publisher(in: dbWriter, scheduling: .immediate)
            .eraseToAnyPublisher()
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
        ValueObservation
            .tracking { db in
                try WebAnnotationRecord
                    .filter(WebAnnotationRecord.Columns.referenceId == referenceId)
                    .order(WebAnnotationRecord.Columns.dateCreated)
                    .fetchAll(db)
            }
            .publisher(in: dbWriter, scheduling: .immediate)
            .eraseToAnyPublisher()
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
import Combine

/// Describes the active sidebar filter so the database layer can build
/// the correct query without loading every row into memory first.
public enum ReferenceScope: Sendable {
    case all
    case tag(Int64)
}

/// Structured search predicates that can be pushed down to SQL.
public struct ReferenceFilter: Sendable {
    public var keyword: String = ""
    public var author: String = ""
    public var yearFrom: Int? = nil
    public var yearTo: Int? = nil
    public var journal: String = ""
    public var referenceType: ReferenceType? = nil
    public var titleOnly: Bool = false
    public var hasPDF: Bool? = nil
    public var readingStatus: ReadingStatus? = nil

    public var isEmpty: Bool {
        keyword.isEmpty && author.isEmpty && yearFrom == nil
            && yearTo == nil && journal.isEmpty && referenceType == nil
            && !titleOnly && hasPDF == nil
            && readingStatus == nil
    }

    public init() {}
}

extension AppDatabase {
    public func observeReferences() -> AnyPublisher<[Reference], Error> {
        ValueObservation
            .tracking { db in
                try Reference.order(Reference.Columns.dateAdded.desc).fetchAll(db)
            }
            .publisher(in: dbWriter, scheduling: .immediate)
            .eraseToAnyPublisher()
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
        ValueObservation
            .tracking { [self] db in
                try self.fetchReferences(
                    db: db,
                    scope: scope,
                    filter: filter,
                    limit: limit,
                    selectedColumns: Reference.lightColumns
                )
            }
            .publisher(in: dbWriter, scheduling: .async(onQueue: .main))
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
                let ftsQuery = sanitizedKeywordTokens.map { "\"\($0)\" *" }.joined(separator: " AND ")
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
            request = hasPDF
                ? request.filter(Reference.Columns.pdfPath != nil)
                : request.filter(Reference.Columns.pdfPath == nil)
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
        ValueObservation
            .tracking { db in
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
            .publisher(in: dbWriter, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    public func observeTags() -> AnyPublisher<[Tag], Error> {
        ValueObservation
            .tracking { db in
                try Tag.order(Tag.Columns.name).fetchAll(db)
            }
            .publisher(in: dbWriter, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    public func observeReferenceTagMappings() -> AnyPublisher<[Int64: [Tag]], Error> {
        ValueObservation
            .tracking { db in
                try Self.loadReferenceTagMappings(db)
            }
            .publisher(in: dbWriter, scheduling: .immediate)
            .eraseToAnyPublisher()
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
        ValueObservation
            .tracking { db in
                try PropertyDefinition
                    .order(PropertyDefinition.Columns.sortOrder)
                    .fetchAll(db)
            }
            .publisher(in: dbWriter, scheduling: .immediate)
            .eraseToAnyPublisher()
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
        ValueObservation
            .tracking { db in
                let rows = try PropertyValue.fetchAll(db)
                var map: [Int64: [Int64: String]] = [:]
                for row in rows {
                    if let val = row.value {
                        map[row.referenceId, default: [:]][row.propertyId] = val
                    }
                }
                return map
            }
            .publisher(in: dbWriter, scheduling: .immediate)
            .eraseToAnyPublisher()
    }
}
