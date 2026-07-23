import ArgumentParser
import Foundation
import RubienCore
import RubienPDFKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@main
struct RubienCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rubien-cli",
        abstract: "rubien-cli — manage your Rubien reference library from the command line",
        version: RubienCLIVersion.marketing,
        subcommands: Self.allSubcommands
    )

    // #if can't appear in array literals; assemble imperatively to gate SyncCommand (RubienSync, Mac-only).
    private static let allSubcommands: [ParsableCommand.Type] = {
        var cmds: [ParsableCommand.Type] = [
            Search.self,
            List.self,
            Get.self,
            Add.self,
            Update.self,
            Delete.self,
            Cite.self,
            Read.self,
            Grep.self,
            Properties.self,
            Styles.self,
            Version.self,
            SelfUpdate.self,
            Export.self,
            Views.self,
            Pdf.self,
            Stats.self,
            StatsClear.self,
            Jobs.self,
            AssistantConversations.self,
            MCPCommand.self,
        ]
#if os(macOS)
        cmds.append(SyncCommand.self)
#endif
        return cmds
    }()
}

// MARK: - Cross-process change notification

/// Posts a Darwin notification so the running Rubien app re-fetches its
/// observation queries. Call this at the end of any subcommand branch that
/// successfully wrote to the shared library. Read-only branches must not
/// call it — extra notifications force every observer in the app to re-run.
@inline(__always)
func notifyLibraryChanged() {
    LibraryChangeBroadcaster.postChangeNotification()
}

// MARK: - JSON Output Helpers

let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    return e
}()

func printJSON<T: Encodable>(_ value: T) {
    if let data = try? jsonEncoder.encode(value), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func printJSONError(_ message: String) {
    let obj: [String: String] = ["error": message]
    if let data = try? jsonEncoder.encode(obj), let str = String(data: data, encoding: .utf8) {
        FileHandle.standardError.write(Data((str + "\n").utf8))
    }
}

/// Encode a *structured* error envelope (multiple fields beyond `error`) to
/// **stderr** (spec §4.6). Success JSON stays on stdout; structured error
/// envelopes go to stderr so the MCP wrappers — which discard stdout on
/// nonzero exit and, until the Phase-D cutover, extract only `{"error": …}`
/// from stderr — can eventually deliver the raw envelope verbatim. Single-
/// message errors keep using `printJSONError`; this is for envelopes that
/// carry extra fields (`ids`/`names`, …) that must survive intact.
func printJSONErrorEnvelope<T: Encodable>(_ envelope: T) {
    if let data = try? jsonEncoder.encode(envelope), let str = String(data: data, encoding: .utf8) {
        FileHandle.standardError.write(Data((str + "\n").utf8))
    }
}

enum AssistantCLIMutationError: Error, LocalizedError {
    case busy

    var errorDescription: String? {
        switch self {
        case .busy: "assistant-execution-busy"
        }
    }
}

/// Mutating transcript/run history can cascade local Assistant state. Acquire
/// the same non-blocking library lock as the app before entering that database
/// transaction; reads intentionally remain available while the app is running.
func acquireAssistantCLIMutationLock() throws -> AssistantLibraryExecutionLock {
    guard let lock = try AssistantLibraryExecutionLock.tryAcquire(
        libraryRoot: AppDatabase.libraryRootURL,
        ownerDescription: "rubien-cli"
    ) else {
        throw AssistantCLIMutationError.busy
    }
    return lock
}

/// A database delete commits before filesystem cleanup. Reconcile best-effort so
/// the command's JSON truthfully reports the committed mutation; any interrupted
/// cleanup is repeated at the next app launch or destructive CLI command.
func reconcileAssistantAttachmentFiles() {
    guard let stored = try? AppDatabase.shared.fetchStoredAssistantAttachmentPaths()
    else { return }
    AssistantAttachmentFiles.reconcile(
        libraryRoot: AppDatabase.libraryRootURL,
        storedPaths: stored
    )
}

/// Shared boundary for destructive Assistant history mutations: one lock,
/// one post-commit attachment sweep, and one app refresh notification.
func withAssistantCLIMutation<Result>(
    _ mutation: () throws -> Result
) throws -> Result {
    let executionLock = try acquireAssistantCLIMutationLock()
    defer { executionLock.release() }
    let result = try mutation()
    reconcileAssistantAttachmentFiles()
    notifyLibraryChanged()
    return result
}

/// The `unresolved-selectors` error envelope shared by `properties` (list
/// selectors) and `update --properties` (cell-payload keys). `ids` and
/// `names` are the unresolved selectors split by kind so callers can tell
/// a missing id from a missing name. Emitted to **stderr** (spec §4.6).
struct UnresolvedSelectorsEnvelope: Encodable {
    let error: String
    let ids: [String]
    let names: [String]

    init(ids: [String], names: [String]) {
        self.error = "unresolved-selectors"
        self.ids = ids
        self.names = names
    }
}

/// Map a `ReferenceEditError` (thrown by `AppDatabase.applyReferenceEdit`)
/// to a CLI error envelope on **stderr** (spec §4.6). The multi-field
/// `unresolved-selectors` case uses the structured envelope; every other
/// case is a single-message `{"error": …}`. Callers throw `ExitCode.failure`
/// afterwards.
func writeReferenceEditError(_ error: ReferenceEditError) {
    switch error {
    case .referenceNotFound(let id):
        printJSONError("Reference \(id) not found")
    case .invalidSelector(let key):
        printJSONError("Invalid property selector '\(key)': a digit-only key must be a valid Int64 property id")
    case .unresolvedSelectors(let keys):
        // A payload key is an id when it is non-empty all-ASCII-digits, otherwise
        // a name (§4.2). Split so the envelope mirrors the `properties` list form.
        func isIdSelector(_ s: String) -> Bool {
            !s.isEmpty && s.allSatisfy { ("0"..."9").contains($0) }
        }
        let ids = keys.filter(isIdSelector)
        let names = keys.filter { !isIdSelector($0) }
        printJSONErrorEnvelope(UnresolvedSelectorsEnvelope(ids: ids, names: names))
    case .duplicateResolution(let propertyId, let keys):
        printJSONError("Payload keys \(keys.joined(separator: ", ")) all resolve to property \(propertyId); address it with a single selector")
    case .conflict(let field, let payloadKey):
        printJSONError("Field '\(field)' and payload key '\(payloadKey)' target the same column; set it in one place")
    case .readOnlyBuiltin(let key):
        printJSONError("Property '\(key)' is a read-only built-in and cannot be set through the properties payload")
    case .nonNullableBuiltin(let key):
        printJSONError("Property '\(key)' is non-nullable and cannot be cleared")
    case .unknownField(let message):
        printJSONError(message)
    case .invalidValue(let key, let message):
        printJSONError("Property '\(key)': \(message)")
    case .invalidPayload(let key, let message):
        printJSONError(key.map { "Property '\($0)': \(message)" } ?? message)
    }
}

// MARK: - Status validation

/// Live values of the Status (`readingStatus`) PropertyDefinition. Status is
/// user-extensible post-Phase-2, so CLI validation can't be a static enum
/// list — it must reflect whatever the user has configured. Falls back to
/// the 4 seeded built-ins if the def is missing for any reason.
func liveStatusOptionValues() throws -> [String] {
    let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
    if let def = defs.first(forFieldKey: PropertyDefinition.readingStatusFieldKey) {
        return def.options.map(\.value)
    }
    return ReadingStatus.builtIn
}

// MARK: - BibTeX Helpers

/// Escape special BibTeX characters in a field value.
private func escapeBibTeX(_ value: String) -> String {
    var s = value
    s = s.replacingOccurrences(of: "\\", with: "\\textbackslash{}")
    s = s.replacingOccurrences(of: "{", with: "\\{")
    s = s.replacingOccurrences(of: "}", with: "\\}")
    s = s.replacingOccurrences(of: "&", with: "\\&")
    s = s.replacingOccurrences(of: "%", with: "\\%")
    s = s.replacingOccurrences(of: "#", with: "\\#")
    s = s.replacingOccurrences(of: "_", with: "\\_")
    s = s.replacingOccurrences(of: "~", with: "\\textasciitilde{}")
    s = s.replacingOccurrences(of: "^", with: "\\textasciicircum{}")
    return s
}

/// Generate a unique BibTeX citation key, appending a/b/c suffix for duplicates.
private func uniqueBibTeXKeys(for refs: [Reference]) -> [String] {
    var counts: [String: Int] = [:]
    var keys: [String] = []
    for ref in refs {
        let base = "\(ref.authors.first?.family ?? "unknown")\(ref.year ?? 0)"
        let count = counts[base, default: 0]
        counts[base] = count + 1
        if count == 0 {
            keys.append(base)
        } else {
            // a=1, b=2, ...
            let suffix = String(UnicodeScalar(UInt8(96 + count)))
            keys.append("\(base)\(suffix)")
        }
    }
    // If any base key had duplicates, retroactively suffix the first occurrence
    var baseSeen: [String: Int] = [:]
    for (i, ref) in refs.enumerated() {
        let base = "\(ref.authors.first?.family ?? "unknown")\(ref.year ?? 0)"
        if (counts[base] ?? 0) > 1 {
            if baseSeen[base] == nil {
                keys[i] = "\(base)a"
                baseSeen[base] = 1
            }
        }
    }
    return keys
}

// MARK: - Reference JSON DTO

struct CustomPropertyValueDTO: Encodable {
    let propertyId: Int64
    let name: String
    let type: String
    let value: String
}

struct ReferenceDTO: Encodable {
    let id: Int64?
    let title: String
    let authors: String
    let year: Int?
    let journal: String?
    let volume: String?
    let issue: String?
    let pages: String?
    let doi: String?
    let url: String?
    let siteName: String?
    let abstract: String?
    let referenceType: String
    let dateAdded: Date
    let dateModified: Date
    let pdfPath: String?
    let notes: String?
    let isbn: String?
    let issn: String?
    let publisher: String?
    let language: String?
    let edition: String?
    let readingStatus: String
    /// Most-recent reader-open timestamp. Omitted from JSON when nil (the
    /// reference has never been opened in a reader post-v4), per Swift's
    /// synthesized Encodable behavior for plain Optionals.
    let lastReadAt: Date?
    /// Distinct reading-session count (10-minute debounce on the write side).
    /// Always present in JSON; defaults to 0 for never-opened references.
    let readCount: Int
    let customProperties: [CustomPropertyValueDTO]

    init(from ref: Reference,
         defs: [PropertyDefinition] = [],
         valuesByRef: [Int64: [Int64: String]] = [:],
         pdfFilenamesByRef: [Int64: String] = [:]) {
        self.id = ref.id
        self.title = ref.title
        self.authors = ref.authors.displayString
        self.year = ref.year
        self.journal = ref.journal
        self.volume = ref.volume
        self.issue = ref.issue
        self.pages = ref.pages
        self.doi = ref.doi
        self.url = ref.url
        self.siteName = ref.siteName
        self.abstract = ref.abstract
        self.referenceType = ref.referenceType.rawValue
        self.dateAdded = ref.dateAdded
        self.dateModified = ref.dateModified
        // Post-B8: PDF lookup is per-device cache. The caller fetches all
        // filenames once and threads them in via pdfFilenamesByRef so the JSON
        // output's "pdfPath" key still exposes the on-disk filename without
        // an N+1 single-row pdfCache query per DTO.
        self.pdfPath = ref.id.flatMap { pdfFilenamesByRef[$0] }
        self.notes = ref.notes
        self.isbn = ref.isbn
        self.issn = ref.issn
        self.publisher = ref.publisher
        self.language = ref.language
        self.edition = ref.edition
        self.readingStatus = ref.readingStatus
        self.lastReadAt = ref.lastReadAt
        self.readCount = ref.readCount

        let refValues = ref.id.flatMap { valuesByRef[$0] } ?? [:]
        let customDefs = defs.filter { !$0.isDefault }
        self.customProperties = customDefs.compactMap { def -> CustomPropertyValueDTO? in
            guard let propId = def.id, let value = refValues[propId] else { return nil }
            return CustomPropertyValueDTO(
                propertyId: propId,
                name: def.name,
                type: def.type.rawValue,
                value: value
            )
        }
    }
}

/// JSON shape for a single select option exposed by the CLI / MCP.
///
/// `value` is the canonical identity (option string for custom selects;
/// stringified tag id for the built-in Tags property). `label` is the
/// display text — equal to `value` for custom options, and the Tag's name
/// for Tags-routed options. Consumers should always render `label` and
/// address mutations by `value`.
struct PropertyOptionDTO: Encodable {
    let value: String
    let label: String
    let color: String
}

struct PropertyDefinitionDTO: Encodable {
    let id: Int64
    let name: String
    let type: String
    let options: [PropertyOptionDTO]
    let sortOrder: Int
    let isDefault: Bool
    let defaultFieldKey: String?
    let isVisible: Bool

    /// Caller MUST pass the tag list when `def.isTags` (the factory helpers
    /// `makePropertyDefinitionDTO` / `makePropertyDefinitionDTOs` are the
    /// supported entry — they fetch tags). Required-arg signature prevents
    /// silently emitting an empty options array for the Tags property.
    init(from def: PropertyDefinition, tags: [Tag]) throws {
        // Every definition exposed by the CLI has already been persisted. Keep
        // the wire contract numeric; a missing rowid is an internal invariant
        // violation rather than something to encode as a magic empty string.
        guard let id = def.id else {
            throw ValidationError("Cannot encode an unpersisted property definition")
        }
        self.id = id
        self.name = def.name
        self.type = def.type.rawValue
        if def.isTags {
            self.options = tags.compactMap { tag in
                guard let id = tag.id else { return nil }
                return PropertyOptionDTO(value: String(id), label: tag.name, color: tag.color)
            }
        } else {
            self.options = def.options.map {
                PropertyOptionDTO(value: $0.value, label: $0.value, color: $0.color)
            }
        }
        self.sortOrder = def.sortOrder
        self.isDefault = def.isDefault
        self.defaultFieldKey = def.defaultFieldKey
        self.isVisible = def.isVisible
    }
}

/// Build a `PropertyDefinitionDTO` for one definition, fetching tags when
/// the definition is the built-in Tags property so its options inline.
func makePropertyDefinitionDTO(from def: PropertyDefinition) throws -> PropertyDefinitionDTO {
    let tags: [Tag] = def.isTags ? try AppDatabase.shared.fetchAllTags() : []
    return try PropertyDefinitionDTO(from: def, tags: tags)
}

/// Build DTOs for a list of definitions. Fetches tags exactly once when any
/// definition is the built-in Tags property.
func makePropertyDefinitionDTOs(from defs: [PropertyDefinition]) throws -> [PropertyDefinitionDTO] {
    let needsTags = defs.contains { $0.isTags }
    let tags: [Tag] = needsTags ? try AppDatabase.shared.fetchAllTags() : []
    return try defs.map { try PropertyDefinitionDTO(from: $0, tags: tags) }
}

struct CitationBibliographyOutput: Encodable {
    let style: String
    let entries: [String]
}

struct CitationDocxCCOutput: Encodable {
    let tag: String
    let text: String
    let style: String
    let isShortTag: Bool?
    let fallbackPayload: String?
}

struct CitationTextOutput: Encodable {
    let style: String
    let inline: String
    let bibliography: [String]
}

// MARK: - PDF download

/// Stable JSON string for the `action` field across both PDF-download
/// outputs. Used by `pdf download <id>` and the resolver route's PDF fetch
/// (`add --source <identifier|paper URL>`, unless explicitly opted out).
enum PDFDownloadAction: String, Encodable {
    case downloaded
    case replaced
    case alreadyAttached = "already-attached"
    case alreadyPending = "already-pending"
    case skipped
}

struct PDFDownloadStatusDTO: Encodable {
    let ok: Bool
    let action: PDFDownloadAction?
    let filename: String?
    let error: String?
}

/// Download via `PDFDownloadService`, attach via `attachImportedPDFs`,
/// and clean up the on-disk file if the attach throws. Returns the local
/// filename on success. Callers handle verification-after-attach and
/// the success notifications. When `pdfURLOverride` is provided, the
/// download service uses it directly and skips arXiv/OpenAlex resolution.
private func downloadAndAttachPDF(
    for ref: Reference,
    refId: Int64,
    pdfURLOverride: String? = nil
) async throws -> String {
    let filename = try await PDFDownloadService.downloadPDF(for: ref, overrideURL: pdfURLOverride)
    do {
        try AppDatabase.shared.attachImportedPDFs(rowIds: [refId], filenames: [filename])
    } catch {
        try? FileManager.default.removeItem(
            at: AppDatabase.pdfStorageURL.appendingPathComponent(filename))
        throw error
    }
    return filename
}

/// Best-effort PDF download for the resolver route. The reference is already
/// saved by the caller, so all error paths must
/// soft-fail into the DTO so the command still exits 0. When
/// `pdfURLOverride` is provided (e.g. from `citation_pdf_url` on a
/// paper-landing-page scrape), the download path uses it directly —
/// supporting papers that have no DOI / arXiv identifier (OpenReview,
/// CVF, PMLR) but do expose a publisher PDF URL.
func attemptPDFDownload(
    for ref: Reference,
    pdfURLOverride: String? = nil
) async -> PDFDownloadStatusDTO {
    guard let refId = ref.id else {
        return PDFDownloadStatusDTO(ok: false, action: nil, filename: nil,
                                    error: "Reference has no id")
    }
    let existing: AppDatabase.PDFCacheStatus?
    do {
        existing = try AppDatabase.shared.pdfCacheStatus(for: refId)
    } catch {
        return PDFDownloadStatusDTO(ok: false, action: nil, filename: nil,
                                    error: "Failed to read PDF cache state: \(error.localizedDescription)")
    }
    if let existing {
        let materialized = existing.materializedAt != nil
        return PDFDownloadStatusDTO(
            ok: true,
            action: materialized ? .alreadyAttached : .alreadyPending,
            filename: materialized ? existing.localFilename : nil,
            error: nil)
    }
    let hasOverride = pdfURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    guard ref.canDownloadPDF || hasOverride else {
        return PDFDownloadStatusDTO(ok: false, action: .skipped, filename: nil,
                                    error: "No DOI or arXiv identifier available")
    }
    let filename: String
    do {
        filename = try await downloadAndAttachPDF(for: ref, refId: refId, pdfURLOverride: pdfURLOverride)
    } catch let err as PDFDownloadService.DownloadError {
        return PDFDownloadStatusDTO(ok: false, action: nil, filename: nil,
                                    error: err.localizedDescription)
    } catch {
        return PDFDownloadStatusDTO(ok: false, action: nil, filename: nil,
                                    error: "Failed to attach PDF: \(error.localizedDescription)")
    }
    // Verify-after-attach: `attachImportedPDFs` silently no-ops on an
    // existing `pdfCache` row, so a concurrent writer can leave our
    // file orphaned. On a verify-read failure, do NOT delete the file —
    // state is ambiguous; preserve the filename in the soft-fail DTO.
    let post: String?
    do {
        post = try AppDatabase.shared.pdfFilename(for: refId)
    } catch {
        return PDFDownloadStatusDTO(
            ok: false, action: .downloaded, filename: filename,
            error: "Attached PDF but verification read failed; library may need reconciliation: \(error.localizedDescription)")
    }
    if post != filename {
        try? FileManager.default.removeItem(
            at: AppDatabase.pdfStorageURL.appendingPathComponent(filename))
        return PDFDownloadStatusDTO(
            ok: true,
            action: post != nil ? .alreadyAttached : .alreadyPending,
            filename: post, error: nil)
    }
    notifyLibraryChanged()
    PDFUploadQueueBroadcaster.postChangeNotification()
    return PDFDownloadStatusDTO(ok: true, action: .downloaded,
                                filename: filename, error: nil)
}

// MARK: - Reference DTO helpers

/// Map a batch of references to DTOs, fetching property defs + values scoped
/// to the returned references so a paged read doesn't scan the whole table.
/// Bulk-fetches PDF filenames in a single query so each DTO doesn't issue
/// its own pdfCache lookup (N+1 → 1+1).
func mapReferenceDTOs(_ refs: [Reference]) throws -> [ReferenceDTO] {
    guard !refs.isEmpty else { return [] }
    let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
    let refIds = refs.compactMap(\.id)
    let valuesByRef = try AppDatabase.shared.fetchPropertyValues(forReferences: refIds)
    let pdfFilenamesByRef = try AppDatabase.shared.pdfFilenames(forReferences: refIds)
    return refs.map {
        ReferenceDTO(
            from: $0,
            defs: defs,
            valuesByRef: valuesByRef,
            pdfFilenamesByRef: pdfFilenamesByRef
        )
    }
}

/// Build a DTO for a single reference, fetching just that reference's values.
func referenceDTO(for ref: Reference) throws -> ReferenceDTO {
    let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
    let valuesByRef: [Int64: [Int64: String]]
    if let rid = ref.id {
        let values = try AppDatabase.shared.fetchPropertyValues(forReference: rid)
        var map: [Int64: String] = [:]
        for v in values {
            if let val = v.value { map[v.propertyId] = val }
        }
        valuesByRef = [rid: map]
    } else {
        valuesByRef = [:]
    }
    var pdfFilenamesByRef: [Int64: String] = [:]
    if let rid = ref.id, let filename = try AppDatabase.shared.pdfFilename(for: rid) {
        pdfFilenamesByRef[rid] = filename
    }
    return ReferenceDTO(
        from: ref,
        defs: defs,
        valuesByRef: valuesByRef,
        pdfFilenamesByRef: pdfFilenamesByRef
    )
}

/// Execute a saved view's query (scope + filters + sorts + groupBy) and return
/// the matching references, honoring `limit` (0 = all) and `offset`. Backs
/// `list --view <id>` (a reference array), routing through the same query
/// engine as an inline `list`.
func querySavedView(_ view: DatabaseView, limit: Int, offset rawOffset: Int = 0) throws -> [Reference] {
    // Clamp a negative offset to 0 so the fast path's `limit + offset` can't go
    // nonpositive (which would fetch-all) — both paths then treat it as no offset.
    let offset = max(0, rawOffset)
    let db = AppDatabase.shared
    let scope: ReferenceScope
    switch view.parsedScope {
    case .all: scope = .all
    case .tag(let id): scope = .tag(id)
    }
    // Fast path: no filters/sorts/groupBy → push (limit+offset) to SQL, then drop
    // the leading `offset` — a bare `limit` fetch followed by `dropFirst(offset)`
    // would return the first page and then empty it (e.g. --limit 20 --offset 20).
    if view.parsedFilters.isEmpty && view.parsedSorts.isEmpty && view.parsedGroupBy == nil {
        let fetchLimit: Int
        if limit > 0 {
            let (sum, overflow) = limit.addingReportingOverflow(offset)
            fetchLimit = overflow ? 0 : sum   // 0 == fetch all (overflow is absurd input)
        } else {
            fetchLimit = 0
        }
        let rows = try db.fetchReferences(scope: scope, filter: ReferenceFilter(), limit: fetchLimit)
        return offset > 0 ? Array(rows.dropFirst(offset)) : rows
    }
    let refs = try db.fetchReferences(scope: scope, filter: ReferenceFilter(), limit: 0)
    let context = PipelineContext(
        tagMap: try db.fetchReferenceTagMappings(),
        propertyValueMap: try db.fetchAllPropertyValues(),
        propertyDefs: try db.fetchAllPropertyDefinitions(),
        pdfAttachedRefIds: try db.pdfAttachedReferenceIDs()
    )
    let filtered = FilterEngine.apply(refs, filters: view.parsedFilters, context: context)
    let sorted = SortEngine.apply(filtered, sorts: view.parsedSorts, context: context)
    let paged = offset > 0 ? Array(sorted.dropFirst(offset)) : sorted
    return limit > 0 ? Array(paged.prefix(limit)) : paged
}

// MARK: - Subcommands

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Full-text search across the library")

    @Argument(help: "Search query")
    var query: String

    @Option(name: .shortAndLong, help: "Maximum number of results")
    var limit: Int = 20

    @Option(
        name: .customLong("in"),
        help: "Restrict FTS to columns (comma-separated). Allowed: title, abstract, notes, authors, journal, doi, publisher, isbn, issn, institution, webContent, siteName."
    )
    var inFields: String?

    @Option(
        name: .customLong("op"),
        help: "Combine multiple query tokens with 'and' (every token must match) or 'or' (any token). Default: and."
    )
    var op: String?

    func run() throws {
        var filter = ReferenceFilter()
        filter.keyword = query
        if let inFields, !inFields.isEmpty {
            let raw = inFields
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            do {
                filter.keywordFields = try ReferenceFilter.validatedKeywordFields(raw)
            } catch ReferenceFilter.KeywordFieldValidationError.unknownColumn(let bad) {
                let allowed = ReferenceFilter.allowedKeywordFieldNames.joined(separator: ", ")
                printJSONError("Unknown --in column '\(bad)'. Allowed: \(allowed)")
                throw ExitCode.failure
            }
        }
        if let op {
            guard let parsed = ReferenceFilter.KeywordOperator(rawValue: op.lowercased()) else {
                printJSONError("Unknown --op '\(op)'. Valid: and, or")
                throw ExitCode.failure
            }
            filter.keywordOperator = parsed
        }
        let refs = try AppDatabase.shared.fetchReferences(scope: .all, filter: filter, limit: limit, orderBy: .relevance)
        printJSON(try mapReferenceDTOs(refs))
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List references")

    @Option(name: .shortAndLong, help: "Maximum number of results (0 = all)")
    var limit: Int = 0

    @Option(name: .long, help: "Skip the first N results (pagination)")
    var offset: Int = 0

    @Option(name: .long, help: "Filter by tag ID")
    var tag: Int64?

    @Option(name: .long, help: "Filter by author name (fuzzy match)")
    var author: String?

    @Option(name: .long, help: "Filter by year (lower bound)")
    var yearFrom: Int?

    @Option(name: .long, help: "Filter by year (upper bound)")
    var yearTo: Int?

    @Option(name: .long, help: "Filter by journal name (fuzzy match)")
    var journal: String?

    @Option(name: .customLong("type"), help: "Filter by reference type (e.g. 'Journal Article')")
    var referenceType: String?

    @Flag(name: .customLong("has-pdf"), help: "Only show references with a PDF attachment")
    var hasPdf = false

    @Option(name: .long, help: "Keyword search across title, abstract, and notes")
    var keyword: String?

    @Option(name: .customLong("reading-status"), help: "Filter by reading status (Unread, Reading, Skimmed, Read — or any user-added Status option)")
    var readingStatus: String?

    @Option(name: .customLong("sort-by"), help: "Sort by field (year, dateAdded, title)")
    var sortBy: String?

    @Flag(name: .long, help: "Sort ascending (default is descending)")
    var asc = false

    @Option(name: .long, help: "List references matching a saved view's query (by view id). Mutually exclusive with inline filters/sorts; --limit and --offset still apply.")
    var view: Int64?

    func run() throws {
        // Saved-view rows (spec §3): route through the same query engine as an
        // inline list, mutually exclusive with inline filters/sorts.
        if let viewId = view {
            let hasInlineFilter = tag != nil || author != nil || yearFrom != nil || yearTo != nil
                || journal != nil || referenceType != nil || hasPdf || keyword != nil
                || readingStatus != nil || sortBy != nil || asc
            if hasInlineFilter {
                printJSONError("--view is mutually exclusive with inline filters/sorts (tag, author, year-from/to, journal, type, has-pdf, keyword, reading-status, sort-by, asc)")
                throw ExitCode.failure
            }
            guard let savedView = try AppDatabase.shared.fetchDatabaseView(id: viewId) else {
                printJSONError("View \(viewId) not found")
                throw ExitCode.failure
            }
            // Pagination is offset-aware inside the query (fetch limit+offset, drop
            // offset) so `--limit N --offset N` returns the next page, not nothing.
            let refs = try querySavedView(savedView, limit: limit, offset: offset)
            printJSON(try mapReferenceDTOs(refs))
            return
        }
        let hasAdvancedFilter = author != nil || yearFrom != nil || yearTo != nil
            || journal != nil || referenceType != nil || hasPdf || keyword != nil
            || readingStatus != nil
        var refs: [Reference]
        if hasAdvancedFilter {
            let scope: ReferenceScope = tag.map { .tag($0) } ?? .all
            var filter = ReferenceFilter()
            if let a = author { filter.author = a }
            if let yf = yearFrom { filter.yearFrom = yf }
            if let yt = yearTo { filter.yearTo = yt }
            if let j = journal { filter.journal = j }
            if let k = keyword { filter.keyword = k }
            if hasPdf { filter.hasPDF = true }
            if let rs = readingStatus {
                // Status is user-extensible: validate against the live Status
                // PropertyDefinition options instead of a fixed enum.
                let liveOptions = try liveStatusOptionValues()
                guard liveOptions.contains(rs) else {
                    let valid = liveOptions.joined(separator: ", ")
                    printJSONError("Unknown reading status '\(rs)'. Valid: \(valid)")
                    throw ExitCode.failure
                }
                filter.readingStatus = rs
            }
            if let rt = referenceType {
                guard let type = ReferenceType(rawValue: rt) else {
                    let valid = ReferenceType.allCases.map(\.rawValue).joined(separator: ", ")
                    printJSONError("Unknown reference type '\(rt)'. Valid: \(valid)")
                    throw ExitCode.failure
                }
                filter.referenceType = type
            }
            refs = try AppDatabase.shared.fetchReferences(scope: scope, filter: filter, limit: limit)
        } else if let tid = tag {
            refs = try AppDatabase.shared.fetchReferences(tagId: tid)
        } else {
            refs = try AppDatabase.shared.fetchAllReferences(limit: limit)
        }
        if offset > 0 {
            refs = Array(refs.dropFirst(offset))
        }
        printJSON(try mapReferenceDTOs(refs))
    }
}

struct Get: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Fetch a single reference by ID")

    @Argument(help: "Reference ID")
    var id: Int64

    func run() throws {
        let refs = try AppDatabase.shared.fetchReferences(ids: [id])
        guard let ref = refs.first else {
            printJSONError("Reference \(id) not found")
            throw ExitCode.failure
        }
        printJSON(try referenceDTO(for: ref))
    }
}

struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Add a reference from any locator (identifier, URL, file, folder, BibTeX, or title)")

    @Option(name: .long, help: "Inline BibTeX source (can hold multiple entries)")
    var bibtex: String?

    @Option(name: .long, help: "Title (for manual entry)")
    var title: String?

    @Option(name: .long, help: "One locator, routed automatically: identifier (DOI/arXiv/PMID/PMCID/ISBN), paper URL, PDF/Markdown file URL, local file path, folder path, or '-' for stdin (spec §5). Returns the unified create-reference envelope.")
    var source: String?

    @Option(name: .long, help: "Format hint for a file or stdin source: bib, ris, md")
    var format: String?

    @Option(name: .long, help: "Folder source: property to stamp on every reference (default: Tags)")
    var property: String?

    @Option(name: .long, help: "Folder source: value to stamp on the property (default: folder basename)")
    var value: String?

    // Tri-state (`--download-pdf` / `--no-download-pdf` / absent, spec §5.1):
    // resolver routes default to downloading, so "explicitly false" must remain
    // representable. Bare `--download-pdf` stays valid.
    @Flag(inversion: .prefixedNo,
          help: "Fetch the open-access PDF after resolving an identifier / paper URL (default). Use --no-download-pdf to opt out.")
    var downloadPdf: Bool?

    func run() async throws {
        // One door (spec §5): exactly one input. `--source` is the locator
        // (identifiers route through it since `--identifier` was removed);
        // `--bibtex` / `--title` carry inline content a locator can't express.
        // Every path emits the unified create-reference envelope (§5.4).
        if [source, bibtex, title].compactMap({ $0 }).count > 1 {
            printJSONError("--source / --bibtex / --title cannot be combined; provide exactly one input")
            throw ExitCode.failure
        }
        if let src = source {
            try await CreateReferenceSource.run(
                source: src,
                downloadPdf: downloadPdf,
                format: format,
                property: property,
                value: value
            )
            return
        }
        // The route-scoped flags apply only to `--source` routes (§5.1:
        // inapplicable options are rejected, not silently ignored).
        if downloadPdf != nil || format != nil || property != nil || value != nil {
            printJSONError("--download-pdf / --no-download-pdf / --format / --property / --value require --source")
            throw ExitCode.failure
        }
        if let bib = bibtex {
            try CreateReferenceSource.runInlineBibTeX(bib)
        } else if let t = title {
            try CreateReferenceSource.runTitle(t)
        } else {
            printJSONError("Provide --source, --bibtex, or --title")
            throw ExitCode.failure
        }
    }
}

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Update fields on an existing reference")

    @Argument(help: "Reference ID")
    var id: Int64

    @Option(name: .long, help: "Title")
    var title: String?

    @Option(name: .long, help: "Publication year")
    var year: Int?

    @Option(name: .long, help: "Authors (semicolon-separated; format: 'Last, First; Last, First')")
    var authors: String?

    @Option(name: .customLong("type"), help: "Reference type (e.g. 'Journal Article', 'Book')")
    var referenceType: String?

    @Option(name: .long, help: "Journal name")
    var journal: String?

    @Option(name: .long, help: "Volume")
    var volume: String?

    @Option(name: .long, help: "Issue")
    var issue: String?

    @Option(name: .long, help: "Pages (e.g. '100-110')")
    var pages: String?

    @Option(name: .long, help: "DOI")
    var doi: String?

    @Option(name: .long, help: "URL")
    var url: String?

    @Option(name: .long, help: "Abstract")
    var abstract: String?

    @Option(name: .long, help: "Notes")
    var notes: String?

    @Option(name: .long, help: "Publisher")
    var publisher: String?

    @Option(name: .long, help: "ISBN")
    var isbn: String?

    @Option(name: .long, help: "ISSN")
    var issn: String?

    @Option(name: .long, help: "Language")
    var language: String?

    @Option(name: .long, help: "Edition")
    var edition: String?

    @Option(name: .customLong("clear-field"), help: "Clear a single field (repeatable, e.g. --clear-field doi)")
    var clearFields: [String] = []

    @Option(name: .customLong("reading-status"), help: "Set reading status (Unread, Reading, Skimmed, Read — or any user-added Status option)")
    var readingStatus: String?

    @Option(name: .long, help: "Cell payload as a JSON object of property selectors → values (built-in and custom). Keys are property ids (digits) or exact names; values replace (scalar / full multiSelect array), {\"add\":[…],\"remove\":[…]} (multiSelect), or null (clear). Applied atomically with the field flags above.")
    var properties: String?

    func run() throws {
        // Unified cell-edit path (spec §4). When `--properties` is present,
        // ALL field flags + clears + the decoded payload apply atomically via
        // the single-transaction `applyReferenceEdit`. Without it, the legacy
        // flag-by-flag path below is preserved unchanged (additive: old form
        // keeps working, output shape identical).
        if let propertiesJSON = properties {
            try runUnifiedEdit(propertiesJSON: propertiesJSON)
            return
        }
        let refs = try AppDatabase.shared.fetchReferences(ids: [id])
        guard var ref = refs.first else {
            printJSONError("Reference \(id) not found")
            throw ExitCode.failure
        }
        if let t = title { ref.title = t }
        if let y = year { ref.year = y }
        if let a = authors { ref.authors = AuthorName.parseList(a) }
        if let rs = readingStatus {
            // Status is user-extensible: validate against the live Status
            // PropertyDefinition options instead of a fixed enum.
            let liveOptions = try liveStatusOptionValues()
            guard liveOptions.contains(rs) else {
                let valid = liveOptions.joined(separator: ", ")
                printJSONError("Unknown reading status '\(rs)'. Valid: \(valid)")
                throw ExitCode.failure
            }
            ref.readingStatus = rs
        }
        if let rt = referenceType {
            guard let type = ReferenceType(rawValue: rt) else {
                let valid = ReferenceType.allCases.map(\.rawValue).joined(separator: ", ")
                printJSONError("Unknown reference type '\(rt)'. Valid: \(valid)")
                throw ExitCode.failure
            }
            ref.referenceType = type
        }
        if let j = journal { ref.journal = j }
        if let v = volume { ref.volume = v }
        if let i = issue { ref.issue = i }
        if let p = pages { ref.pages = p }
        if let d = doi { ref.doi = d }
        if let u = url { ref.url = u }
        if let ab = abstract { ref.abstract = ab }
        if let n = notes { ref.notes = n }
        if let pub = publisher { ref.publisher = pub }
        if let i = isbn { ref.isbn = i }
        if let i = issn { ref.issn = i }
        if let l = language { ref.language = l }
        if let e = edition { ref.edition = e }
        for field in clearFields {
            switch field.lowercased() {
            case "year": ref.year = nil
            case "journal": ref.journal = nil
            case "volume": ref.volume = nil
            case "issue": ref.issue = nil
            case "pages": ref.pages = nil
            case "doi": ref.doi = nil
            case "url": ref.url = nil
            case "abstract": ref.abstract = nil
            case "notes": ref.notes = nil
            case "publisher": ref.publisher = nil
            case "isbn": ref.isbn = nil
            case "issn": ref.issn = nil
            case "language": ref.language = nil
            case "edition": ref.edition = nil
            default:
                printJSONError("Unknown field '\(field)'. Valid: year, journal, volume, issue, pages, doi, url, abstract, notes, publisher, isbn, issn, language, edition")
                throw ExitCode.failure
            }
        }
        try AppDatabase.shared.saveReference(&ref)
        notifyLibraryChanged()
        printJSON(try referenceDTO(for: ref))
    }

    /// Atomic cell-edit path: decode the payload, fold every field flag +
    /// clear-field into a `ReferenceEdit`, and apply it in one transaction
    /// (spec §4.2–§4.5). Structured errors go to stderr (spec §4.6).
    private func runUnifiedEdit(propertiesJSON: String) throws {
        let decoded: [String: PropertyEntry]
        do {
            decoded = try ReferenceEdit.decodeProperties(fromJSON: propertiesJSON)
        } catch let error as ReferenceEditError {
            writeReferenceEditError(error)
            throw ExitCode.failure
        }
        let edit = ReferenceEdit(
            title: title,
            year: year,
            authors: authors,
            referenceType: referenceType,
            readingStatus: readingStatus,
            journal: journal,
            volume: volume,
            issue: issue,
            pages: pages,
            doi: doi,
            url: url,
            abstract: abstract,
            notes: notes,
            publisher: publisher,
            isbn: isbn,
            issn: issn,
            language: language,
            edition: edition,
            clearFields: clearFields,
            properties: decoded
        )
        let updated: Reference
        let didChange: Bool
        do {
            (updated, didChange) = try AppDatabase.shared.applyReferenceEditReportingChange(id: id, edit: edit)
        } catch let error as ReferenceEditError {
            writeReferenceEditError(error)
            throw ExitCode.failure
        }
        // A no-op edit (empty `--properties {}` payload, or every value already
        // equal) writes nothing — skip the notification so it triggers no
        // dirty-queue / sync churn (spec §4.5). Output is unchanged.
        if didChange { notifyLibraryChanged() }
        printJSON(try referenceDTO(for: updated))
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete references by ID")

    @Argument(help: "Reference IDs to delete")
    var ids: [Int64] = []

    @Flag(name: .shortAndLong, help: "Skip the confirmation prompt")
    var force = false

    func run() throws {
        if !ids.isEmpty {
            if !force && isatty(STDIN_FILENO) != 0 {
                FileHandle.standardError.write(Data("Delete \(ids.count) reference(s) and associated PDFs? [y/N] ".utf8))
                guard let line = readLine(), line.lowercased().hasPrefix("y") else {
                    printJSONError("Aborted")
                    throw ExitCode.failure
                }
            }
            let pdfPaths = try AppDatabase.shared.deleteReferencesReturningPDFPaths(ids: ids)
            for path in pdfPaths { PDFService.deletePDF(at: path) }
            notifyLibraryChanged()
            printJSON(["deleted": ids.map(String.init).joined(separator: ",")])
        } else {
            printJSONError("Provide reference IDs as arguments")
            throw ExitCode.failure
        }
    }
}

struct Cite: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate a formatted citation")

    @Argument(help: "Reference IDs")
    var ids: [Int64]

    @Option(name: .shortAndLong, help: "Citation style (apa, mla, chicago, ieee, harvard, vancouver, nature)")
    var style: String = "apa"

    @Option(name: .long, help: "Output format: text, bibliography, docx-cc")
    var format: String = "text"

    func run() throws {
        // Validate citation style
        let validIds = Set(CSLManager.shared.availableStyles().map(\.id))
        guard validIds.contains(style) else {
            let available = validIds.sorted().joined(separator: ", ")
            printJSONError("Unknown citation style '\(style)'. Available: \(available)")
            throw ExitCode.failure
        }

        let refs = try AppDatabase.shared.fetchReferences(ids: ids)
        guard !refs.isEmpty else {
            printJSONError("No references found for given IDs")
            throw ExitCode.failure
        }

        switch format {
        case "bibliography":
            let entries = refs.map { CSLManager.shared.formatBibliography($0, style: style) }
            printJSON(CitationBibliographyOutput(style: style, entries: entries))
        case "docx-cc":
            let uuid = UUID().uuidString.lowercased()
            let idList = refs.compactMap(\.id).map(String.init).joined(separator: ",")
            let encodedStyle = style.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? style
            let fullTag = "rubien:v3:cite:\(uuid):\(encodedStyle):\(idList)"
            // Word rejects content-control tags longer than ~220 characters.
            // When the full tag exceeds this limit, emit a short tag (UUID only)
            // and include a fallbackPayload field so callers can set
            // cc.placeholderText = fallbackPayload when writing the DOCX.
            let maxTagLength = 220
            let isShortTag = fullTag.count > maxTagLength
            let tag = isShortTag ? "rubien:v3:cite:\(uuid)" : fullTag
            let inlineText = CSLManager.shared.formatCitation(refs, style: style)
            printJSON(
                CitationDocxCCOutput(
                    tag: tag,
                    text: inlineText,
                    style: style,
                    isShortTag: isShortTag ? true : nil,
                    fallbackPayload: isShortTag ? "rubien:v3:payload:\(encodedStyle):\(idList)" : nil
                )
            )
        default:
            let inline = CSLManager.shared.formatCitation(refs, style: style)
            let entries = refs.map { CSLManager.shared.formatBibliography($0, style: style) }
            printJSON(CitationTextOutput(style: style, inline: inline, bibliography: entries))
        }
    }
}

struct Properties: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "properties",
        abstract: "List or manage property definitions and options; list per-reference values (write them via `rubien-cli update --properties`). Covers tags via the built-in 'Tags' property."
    )

    @Flag(name: .long, help: "Only visible property definitions (with list). Ignored when --id / --name is supplied — explicit selectors always win.")
    var visible = false

    @Flag(name: .long, help: "Create a new property definition")
    var create = false

    @Option(name: .long, parsing: .singleValue, help: "Property name. With --create / --update: target name (single value required). With list: repeatable filter selector (exact, case-sensitive). Errors with `unresolved-selectors` when any name doesn't match.")
    var name: [String] = []

    @Option(name: .long, help: "Property type (with --create): string, url, number, singleSelect, multiSelect, date, checkbox")
    var type: String?

    @Option(name: .long, help: "Comma-separated option values for singleSelect/multiSelect (with --create), auto-colored")
    var options: String?

    @Option(name: .long, help: "Delete a property definition by ID (rejected for built-in defaults)")
    var delete: Int64?

    @Flag(name: .long, help: "Combined property update: rename and/or change visibility in one transaction (requires --id and at least one of --name / --set-visible)")
    var update = false

    @Option(name: .customLong("set-visible"), help: "Set visibility with --update (true or false). Distinct from the --visible list filter.")
    var setVisible: Bool?

    @Flag(name: .customLong("add-option"), help: "Append a select option (or, for the Tags property, create a new tag) (requires --id, --value, optional --color)")
    var addOption = false

    @Flag(name: .customLong("update-option"), help: "Combined option update: rename and/or recolor in one transaction (requires --id and --option, at least one of --to / --color). For Tags, --option is the stringified tag id.")
    var updateOption = false

    @Option(name: .customLong("option"), help: "Existing option value to update (with --update-option). For Tags, the stringified tag id.")
    var optionValue: String?

    @Flag(name: .customLong("delete-option"), help: "Remove a select option (requires --id, --value). For Tags, --value is the stringified tag id. If the option is in use, supply --replace-with to migrate affected rows or --clear-in-use to clear it from them.")
    var deleteOption = false

    @Option(name: .long, parsing: .singleValue, help: "Property definition ID. With operations: single target. With list: repeatable filter selector. Errors with `unresolved-selectors` when any id doesn't exist.")
    var id: [Int64] = []

    @Option(name: .long, help: "Option value (with --add-option / --delete-option).")
    var value: String?

    @Option(name: .long, help: "Option color as hex (with --add-option, auto-assigned if omitted)")
    var color: String?

    @Option(name: .customLong("to"), help: "New option value (with --update-option). For Tags, the new display name.")
    var toValue: String?

    @Option(name: .customLong("replace-with"), help: "Replacement option for in-use values when deleting (with --delete-option). For Tags, the stringified id of another tag.")
    var replaceWith: String?

    @Flag(name: .customLong("clear-in-use"), help: "When deleting an in-use option (with --delete-option), clear it from affected references instead of refusing. Mutually exclusive with --replace-with.")
    var clearOptionInUse = false

    @Option(name: .long, help: "Reference ID — list that reference's property values (write them via `rubien-cli update --properties`)")
    var reference: Int64?

    func run() throws {
        if let deleteId = delete {
            let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
            guard let target = defs.first(where: { $0.id == deleteId }) else {
                printJSONError("Property \(deleteId) not found")
                throw ExitCode.failure
            }
            if target.isDefault {
                printJSONError("Cannot delete built-in property '\(target.name)'")
                throw ExitCode.failure
            }
            try AppDatabase.shared.deletePropertyDefinition(id: deleteId)
            notifyLibraryChanged()
            printJSON(["deleted": "\(deleteId)"])
            return
        }

        if create {
            guard let n = try singleName(flag: "--create") else {
                printJSONError("--create requires --name")
                throw ExitCode.failure
            }
            guard let typeStr = type, let ptype = PropertyType(rawValue: typeStr) else {
                printJSONError("--create requires --type (one of: string, url, number, singleSelect, multiSelect, date, checkbox)")
                throw ExitCode.failure
            }
            let parsedOptions = parseOptions(options)
            if !parsedOptions.isEmpty, ptype != .singleSelect && ptype != .multiSelect {
                printJSONError("--options only applies to singleSelect or multiSelect types")
                throw ExitCode.failure
            }
            do {
                let prop = try AppDatabase.shared.createPropertyDefinition(
                    name: n,
                    type: ptype,
                    options: parsedOptions
                )
                notifyLibraryChanged()
                printJSON(try makePropertyDefinitionDTO(from: prop))
            } catch let error as PropertyMutationError {
                printJSONError(describePropertyMutationError(error))
                throw ExitCode.failure
            }
            return
        }

        if update {
            guard let propId = try singleId(flag: "--update") else {
                printJSONError("--update requires --id")
                throw ExitCode.failure
            }
            let newName = try singleName(flag: "--update")
            guard newName != nil || setVisible != nil else {
                printJSONError("--update requires --name and/or --set-visible")
                throw ExitCode.failure
            }
            do {
                let (updated, didChange) = try AppDatabase.shared.updatePropertyDefinitionReportingChange(
                    id: propId, name: newName, visible: setVisible
                )
                // No-op update (name/visible already equal) writes nothing — skip
                // the notification (spec §4.5). Output is unchanged.
                if didChange { notifyLibraryChanged() }
                printJSON(try makePropertyDefinitionDTO(from: updated))
            } catch let error as PropertyMutationError {
                printJSONError(describePropertyMutationError(error))
                throw ExitCode.failure
            }
            return
        }

        if addOption {
            guard let propId = try singleId(flag: "--add-option"), let v = value else {
                printJSONError("--add-option requires --id and --value")
                throw ExitCode.failure
            }
            let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
            guard let prop = defs.first(where: { $0.id == propId }) else {
                printJSONError("Property \(propId) not found")
                throw ExitCode.failure
            }
            if prop.isDefault, !Self.optionsMutable(for: prop) {
                printJSONError(typeFixedHintMessage(propertyName: prop.name))
                throw ExitCode.failure
            }
            guard prop.type == .singleSelect || prop.type == .multiSelect else {
                printJSONError("--add-option only applies to singleSelect or multiSelect types")
                throw ExitCode.failure
            }
            do {
                _ = try AppDatabase.shared.addPropertyOption(propertyId: propId, value: v, color: color)
            } catch let error as PropertyOptionError {
                printJSONError(describePropertyOptionError(error))
                throw ExitCode.failure
            }
            notifyLibraryChanged()
            // Re-fetch so the DTO reflects the post-mutation state (Tags
            // routes through saveTag, not optionsJSON, so we need a fresh
            // PropertyDefinition + tag list to render the new option inline).
            let updated = try AppDatabase.shared.fetchPropertyDefinition(id: propId)!
            printJSON(try makePropertyDefinitionDTO(from: updated))
            return
        }

        if updateOption {
            guard let propId = try singleId(flag: "--update-option"), let opt = optionValue else {
                printJSONError("--update-option requires --id and --option")
                throw ExitCode.failure
            }
            guard toValue != nil || color != nil else {
                printJSONError("--update-option requires --to and/or --color")
                throw ExitCode.failure
            }
            do {
                let (updated, didChange) = try AppDatabase.shared.updatePropertyOptionReportingChange(
                    propertyId: propId, option: opt, newName: toValue, color: color
                )
                // No-op update (name/color already equal) writes nothing — skip
                // the notification (spec §4.5). Output is unchanged.
                if didChange { notifyLibraryChanged() }
                printJSON(try makePropertyDefinitionDTO(from: updated))
            } catch let error as PropertyMutationError {
                printJSONError(describePropertyMutationError(error))
                throw ExitCode.failure
            } catch let error as PropertyOptionError {
                printJSONError(describePropertyOptionError(error))
                throw ExitCode.failure
            }
            return
        }

        if deleteOption {
            guard let propId = try singleId(flag: "--delete-option"), let v = value else {
                printJSONError("--delete-option requires --id and --value")
                throw ExitCode.failure
            }
            let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
            guard let prop = defs.first(where: { $0.id == propId }) else {
                printJSONError("Property \(propId) not found")
                throw ExitCode.failure
            }
            if prop.isDefault, !Self.optionsMutable(for: prop) {
                printJSONError(typeFixedHintMessage(propertyName: prop.name))
                throw ExitCode.failure
            }
            do {
                try AppDatabase.shared.deletePropertyOption(
                    propertyId: propId,
                    value: v,
                    replaceWith: replaceWith,
                    clearInUse: clearOptionInUse
                )
            } catch let error as PropertyOptionError {
                printJSONError(describePropertyOptionError(error))
                throw ExitCode.failure
            }
            notifyLibraryChanged()
            let updated = try AppDatabase.shared.fetchPropertyDefinition(id: propId)!
            printJSON(try makePropertyDefinitionDTO(from: updated))
            return
        }

        if let refId = reference {
            // List values set on this reference. Tags-routed values are
            // injected by fetchPropertyValues so they appear here too.
            let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
            let defsById: [Int64: PropertyDefinition] = Dictionary(
                uniqueKeysWithValues: defs.compactMap { def in def.id.map { ($0, def) } }
            )
            let values = try AppDatabase.shared.fetchPropertyValues(forReference: refId)
            let dtos: [CustomPropertyValueDTO] = values.compactMap { v in
                guard let val = v.value, let def = defsById[v.propertyId] else { return nil }
                return CustomPropertyValueDTO(
                    propertyId: v.propertyId,
                    name: def.name,
                    type: def.type.rawValue,
                    value: val
                )
            }
            printJSON(dtos)
            return
        }

        // Default: list definitions, optionally filtered.
        try runList()
    }

    private func runList() throws {
        let allDefs = try AppDatabase.shared.fetchAllPropertyDefinitions()
        let defsById = Dictionary(uniqueKeysWithValues: allDefs.compactMap { def in
            def.id.map { ($0, def) }
        })
        let defsByName = Dictionary(uniqueKeysWithValues: allDefs.map { ($0.name, $0) })

        let hasSelectors = !id.isEmpty || !name.isEmpty
        if hasSelectors {
            // Fail-loud: silent partial results would be a footgun in scripts.
            let unresolvedIds = id.filter { defsById[$0] == nil }
            let unresolvedNames = name.filter { defsByName[$0] == nil }
            if !unresolvedIds.isEmpty || !unresolvedNames.isEmpty {
                // Structured envelope → stderr (spec §4.6); stdout stays reserved
                // for success JSON so the MCP wrappers can pass it through raw.
                printJSONErrorEnvelope(UnresolvedSelectorsEnvelope(
                    ids: unresolvedIds.map(String.init),
                    names: unresolvedNames
                ))
                throw ExitCode.failure
            }
            // Explicit selectors override `--visible` filtering — the caller
            // asked for these by name, so don't silently drop hidden ones.
            var picked: [Int64: PropertyDefinition] = [:]
            for i in id {
                if let def = defsById[i], let did = def.id { picked[did] = def }
            }
            for n in name {
                if let def = defsByName[n], let did = def.id { picked[did] = def }
            }
            // Preserve sortOrder so output matches the un-filtered ordering.
            let result = picked.values.sorted { $0.sortOrder < $1.sortOrder }
            printJSON(try makePropertyDefinitionDTOs(from: Array(result)))
            return
        }

        let defs = visible
            ? try AppDatabase.shared.fetchVisiblePropertyDefinitions()
            : allDefs
        printJSON(try makePropertyDefinitionDTOs(from: defs))
    }

    private func singleId(flag: String) throws -> Int64? {
        if id.count > 1 {
            printJSONError("\(flag) accepts a single --id (multiple --id selectors only apply to the list operation)")
            throw ExitCode.failure
        }
        return id.first
    }

    private func singleName(flag: String) throws -> String? {
        if name.count > 1 {
            printJSONError("\(flag) accepts a single --name (multiple --name selectors only apply to the list operation)")
            throw ExitCode.failure
        }
        return name.first
    }

    /// Defaults whose options users may edit. Status is option-extensible
    /// (post-Phase-2); Tags is option-extensible because tag CRUD now flows
    /// through this surface; Type stays locked (drives BibTeX/RIS buckets).
    private static func optionsMutable(for prop: PropertyDefinition) -> Bool {
        prop.defaultFieldKey == PropertyDefinition.readingStatusFieldKey || prop.isTags
    }

    /// Error message shown when a user tries to add/rename/delete options on
    /// a built-in property whose options are intentionally fixed (currently
    /// only Type). Points at the right tools for organizational categorization.
    private func typeFixedHintMessage(propertyName: String) -> String {
        "'\(propertyName)' is a fixed built-in property because it drives BibTeX/RIS export buckets. For organization, use the Tags property ('rubien-cli properties --add-option --id <Tags id> --value <name>') or create a custom singleSelect property ('rubien-cli properties --create')."
    }

    /// Map a `PropertyMutationError` (combined property/option updates) to a
    /// user-visible CLI error string.
    private func describePropertyMutationError(_ error: PropertyMutationError) -> String {
        switch error {
        case .propertyNotFound:
            return "Property not found"
        case .builtInRenameForbidden(let name):
            return "Cannot rename built-in property '\(name)'"
        case .allDigitName(let name):
            return "Property name '\(name)' cannot be all digits — it would shadow an id selector in the properties payload."
        case .immutableBuiltInOptions(let name):
            return typeFixedHintMessage(propertyName: name)
        case .invalidColor(let color):
            return "Invalid color '\(color)'. Use #RRGGBB."
        case .nothingToUpdate:
            return "Nothing to update (supply a changed value)."
        }
    }

    /// Map a `PropertyOptionError` to a user-visible CLI error string.
    private func describePropertyOptionError(_ error: PropertyOptionError) -> String {
        switch error {
        case .propertyNotFound:
            return "Property not found"
        case .optionNotFound:
            return "Option not found in this property"
        case .optionInUse(let count):
            return "Cannot delete: \(count) reference\(count == 1 ? "" : "s") still use this option. Pass --replace-with <existing-value> to migrate them, or --clear-in-use to clear it from them."
        case .replacementNotFound(let name):
            return "Replacement option '\(name)' is not an existing option on this property."
        case .duplicateValue(let name):
            return "An option with value '\(name)' already exists on this property — pick a different rename target."
        case .unsupportedPropertyType:
            return "Option rename / delete only applies to select properties (singleSelect, multiSelect, and the built-in Tags property)."
        case .conflictingDisposition:
            return "Pass either --replace-with or --clear-in-use, not both."
        }
    }

    private func parseOptions(_ raw: String?) -> [SelectOption] {
        guard let raw, !raw.isEmpty else { return [] }
        let values = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var options: [SelectOption] = []
        var used: Set<String> = []
        for v in values {
            let color = ColorPalette.nextUnused(excluding: used)
            used.insert(color)
            options.append(SelectOption(value: v, color: color))
        }
        return options
    }
}

// MARK: - Activity statistics

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Report tracked reading and Rubien Assistant activity as JSON."
    )

    @Option(name: .long, help: "Gregorian activity year (1970...9999). Defaults to the current local year.")
    var year: Int?

    mutating func validate() throws {
        if let year, !(1970 ... 9999).contains(year) {
            throw ValidationError("--year must be between 1970 and 9999")
        }
    }

    func run() throws {
        let statistics = try AppDatabase.shared.fetchReadingActivityStatistics(year: year)
        printJSON(statistics)
    }
}

struct StatsClear: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats-clear",
        abstract: "Clear one tracked activity category using a synced reset boundary."
    )

    @Option(name: .long, help: "Activity category: reading or assistant.")
    var kind: String

    @Flag(name: .long, help: "Confirm the destructive clear.")
    var yes = false

    mutating func validate() throws {
        guard ActivityKind(rawValue: kind) != nil else {
            throw ValidationError("--kind must be 'reading' or 'assistant'")
        }
        guard yes else {
            throw ValidationError("stats-clear requires --yes")
        }
    }

    func run() throws {
        let activityKind = ActivityKind(rawValue: kind)!
        try AppDatabase.shared.clearActivity(kind: activityKind)
        notifyLibraryChanged()
        printJSON(["cleared": activityKind.rawValue])
    }
}

// MARK: - Scheduled Jobs

struct ScheduledJobDTO: Encodable {
    let id: String
    let name: String
    let prompt: String
    let weekdayMask: Int
    let weekdays: [String]
    let localTime: String
    let enabled: Bool
    let provider: String
    let model: String?
    let effort: String?
    let webAccess: Bool
    let notifyOnCompletion: Bool
    let nextRunAt: Date?
    let createdAt: Date
    let dateModified: Date

    init(_ job: ScheduledJob) {
        id = job.id
        name = job.name
        prompt = job.prompt
        weekdayMask = job.weekdayMask
        weekdays = ScheduledWeekday.allCases
            .filter { job.recurrence.contains($0) }
            .map(scheduledWeekdayName)
        localTime = String(format: "%02d:%02d", job.localMinuteOfDay / 60, job.localMinuteOfDay % 60)
        enabled = job.isEnabled
        provider = job.provider.rawValue
        model = job.model
        effort = job.effort
        webAccess = job.webAccess
        notifyOnCompletion = job.notifyOnCompletion
        nextRunAt = job.nextRunAt
        createdAt = job.createdAt
        dateModified = job.dateModified
    }
}

struct ScheduledJobRunDTO: Encodable {
    let id: String
    let jobId: String
    let trigger: String
    let occurrenceKey: String
    let scheduledFor: Date
    let startedAt: Date?
    let finishedAt: Date?
    let status: String
    let provider: String
    let providerSessionId: String?
    let failureKind: String?
    let unread: Bool
    let assistantTranscriptState: String
    let assistantTranscriptStatusCode: String?

    init(_ run: ScheduledJobRun) {
        id = run.id
        jobId = run.jobId
        trigger = run.trigger.rawValue
        occurrenceKey = run.occurrenceKey
        scheduledFor = run.scheduledFor
        startedAt = run.startedAt
        finishedAt = run.finishedAt
        status = run.status.rawValue
        provider = run.provider.rawValue
        providerSessionId = run.providerSessionId
        failureKind = run.failureKind?.rawValue
        unread = run.isUnread
        assistantTranscriptState = run.assistantTranscriptState.rawValue
        assistantTranscriptStatusCode = run.assistantTranscriptStatusCode?.rawValue
    }
}

struct AssistantConversations: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assistant-conversations",
        abstract: "Read and manage Rubien-owned Assistant transcripts",
        subcommands: [
            AssistantConversationsList.self,
            AssistantConversationsGet.self,
            AssistantConversationsDelete.self,
            AssistantConversationsClear.self,
        ],
        defaultSubcommand: AssistantConversationsList.self
    )
}

struct AssistantConversationsList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List locally saved Assistant conversations"
    )

    @Option(help: "Provider: claude or codex") var provider: String?
    @Option(name: .customLong("reference-id"), help: "Limit results to one reference")
    var referenceId: Int64?
    @Option(help: "Search locally indexed visible transcript text") var search: String?
    @Option(help: "Maximum rows") var limit = 50

    func run() throws {
        guard limit > 0 else {
            printJSONError("--limit must be greater than zero")
            throw ExitCode.failure
        }
        let parsedProvider: AssistantProvider?
        if let provider {
            do {
                parsedProvider = try parseScheduledProvider(provider)
            } catch {
                printJSONError("Invalid provider '\(provider)'. Use claude or codex.")
                throw ExitCode.failure
            }
        } else {
            parsedProvider = nil
        }
        printJSON(try AppDatabase.shared.fetchAssistantConversationSummaries(
            query: .init(
                provider: parsedProvider,
                referenceId: referenceId,
                search: search,
                limit: limit
            )
        ))
    }
}

struct AssistantConversationsGet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a locally saved Assistant transcript"
    )

    @Argument(help: "Assistant conversation ID") var id: String
    @Option(help: "Maximum transcript entries")
    var limit = AssistantConversationDetail.defaultPageLimit
    @Option(help: "Opaque olderCursor from the previous page")
    var cursor: String?

    func run() throws {
        guard (1...AssistantConversationDetail.maximumPageLimit).contains(limit) else {
            printJSONError(
                "--limit must be between 1 and "
                    + "\(AssistantConversationDetail.maximumPageLimit)"
            )
            throw ExitCode.failure
        }
        let parsedCursor: AssistantTranscriptCursor?
        if let cursor {
            guard let value = AssistantTranscriptCursor(token: cursor) else {
                printJSONError("--cursor is not a valid Assistant transcript cursor")
                throw ExitCode.failure
            }
            parsedCursor = value
        } else {
            parsedCursor = nil
        }
        if let parsedCursor, parsedCursor.conversationID != id {
            printJSONError(
                "--cursor belongs to a different Assistant conversation"
            )
            throw ExitCode.failure
        }
        guard let detail = try AppDatabase.shared.fetchAssistantConversationDetail(
            id: id,
            before: parsedCursor,
            limit: limit
        ) else {
            printJSONError("Assistant conversation \(id) not found")
            throw ExitCode.failure
        }
        printJSON(detail)
    }
}

struct AssistantConversationsDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete one local Assistant transcript"
    )

    @Argument(help: "Assistant conversation ID") var id: String

    func run() throws {
        do {
            try withAssistantCLIMutation {
                try AppDatabase.shared.deleteAssistantConversation(id: id)
            }
            printJSON(["deleted": id])
        } catch {
            printJSONError(assistantConversationCLIErrorMessage(error))
            throw ExitCode.failure
        }
    }
}

struct AssistantConversationsClear: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Delete local Assistant transcripts"
    )

    @Option(help: "Delete conversations older than this ISO-8601 timestamp")
    var before: String?
    @Flag(help: "Confirm destructive deletion") var confirm = false

    func run() throws {
        guard confirm else {
            printJSONError("--confirm is required")
            throw ExitCode.failure
        }
        let cutoff: Date?
        if let before {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            cutoff = formatter.date(from: before) ?? ISO8601DateFormatter().date(from: before)
            guard cutoff != nil else {
                printJSONError("--before must be an ISO-8601 timestamp")
                throw ExitCode.failure
            }
        } else {
            cutoff = nil
        }
        do {
            let count = try withAssistantCLIMutation {
                try AppDatabase.shared.clearAssistantConversations(before: cutoff)
            }
            printJSON(["cleared": count])
        } catch {
            printJSONError(assistantConversationCLIErrorMessage(error))
            throw ExitCode.failure
        }
    }
}

private func assistantConversationCLIErrorMessage(_ error: Error) -> String {
    if let error = error as? AssistantConversationError {
        return error.errorDescription ?? "Assistant conversation operation failed"
    }
    return error.localizedDescription
}

struct Jobs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jobs",
        abstract: "Manage local scheduled Rubien Assistant jobs",
        subcommands: [
            JobsList.self,
            JobsGet.self,
            JobsCreate.self,
            JobsUpdate.self,
            JobsDelete.self,
            JobsEnable.self,
            JobsRuns.self,
            JobsDeleteRun.self,
        ],
        defaultSubcommand: JobsList.self
    )
}

struct JobsList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List scheduled jobs")

    func run() throws {
        printJSON(try AppDatabase.shared.fetchScheduledJobs().map(ScheduledJobDTO.init))
    }
}

struct JobsGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get one scheduled job")

    @Argument(help: "Scheduled job ID") var id: String

    func run() throws {
        guard let job = try AppDatabase.shared.fetchScheduledJob(id: id) else {
            printJSONError("Scheduled job \(id) not found")
            throw ExitCode.failure
        }
        printJSON(ScheduledJobDTO(job))
    }
}

struct JobsCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a scheduled job")

    @Option(help: "Display name") var name: String
    @Option(help: "Assistant prompt") var prompt: String
    @Option(help: "Comma-separated weekdays (mon..sun), daily, weekdays, or weekends") var weekdays: String
    @Option(help: "Local wall-clock time in HH:mm") var time: String
    @Option(help: "Provider: claude or codex") var provider: String = "claude"
    @Option(help: "Provider model override") var model: String?
    @Option(help: "Provider effort override") var effort: String?
    @Flag(name: .customLong("paused"), help: "Create the job paused") var paused = false
    @Flag(name: .customLong("no-web-access"), help: "Disable provider web access") var noWebAccess = false
    @Flag(name: .customLong("no-notify"), help: "Disable completion notifications") var noNotify = false

    func run() throws {
        do {
            let job = try AppDatabase.shared.createScheduledJob(
                .init(
                    name: name,
                    prompt: prompt,
                    recurrence: .init(
                        weekdayMask: try parseScheduledWeekdayMask(weekdays),
                        localMinuteOfDay: try parseScheduledLocalTime(time)
                    ),
                    isEnabled: !paused,
                    provider: try parseScheduledProvider(provider),
                    model: model,
                    effort: effort,
                    webAccess: !noWebAccess,
                    notifyOnCompletion: !noNotify
                )
            )
            notifyLibraryChanged()
            printJSON(ScheduledJobDTO(job))
        } catch {
            printJSONError(scheduledJobCLIErrorMessage(error))
            throw ExitCode.failure
        }
    }
}

struct JobsUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a scheduled job")

    @Argument(help: "Scheduled job ID") var id: String
    @Option(help: "Display name") var name: String?
    @Option(help: "Assistant prompt") var prompt: String?
    @Option(help: "Comma-separated weekdays (mon..sun), daily, weekdays, or weekends") var weekdays: String?
    @Option(help: "Local wall-clock time in HH:mm") var time: String?
    @Option(help: "Provider: claude or codex") var provider: String?
    @Option(help: "Provider model override; pass an empty string to clear") var model: String?
    @Option(help: "Provider effort override; pass an empty string to clear") var effort: String?
    @Option(help: "Whether the job is enabled: true or false") var enabled: Bool?
    @Option(name: .customLong("web-access"), help: "Whether provider web access is enabled: true or false") var webAccess: Bool?
    @Option(name: .customLong("notify-on-completion"), help: "Whether completion notifications are enabled: true or false") var notifyOnCompletion: Bool?

    func run() throws {
        do {
            guard let existing = try AppDatabase.shared.fetchScheduledJob(id: id) else {
                throw ScheduledJobError.notFound
            }
            let recurrence = ScheduledRecurrence(
                weekdayMask: try weekdays.map(parseScheduledWeekdayMask) ?? existing.weekdayMask,
                localMinuteOfDay: try time.map(parseScheduledLocalTime) ?? existing.localMinuteOfDay
            )
            let job = try AppDatabase.shared.updateScheduledJob(
                id: id,
                definition: .init(
                    name: name ?? existing.name,
                    prompt: prompt ?? existing.prompt,
                    recurrence: recurrence,
                    isEnabled: enabled ?? existing.isEnabled,
                    provider: try provider.map(parseScheduledProvider) ?? existing.provider,
                    model: model ?? existing.model,
                    effort: effort ?? existing.effort,
                    webAccess: webAccess ?? existing.webAccess,
                    notifyOnCompletion: notifyOnCompletion ?? existing.notifyOnCompletion
                )
            )
            notifyLibraryChanged()
            printJSON(ScheduledJobDTO(job))
        } catch {
            printJSONError(scheduledJobCLIErrorMessage(error))
            throw ExitCode.failure
        }
    }
}

struct JobsDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a scheduled job and its run history")

    @Argument(help: "Scheduled job ID") var id: String

    func run() throws {
        do {
            try withAssistantCLIMutation {
                try AppDatabase.shared.deleteScheduledJob(id: id)
            }
            printJSON(["deleted": id])
        } catch {
            printJSONError(scheduledJobCLIErrorMessage(error))
            throw ExitCode.failure
        }
    }
}

struct JobsEnable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable or pause a scheduled job")

    @Argument(help: "Scheduled job ID") var id: String
    @Option(help: "true to enable, false to pause") var enabled: Bool

    func run() throws {
        do {
            let job = try AppDatabase.shared.setScheduledJobEnabled(id: id, isEnabled: enabled)
            notifyLibraryChanged()
            printJSON(ScheduledJobDTO(job))
        } catch {
            printJSONError(scheduledJobCLIErrorMessage(error))
            throw ExitCode.failure
        }
    }
}

struct JobsRuns: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "runs", abstract: "List scheduled job run history")

    @Option(name: .customLong("job-id"), help: "Limit history to one scheduled job") var jobId: String?
    @Option(help: "Maximum rows") var limit = 50

    func run() throws {
        guard limit > 0 else {
            printJSONError("--limit must be greater than zero")
            throw ExitCode.failure
        }
        let runs = try jobId.map { try AppDatabase.shared.fetchScheduledJobRuns(jobId: $0, limit: limit) }
            ?? AppDatabase.shared.fetchRecentScheduledJobRuns(limit: limit)
        printJSON(runs.map(ScheduledJobRunDTO.init))
    }
}

struct JobsDeleteRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-run",
        abstract: "Remove one terminal run from visible history"
    )

    @Argument(help: "Scheduled job run ID") var id: String

    func run() throws {
        do {
            try withAssistantCLIMutation {
                try AppDatabase.shared.deleteScheduledJobRun(id: id)
            }
            printJSON(["deletedRun": id])
        } catch {
            printJSONError(scheduledJobCLIErrorMessage(error))
            throw ExitCode.failure
        }
    }
}

private func scheduledWeekdayName(_ weekday: ScheduledWeekday) -> String {
    switch weekday {
    case .monday: "mon"
    case .tuesday: "tue"
    case .wednesday: "wed"
    case .thursday: "thu"
    case .friday: "fri"
    case .saturday: "sat"
    case .sunday: "sun"
    }
}

func parseScheduledWeekdayMask(_ raw: String) throws -> Int {
    let normalized = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    switch normalized {
    case "daily": return 127
    case "weekdays":
        return ScheduledWeekday.monday.mask | ScheduledWeekday.tuesday.mask
            | ScheduledWeekday.wednesday.mask | ScheduledWeekday.thursday.mask
            | ScheduledWeekday.friday.mask
    case "weekends": return ScheduledWeekday.saturday.mask | ScheduledWeekday.sunday.mask
    default: break
    }

    let mapping: [String: ScheduledWeekday] = [
        "mon": .monday, "monday": .monday,
        "tue": .tuesday, "tues": .tuesday, "tuesday": .tuesday,
        "wed": .wednesday, "wednesday": .wednesday,
        "thu": .thursday, "thur": .thursday, "thurs": .thursday, "thursday": .thursday,
        "fri": .friday, "friday": .friday,
        "sat": .saturday, "saturday": .saturday,
        "sun": .sunday, "sunday": .sunday,
    ]
    let tokens = normalized.split(separator: ",").map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !tokens.isEmpty, tokens.allSatisfy({ mapping[$0] != nil }) else {
        throw ValidationError("Invalid --weekdays value. Use mon..sun, daily, weekdays, or weekends.")
    }
    return tokens.reduce(0) { $0 | mapping[$1]!.mask }
}

func parseScheduledLocalTime(_ raw: String) throws -> Int {
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2,
          parts[0].count == 2,
          parts[1].count == 2,
          let hour = Int(parts[0]),
          let minute = Int(parts[1]),
          (0 ... 23).contains(hour),
          (0 ... 59).contains(minute)
    else {
        throw ValidationError("Invalid --time value. Use 24-hour HH:mm format.")
    }
    return hour * 60 + minute
}

func parseScheduledProvider(_ raw: String) throws -> ScheduledJobProvider {
    let provider = ScheduledJobProvider(rawValue: raw.lowercased())
    guard provider.isSupported else {
        throw ValidationError("Invalid provider '\(raw)'. Use claude or codex.")
    }
    return provider
}

func scheduledJobCLIErrorMessage(_ error: Error) -> String {
    if let validationError = error as? ValidationError {
        return validationError.message
    }
    if let localizedError = error as? LocalizedError,
       let description = localizedError.errorDescription {
        return description
    }
    return error.localizedDescription
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the CLI marketing version and monotonic build number as JSON")

    struct VersionInfo: Encodable {
        let version: String
        let build: Int
    }

    func run() throws {
        printJSON(VersionInfo(version: RubienCLIVersion.marketing,
                              build: RubienCLIVersion.build))
    }
}

struct Styles: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List available citation styles")

    func run() throws {
        struct StyleDTO: Encodable {
            let id: String
            let title: String
            let isBuiltin: Bool
            let citationKind: String
        }
        let dtos = CSLManager.shared.availableStyles().map { s in
            StyleDTO(id: s.id, title: s.title, isBuiltin: s.isBuiltin, citationKind: s.citationKind.rawValue)
        }
        printJSON(dtos)
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Export references as BibTeX, RIS, or JSON")

    @Option(name: .shortAndLong, help: "Output format: json, bibtex, ris")
    var format: String = "json"

    func run() throws {
        let refs = try AppDatabase.shared.fetchAllReferences()

        switch format {
        case "bibtex":
            let keys = uniqueBibTeXKeys(for: refs)
            var output = ""
            output.reserveCapacity(refs.count * 300)
            for (i, ref) in refs.enumerated() {
                let entryType: String
                switch ref.referenceType {
                case .journalArticle:  entryType = "article"
                case .conferencePaper: entryType = "inproceedings"
                case .book:            entryType = "book"
                case .thesis:          entryType = "phdthesis"
                case .webpage, .other, .markdown: entryType = "misc"
                }
                output += "@\(entryType){\(keys[i]),\n"
                output += "  title = {\(escapeBibTeX(ref.title))},\n"
                let authStr = ref.authors.map { "\($0.family), \($0.given)" }.joined(separator: " and ")
                if !authStr.isEmpty { output += "  author = {\(escapeBibTeX(authStr))},\n" }
                if let y = ref.year { output += "  year = {\(y)},\n" }
                if let j = ref.journal { output += "  journal = {\(escapeBibTeX(j))},\n" }
                if let v = ref.volume { output += "  volume = {\(v)},\n" }
                if let n = ref.issue { output += "  number = {\(n)},\n" }
                if let p = ref.pages { output += "  pages = {\(p)},\n" }
                if let d = ref.doi { output += "  doi = {\(d)},\n" }
                if let u = ref.url { output += "  url = {\(u)},\n" }
                if let isbn = ref.isbn { output += "  isbn = {\(isbn)},\n" }
                if let issn = ref.issn { output += "  issn = {\(issn)},\n" }
                if let pub = ref.publisher { output += "  publisher = {\(escapeBibTeX(pub))},\n" }
                output += "}\n\n"
            }
            print(output, terminator: "")
        case "ris":
            var output = ""
            output.reserveCapacity(refs.count * 300)
            for ref in refs {
                let risType: String
                switch ref.referenceType {
                case .journalArticle:  risType = "JOUR"
                case .book:            risType = "BOOK"
                case .conferencePaper: risType = "CONF"
                case .thesis:          risType = "THES"
                case .webpage:         risType = "ELEC"
                case .other, .markdown: risType = "GEN"
                }
                output += "TY  - \(risType)\n"
                output += "TI  - \(ref.title)\n"
                for author in ref.authors {
                    output += "AU  - \(author.family), \(author.given)\n"
                }
                if let y = ref.year { output += "PY  - \(y)\n" }
                if let j = ref.journal { output += "JO  - \(j)\n" }
                if let v = ref.volume { output += "VL  - \(v)\n" }
                if let n = ref.issue { output += "IS  - \(n)\n" }
                if let p = ref.pages {
                    let parts = p.split(separator: "-", maxSplits: 1)
                    output += "SP  - \(parts.first ?? Substring(p))\n"
                    if parts.count > 1 { output += "EP  - \(parts[1])\n" }
                }
                if let d = ref.doi { output += "DO  - \(d)\n" }
                if let u = ref.url { output += "UR  - \(u)\n" }
                if let isbn = ref.isbn { output += "SN  - \(isbn)\n" }
                if let pub = ref.publisher { output += "PB  - \(pub)\n" }
                if let ab = ref.abstract { output += "AB  - \(ab)\n" }
                output += "ER  - \n\n"
            }
            print(output, terminator: "")
        default:
            printJSON(try mapReferenceDTOs(refs))
        }
    }
}

// MARK: - Views

struct Views: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "views",
        abstract: "Manage database views"
    )

    @Flag(name: .long, help: "Create a new view")
    var create = false

    @Option(name: .long, help: "View name (for --create or --rename)")
    var name: String?

    @Option(name: .long, help: "Delete a view by ID")
    var delete: Int64?

    @Option(name: .long, help: "Rename a view by ID")
    var rename: Int64?

    @Option(name: .long, help: "JSON filters (for --create)")
    var filters: String?

    @Option(name: .long, help: "JSON sorts (for --create)")
    var sorts: String?

    @Option(name: .long, help: "JSON groupBy (for --create)")
    var groupBy: String?

    func run() throws {
        let db = AppDatabase.shared

        if create {
            guard let viewName = name else {
                printJSONError("--name is required with --create")
                throw ExitCode.failure
            }
            let parsedFilters = try decodeOption([ViewFilter].self, from: filters, flag: "--filters", default: [])
            let parsedSorts = try decodeOption([ViewSort].self, from: sorts, flag: "--sorts", default: [.defaultSort])
            let parsedGroupBy = try decodeOption(GroupConfig?.self, from: groupBy, flag: "--group-by", default: nil)
            let existing = try db.fetchAllDatabaseViews()
            let maxOrder = existing.map(\.displayOrder).max() ?? 0
            var view = DatabaseView(
                name: viewName,
                filters: parsedFilters,
                sorts: parsedSorts,
                groupBy: parsedGroupBy,
                displayOrder: maxOrder + 1
            )
            try db.saveDatabaseView(&view)
            notifyLibraryChanged()
            printJSON(DatabaseViewDTO(from: view))
        } else if let deleteId = delete {
            guard let view = try db.fetchDatabaseView(id: deleteId) else {
                printJSONError("View \(deleteId) not found")
                throw ExitCode.failure
            }
            if view.isDefault {
                printJSONError("Cannot delete the default view")
                throw ExitCode.failure
            }
            try db.deleteDatabaseView(id: deleteId)
            notifyLibraryChanged()
            printJSON(["deleted": deleteId])
        } else if let renameId = rename {
            guard var view = try db.fetchDatabaseView(id: renameId) else {
                printJSONError("View \(renameId) not found")
                throw ExitCode.failure
            }
            guard let newName = name else {
                printJSONError("--name is required with --rename")
                throw ExitCode.failure
            }
            view.name = newName
            try db.saveDatabaseView(&view)
            notifyLibraryChanged()
            printJSON(DatabaseViewDTO(from: view))
        } else {
            let views = try db.fetchAllDatabaseViews()
            printJSON(views.map(DatabaseViewDTO.init))
        }
    }

    private func decodeOption<T: Decodable>(_ type: T.Type, from json: String?, flag: String, default fallback: T) throws -> T {
        guard let json else { return fallback }
        guard let data = json.data(using: .utf8) else {
            printJSONError("\(flag) is not valid UTF-8")
            throw ExitCode.failure
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            printJSONError("\(flag) JSON is invalid: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

/// Forces an optional value to encode explicitly — `null` when absent rather
/// than being omitted. Swift's synthesized Encodable calls `encodeIfPresent`
/// for optionals and drops the key entirely, which would break the scripting
/// contract that every DTO field is always present.
struct AlwaysEncodedOptional<T: Encodable>: Encodable {
    let value: T?

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let value { try c.encode(value) }
        else { try c.encodeNil() }
    }
}

struct DatabaseViewDTO: Encodable {
    let id: Int64?
    let name: String
    let icon: String
    let isDefault: Bool
    let displayOrder: Int
    let scope: ViewScope
    let columns: [ColumnConfig]
    let filters: [ViewFilter]
    let sorts: [ViewSort]
    let groupBy: AlwaysEncodedOptional<GroupConfig>
    let dateCreated: Date
    let dateModified: Date

    init(from view: DatabaseView) {
        self.id = view.id
        self.name = view.name
        self.icon = view.icon
        self.isDefault = view.isDefault
        self.displayOrder = view.displayOrder
        self.scope = view.parsedScope
        self.columns = view.parsedColumns
        self.filters = view.parsedFilters
        self.sorts = view.parsedSorts
        self.groupBy = AlwaysEncodedOptional(value: view.parsedGroupBy)
        self.dateCreated = view.dateCreated
        self.dateModified = view.dateModified
    }
}

// MARK: - PDF Subcommands

extension PDFExtractor.Format: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument.lowercased() {
        case "jpeg", "jpg": self = .jpeg
        case "png": self = .png
        default: return nil
        }
    }

    public static var allValueStrings: [String] { ["jpeg", "png"] }
}

struct Pdf: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "Inspect and extract content from a reference's attached PDF",
        subcommands: [PdfInfo.self, PdfPageImage.self, PdfStatus.self, PdfDownload.self]
    )
}

private func resolveReferencePDFURL(for id: Int64) throws -> URL {
    guard let ref = try AppDatabase.shared.fetchReferences(ids: [id]).first else {
        printJSONError("Reference \(id) not found")
        throw ExitCode.failure
    }
    guard let refId = ref.id,
          let pdfPath = (try? AppDatabase.shared.pdfFilename(for: refId)),
          !pdfPath.isEmpty else {
        printJSONError("Reference \(id) has no attached PDF")
        throw ExitCode.failure
    }
    let url = PDFService.pdfURL(for: pdfPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        printJSONError("PDF file missing at \(url.path)")
        throw ExitCode.failure
    }
    return url
}

private func emitPDFExtractError(_ error: PDFExtractor.ExtractError) {
    var obj: [String: String] = ["error": error.code]
    switch error {
    case .pageOutOfRange(let p): obj["page"] = String(p)
    case .maxBytesExceeded(let b): obj["maxBytes"] = String(b)
    case .invalidPageRange(let s): obj["range"] = s
    case .fileMissing(let p), .cannotOpen(let p): obj["path"] = p
    default: break
    }
    if let data = try? jsonEncoder.encode(obj), let str = String(data: data, encoding: .utf8) {
        FileHandle.standardError.write(Data((str + "\n").utf8))
    }
}

/// Resolve `id` → PDF URL, run `extractor`, print its Encodable output, and
/// translate `PDFExtractor.ExtractError` into the structured stderr envelope.
/// Used by all three `pdf` subcommands so the resolve-try-catch boilerplate
/// lives in one place.
private func runPdfSubcommand<Result: Encodable>(
    referenceId id: Int64,
    _ extractor: (URL) throws -> Result
) throws {
    let url = try resolveReferencePDFURL(for: id)
    do {
        printJSON(try extractor(url))
    } catch let e as PDFExtractor.ExtractError {
        emitPDFExtractError(e)
        throw ExitCode.failure
    }
}

// MARK: - read (kind-agnostic body/annotation reads)

enum PDFSourceState: String {
    case notAttached, notMaterialized, missingFile, available
}

func pdfStateDescription(_ state: PDFSourceState) -> String {
    switch state {
    case .notAttached: return "no PDF attached"
    case .notMaterialized: return "PDF attached but not materialized on this device (see 'pdf status')"
    case .missingFile: return "PDF materialized but its file is missing on disk"
    case .available: return "available"
    }
}

struct SourceAvailability {
    let pdfState: PDFSourceState
    let pdfURL: URL?                             // non-nil iff pdfState == .available
    let web: Reference.DecodedWebContent?        // non-nil iff web is readable
    var available: [String] {
        var out: [String] = []
        if pdfState == .available { out.append("pdf") }
        if web != nil { out.append("web") }
        return out
    }
}

/// Resolve which body sources a reference can serve right now. Four-state PDF
/// (spec §4): pdfFilename(for:) alone can't distinguish attached-not-materialized
/// from never-attached, so read the pdfCache row like `pdf status` does.
func resolveSources(for ref: Reference) throws -> SourceAvailability {
    var pdfState = PDFSourceState.notAttached
    var pdfURL: URL? = nil
    if let refId = ref.id, let status = try AppDatabase.shared.pdfCacheStatus(for: refId) {
        if status.materializedAt == nil {
            pdfState = .notMaterialized
        } else {
            let url = PDFService.pdfURL(for: status.localFilename)
            if FileManager.default.fileExists(atPath: url.path) {
                pdfState = .available
                pdfURL = url
            } else {
                pdfState = .missingFile
            }
        }
    }
    return SourceAvailability(pdfState: pdfState, pdfURL: pdfURL, web: ref.decodedWebContent)
}

enum ReadSource: String, ExpressibleByArgument, CaseIterable {
    case pdf, web
}

struct Read: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read a reference's body text or annotations, whichever kind it is (PDF or web clip)",
        subcommands: [ReadText.self, ReadAnnotations.self]
    )
}

struct ReadTextPdfOutput: Encodable {
    let id: Int64
    let source: String
    let available: [String]
    let pageCount: Int
    let selection: PDFExtractor.SelectionEcho
    let pages: [PDFExtractor.PageContent]
    let truncated: Bool
    let hasTextLayer: Bool
}

struct ReadTextWebOutput: Encodable {
    let id: Int64
    let source: String
    let available: [String]
    let url: String?
    let siteName: String?
    let contentFormat: String
    let content: String
    let contentLength: Int
    let start: Int
    let returnedChars: Int
    let truncated: Bool
    let annotationCount: Int
}

struct ReadText: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text",
        abstract: "Read the body text of a reference (PDF pages/sections or web body window)"
    )

    @Argument(help: "Reference ID")
    var id: Int64

    @Option(name: .customLong("pages"),
            help: "PDF page range: e.g. 1-3, 1-3,8-10, 12-. Implies a PDF source.")
    var pages: String?

    @Option(name: .customLong("section"), parsing: .singleValue,
            help: "PDF section title substring (case-insensitive, repeatable). Implies a PDF source.")
    var sections: [String] = []

    @Option(name: .customLong("start"),
            help: "Character offset into the web body (default 0). Implies a web source.")
    var start: Int?

    @Option(name: .customLong("max-chars"),
            help: "Cap total returned characters (default 50000)")
    var maxChars: Int = 50_000

    @Option(name: .customLong("source"),
            help: "Force a source: pdf or web (default: pages/sections imply pdf, start implies web, else PDF wins)")
    var source: ReadSource?

    func run() throws {
        guard maxChars > 0, maxChars <= 500_000 else {
            printJSONError("--max-chars must be between 1 and 500000")
            throw ExitCode.failure
        }
        if let start, start < 0 {
            printJSONError("--start must be >= 0")
            throw ExitCode.failure
        }
        let pdfParamsGiven = pages != nil || !sections.isEmpty
        let webParamsGiven = start != nil
        if pages != nil && !sections.isEmpty {
            printJSONError("--pages and --section are mutually exclusive")
            throw ExitCode.failure
        }
        if pdfParamsGiven && webParamsGiven {
            printJSONError("--pages/--section and --start are mutually exclusive (PDF vs web addressing)")
            throw ExitCode.failure
        }

        guard let ref = try AppDatabase.shared.fetchReferences(ids: [id]).first else {
            printJSONError("Reference \(id) not found")
            throw ExitCode.failure
        }
        let avail = try resolveSources(for: ref)
        let availJSON = "[" + avail.available.map { "\"\($0)\"" }.joined(separator: ",") + "]"

        // Explicit-source contradictions report AFTER the probe so the error can
        // carry real availability (spec §5: requested source + available + state).
        if let source {
            if source == .web && pdfParamsGiven {
                printJSONError("--pages/--section require a PDF source (requested source: web); available: \(availJSON)")
                throw ExitCode.failure
            }
            if source == .pdf && webParamsGiven {
                printJSONError("--start requires a web source (requested source: pdf); available: \(availJSON)")
                throw ExitCode.failure
            }
        }

        let resolved: ReadSource
        if let source {
            resolved = source
        } else if pdfParamsGiven {
            resolved = .pdf
        } else if webParamsGiven {
            resolved = .web
        } else if avail.pdfState == .available {
            resolved = .pdf
        } else if avail.web != nil {
            resolved = .web
        } else {
            printJSONError("Reference \(id) has no readable content (pdf: \(pdfStateDescription(avail.pdfState)); web: none)")
            throw ExitCode.failure
        }

        switch resolved {
        case .pdf:
            guard let url = avail.pdfURL else {
                printJSONError("source \"pdf\" is not readable (pdf: \(pdfStateDescription(avail.pdfState))); available: \(availJSON)")
                throw ExitCode.failure
            }
            let selection: PDFExtractor.Selection
            if !sections.isEmpty {
                selection = .sections(sections)
            } else if let pages, !pages.isEmpty {
                selection = .pagesString(pages)
            } else {
                selection = .allPages
            }
            do {
                let result = try PDFExtractor.extractText(at: url, selection: selection, maxChars: maxChars)
                printJSON(ReadTextPdfOutput(
                    id: id, source: "pdf", available: avail.available,
                    pageCount: result.pageCount, selection: result.selection,
                    pages: result.pages, truncated: result.truncated,
                    hasTextLayer: result.hasTextLayer
                ))
            } catch let e as PDFExtractor.ExtractError {
                emitPDFExtractError(e)
                throw ExitCode.failure
            }
        case .web:
            guard let decoded = avail.web else {
                printJSONError("source \"web\" is not readable (reference \(id) has no web content); available: \(availJSON)")
                throw ExitCode.failure
            }
            let body = decoded.body
            let total = body.count
            let offset = start ?? 0
            let slice: String
            let returned: Int
            let truncated: Bool
            if offset >= total {
                slice = ""; returned = 0; truncated = false
            } else {
                let startIdx = body.index(body.startIndex, offsetBy: offset)
                let remaining = total - offset
                let take = min(maxChars, remaining)
                let endIdx = body.index(startIdx, offsetBy: take)
                slice = String(body[startIdx..<endIdx])
                returned = take
                truncated = take < remaining
            }
            let annotationCount = (try? AppDatabase.shared.webAnnotationCount(referenceId: id)) ?? 0
            printJSON(ReadTextWebOutput(
                id: id, source: "web", available: avail.available,
                url: ref.url, siteName: ref.siteName,
                contentFormat: decoded.format.rawValue,
                content: slice, contentLength: total, start: offset,
                returnedChars: returned, truncated: truncated,
                annotationCount: annotationCount
            ))
        }
    }
}

/// Union DTO for both annotation kinds. `id` is non-optional by contract
/// (fetched rows always have rowids; the zod mirror requires it). Kind-foreign
/// optionals are OMITTED from JSON, not null — synthesized Encodable encodes
/// optionals via encodeIfPresent (the same behavior ReferenceDTO.lastReadAt
/// documents and relies on).
struct ReadAnnotationItem: Encodable {
    let source: String
    let id: Int64
    let type: String
    let color: String
    let noteText: String?
    let dateCreated: Date
    let dateModified: Date
    // pdf-only anchors
    let pageIndex: Int?
    let selectedText: String?
    // web-only anchors
    let anchorText: String?
    let prefixText: String?
    let suffixText: String?
}

struct ReadAnnotations: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "annotations",
        abstract: "List a reference's annotations, PDF and web merged (source-tagged)"
    )

    @Argument(help: "Reference ID")
    var id: Int64

    @Option(name: .customLong("source"), help: "Filter to one kind: pdf or web")
    var source: ReadSource?

    func run() throws {
        var items: [ReadAnnotationItem] = []
        // .compactMap drops a nil-id row (impossible for fetched records) rather
        // than inventing an id or crashing.
        if source != .web {
            let pdf = (try AppDatabase.shared.fetchAnnotations(referenceId: id))
                .sorted { ($0.pageIndex, $0.id ?? 0) < ($1.pageIndex, $1.id ?? 0) }
            items += pdf.compactMap { a in
                guard let rowId = a.id else { return nil }
                return ReadAnnotationItem(
                    source: "pdf", id: rowId, type: a.type.rawValue, color: a.color,
                    noteText: a.noteText, dateCreated: a.dateCreated, dateModified: a.dateModified,
                    pageIndex: a.pageIndex, selectedText: a.selectedText,
                    anchorText: nil, prefixText: nil, suffixText: nil
                )
            }
        }
        if source != .pdf {
            let web = (try AppDatabase.shared.fetchWebAnnotations(referenceId: id))
                .sorted { ($0.dateCreated, $0.id ?? 0) < ($1.dateCreated, $1.id ?? 0) }
            items += web.compactMap { a in
                guard let rowId = a.id else { return nil }
                return ReadAnnotationItem(
                    source: "web", id: rowId, type: a.type.rawValue, color: a.color,
                    noteText: a.noteText, dateCreated: a.dateCreated, dateModified: a.dateModified,
                    pageIndex: nil, selectedText: nil,
                    anchorText: a.anchorText, prefixText: a.prefixText, suffixText: a.suffixText
                )
            }
        }
        printJSON(items)
    }
}

// MARK: - grep (kind-agnostic body-text search)

struct GrepPdfOutput: Encodable {
    let id: Int64
    let source: String
    let available: [String]
    let query: String
    let isRegex: Bool
    let pageCount: Int
    let hasTextLayer: Bool
    let totalMatches: Int
    let totalMatchingPages: Int
    let truncated: Bool
    let pages: [PDFExtractor.PageSearchHit]
}

struct GrepWebMatch: Encodable {
    let start: Int
    let matchCount: Int
    let snippet: String
}

struct GrepWebOutput: Encodable {
    let id: Int64
    let source: String
    let available: [String]
    let query: String
    let isRegex: Bool
    let contentLength: Int
    let totalMatches: Int
    let totalEntries: Int
    let truncated: Bool
    let matches: [GrepWebMatch]
}

struct Grep: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grep",
        abstract: "Find where a phrase or regex occurs in a reference's body text (PDF pages or web offsets)"
    )

    @Argument(help: "Reference ID")
    var id: Int64

    @Argument(help: "Literal phrase (default) or regex (--regex). Case-insensitive.")
    var query: String

    @Flag(name: .customLong("regex"), help: "Treat the query as a regular expression")
    var isRegex: Bool = false

    @Option(name: .customLong("source"),
            help: "Force a source: pdf or web (default: pdf-scoped flags imply pdf, --max-matches implies web, else PDF wins)")
    var source: ReadSource?

    @Option(name: .customLong("context-chars"),
            help: "Snippet window width (default 160)")
    var contextChars: Int?

    @Option(name: .customLong("pages"),
            help: "PDF page range scope, e.g. 1-3,8-10. Implies a PDF source.")
    var pages: String?

    @Option(name: .customLong("max-pages"),
            help: "Cap returned PDF page-hits (default 30). Implies a PDF source.")
    var maxPages: Int?

    @Option(name: .customLong("snippets-per-page"),
            help: "Cap snippets per PDF page (default 3). Implies a PDF source.")
    var snippetsPerPage: Int?

    @Option(name: .customLong("max-matches"),
            help: "Cap returned web match entries (default 20). Implies a web source.")
    var maxMatches: Int?

    func run() throws {
        func requireBounds(_ value: Int?, _ flag: String, _ range: ClosedRange<Int>) throws {
            if let value, !range.contains(value) {
                printJSONError("\(flag) must be between \(range.lowerBound) and \(range.upperBound)")
                throw ExitCode.failure
            }
        }
        try requireBounds(contextChars, "--context-chars", 1...2_000)
        try requireBounds(maxPages, "--max-pages", 1...200)
        try requireBounds(snippetsPerPage, "--snippets-per-page", 1...20)
        try requireBounds(maxMatches, "--max-matches", 1...200)

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            printJSONError("query must not be empty")
            throw ExitCode.failure
        }
        // Validate a regex up front so the error beats routing (spec §7).
        if isRegex {
            do { _ = try BodyTextQuery.compile(query, isRegex: true) }
            catch {
                printJSONError("invalid-regex: \(error)")
                throw ExitCode.failure
            }
        }

        let pdfParamsGiven = pages != nil || maxPages != nil || snippetsPerPage != nil
        let webParamsGiven = maxMatches != nil
        if pdfParamsGiven && webParamsGiven {
            printJSONError("--pages/--max-pages/--snippets-per-page and --max-matches are mutually exclusive (PDF vs web scoping)")
            throw ExitCode.failure
        }

        guard let ref = try AppDatabase.shared.fetchReferences(ids: [id]).first else {
            printJSONError("Reference \(id) not found")
            throw ExitCode.failure
        }
        let avail = try resolveSources(for: ref)
        let availJSON = "[" + avail.available.map { "\"\($0)\"" }.joined(separator: ",") + "]"

        if let source {
            if source == .web && pdfParamsGiven {
                printJSONError("--pages/--max-pages/--snippets-per-page require a PDF source (requested source: web); available: \(availJSON)")
                throw ExitCode.failure
            }
            if source == .pdf && webParamsGiven {
                printJSONError("--max-matches requires a web source (requested source: pdf); available: \(availJSON)")
                throw ExitCode.failure
            }
        }

        let resolved: ReadSource
        if let source {
            resolved = source
        } else if pdfParamsGiven {
            resolved = .pdf
        } else if webParamsGiven {
            resolved = .web
        } else if avail.pdfState == .available {
            resolved = .pdf
        } else if avail.web != nil {
            resolved = .web
        } else {
            printJSONError("Reference \(id) has no readable content (pdf: \(pdfStateDescription(avail.pdfState)); web: none)")
            throw ExitCode.failure
        }

        switch resolved {
        case .pdf:
            guard let url = avail.pdfURL else {
                printJSONError("source \"pdf\" is not readable (pdf: \(pdfStateDescription(avail.pdfState))); available: \(availJSON)")
                throw ExitCode.failure
            }
            do {
                let result = try PDFExtractor.search(
                    at: url, query: query, isRegex: isRegex,
                    pagesString: pages,
                    maxPages: maxPages ?? 30,
                    snippetsPerPage: snippetsPerPage ?? 3,
                    contextChars: contextChars ?? 160
                )
                printJSON(GrepPdfOutput(
                    id: id, source: "pdf", available: avail.available,
                    query: query, isRegex: isRegex,
                    pageCount: result.pageCount, hasTextLayer: result.hasTextLayer,
                    totalMatches: result.totalMatches,
                    totalMatchingPages: result.totalMatchingPages,
                    truncated: result.truncated, pages: result.pages
                ))
            } catch let e as PDFExtractor.ExtractError {
                emitPDFExtractError(e)
                throw ExitCode.failure
            }
        case .web:
            guard let decoded = avail.web else {
                printJSONError("source \"web\" is not readable (reference \(id) has no web content); available: \(availJSON)")
                throw ExitCode.failure
            }
            let body = decoded.body
            let compiled: BodyTextQuery
            do { compiled = try BodyTextQuery.compile(query, isRegex: isRegex) }
            catch {
                printJSONError("invalid-regex: \(error)")
                throw ExitCode.failure
            }
            let ranges = BodyTextMatcher.matches(in: body, query: compiled)
            let clusters = BodyTextMatcher.clusters(in: body, ranges: ranges,
                                                    contextChars: contextChars ?? 160)
            let cap = maxMatches ?? 20
            let kept = Array(clusters.prefix(cap))
            printJSON(GrepWebOutput(
                id: id, source: "web", available: avail.available,
                query: query, isRegex: isRegex,
                contentLength: body.count,
                totalMatches: ranges.count,
                totalEntries: clusters.count,
                truncated: clusters.count > kept.count,
                matches: kept.map { GrepWebMatch(start: $0.start, matchCount: $0.matchCount, snippet: $0.snippet) }
            ))
        }
    }
}

struct PdfInfoOutput: Encodable {
    let id: Int64
    let pageCount: Int
    let hasTextLayer: Bool
    let fileBytes: Int
    let isEncrypted: Bool
    let documentTitle: String?
    let sections: [PDFExtractor.Section]?
}

struct PdfInfo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Print PDF metadata + outline-derived sections for a reference"
    )

    @Argument(help: "Reference ID")
    var id: Int64

    func run() throws {
        try runPdfSubcommand(referenceId: id) { url in
            let info = try PDFExtractor.info(at: url)
            return PdfInfoOutput(
                id: id,
                pageCount: info.pageCount,
                hasTextLayer: info.hasTextLayer,
                fileBytes: info.fileBytes,
                isEncrypted: info.isEncrypted,
                documentTitle: info.documentTitle,
                sections: info.sections
            )
        }
    }
}

struct PdfPageImageOutput: Encodable {
    let id: Int64
    let page: Int
    let mimeType: String
    let data: String
    let widthPx: Int
    let heightPx: Int
    let qualityUsed: Double?
}

struct PdfPageImage: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "page-image",
        abstract: "Render a single PDF page to a base64-encoded image (JPEG by default)"
    )

    @Argument(help: "Reference ID")
    var id: Int64

    @Option(name: .customLong("page"), help: "Page number (1-indexed)")
    var page: Int

    @Option(name: .customLong("scale"), help: "Render scale (default 2.0 ≈ 192 DPI)")
    var scale: Double = 2.0

    @Option(name: .customLong("max-bytes"), help: "Cap rendered image bytes (default 2_000_000)")
    var maxBytes: Int = 2_000_000

    @Option(name: .customLong("format"), help: "Output format: jpeg or png (default jpeg)")
    var format: PDFExtractor.Format = .jpeg

    func run() throws {
        try runPdfSubcommand(referenceId: id) { url in
            let img = try PDFExtractor.renderPage(
                at: url,
                page: page,
                scale: CGFloat(scale),
                maxBytes: maxBytes,
                format: format
            )
            return PdfPageImageOutput(
                id: id,
                page: img.page,
                mimeType: img.mimeType,
                data: img.data.base64EncodedString(),
                widthPx: img.widthPx,
                heightPx: img.heightPx,
                qualityUsed: img.qualityUsed
            )
        }
    }
}

/// JSON shape for `pdf status`. Optional fields use `encodeIfPresent` so they
/// are omitted entirely when nil — callers (scripts, the MCP server) treat
/// key presence as the signal for "this device has a cache row".
struct PdfStatusOutput: Encodable {
    let referenceId: Int64
    let cached: Bool
    let localFilename: String?
    let contentHash: String?
    let assetVersion: Int64?
    let materializedAt: Date?
    let lastOpenedAt: Date?
    let inUploadQueue: Bool?

    enum CodingKeys: String, CodingKey {
        case referenceId, cached, localFilename, contentHash, assetVersion
        case materializedAt, lastOpenedAt, inUploadQueue
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(referenceId, forKey: .referenceId)
        try c.encode(cached, forKey: .cached)
        try c.encodeIfPresent(localFilename, forKey: .localFilename)
        try c.encodeIfPresent(contentHash, forKey: .contentHash)
        try c.encodeIfPresent(assetVersion, forKey: .assetVersion)
        try c.encodeIfPresent(materializedAt, forKey: .materializedAt)
        try c.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
        try c.encodeIfPresent(inUploadQueue, forKey: .inUploadQueue)
    }
}

struct PdfStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show PDF cache + upload-queue state for a reference"
    )

    @Argument(help: "Reference ID")
    var id: Int64

    func run() throws {
        guard let status = try AppDatabase.shared.pdfCacheStatus(for: id) else {
            printJSON(PdfStatusOutput(
                referenceId: id,
                cached: false,
                localFilename: nil,
                contentHash: nil,
                assetVersion: nil,
                materializedAt: nil,
                lastOpenedAt: nil,
                inUploadQueue: nil
            ))
            return
        }
        printJSON(PdfStatusOutput(
            referenceId: status.referenceId,
            cached: status.materializedAt != nil,
            localFilename: status.localFilename,
            contentHash: status.contentHash,
            assetVersion: status.assetVersion,
            materializedAt: status.materializedAt,
            lastOpenedAt: status.lastOpenedAt,
            inUploadQueue: status.inUploadQueue
        ))
    }
}

struct PdfDownloadOutput: Encodable {
    let id: Int64
    let ok: Bool
    let action: PDFDownloadAction
    let filename: String?
}

struct PdfDownload: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Fetch the open-access PDF for a reference and attach it."
    )

    @Argument(help: "Reference ID")
    var id: Int64

    @Flag(name: .long, help: "Replace any attached PDF instead of skipping.")
    var force: Bool = false

    func run() async throws {
        let refs = try AppDatabase.shared.fetchReferences(ids: [id])
        guard let ref = refs.first else {
            printJSONError("Reference \(id) not found")
            throw ExitCode.failure
        }

        // Explicit do/catch keeps the failure on stderr as `{"error":...}`
        // (MCP contract), not as swift-argument-parser's default formatting.
        let existing: AppDatabase.PDFCacheStatus?
        do {
            existing = try AppDatabase.shared.pdfCacheStatus(for: id)
        } catch {
            printJSONError("Failed to read PDF cache state: \(error.localizedDescription)")
            throw ExitCode.failure
        }
        let materialized = existing?.materializedAt != nil
        let existingFilename = materialized ? existing?.localFilename : nil

        // Skip-if-attached (default).
        if existing != nil && !force {
            printJSON(PdfDownloadOutput(
                id: id, ok: true,
                action: materialized ? .alreadyAttached : .alreadyPending,
                filename: existingFilename))
            return
        }

        guard ref.canDownloadPDF else {
            printJSONError("No DOI or arXiv identifier available for reference \(id)")
            throw ExitCode.failure
        }

        // --force replace: DB detach FIRST so attach can't no-op. If detach
        // throws, disk state stays unchanged.
        if existing != nil {
            do {
                try AppDatabase.shared.detachReferencePDF(id: id)
            } catch {
                printJSONError("Failed to detach existing PDF: \(error.localizedDescription)")
                throw ExitCode.failure
            }
            if let old = existingFilename {
                try? FileManager.default.removeItem(
                    at: AppDatabase.pdfStorageURL.appendingPathComponent(old))
            }
        }

        let filename: String
        do {
            filename = try await downloadAndAttachPDF(for: ref, refId: id)
        } catch let err as PDFDownloadService.DownloadError {
            printJSONError(err.localizedDescription)
            throw ExitCode.failure
        } catch {
            printJSONError("Failed to attach PDF: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // Verify-after-attach: a concurrent writer can have inserted a
        // `pdfCache` row, in which case our `attachImportedPDFs` silently
        // no-op'd and our file is orphaned. On verify-read failure, do NOT
        // delete the file — state is ambiguous.
        let post: String?
        do {
            post = try AppDatabase.shared.pdfFilename(for: id)
        } catch {
            printJSONError("Attached PDF but verification read failed; library may need reconciliation: \(error.localizedDescription)")
            throw ExitCode.failure
        }
        if post != filename {
            try? FileManager.default.removeItem(
                at: AppDatabase.pdfStorageURL.appendingPathComponent(filename))
            printJSON(PdfDownloadOutput(
                id: id, ok: true,
                action: post != nil ? .alreadyAttached : .alreadyPending,
                filename: post))
            return
        }
        notifyLibraryChanged()
        PDFUploadQueueBroadcaster.postChangeNotification()

        printJSON(PdfDownloadOutput(
            id: id, ok: true,
            action: existing != nil ? .replaced : .downloaded,
            filename: filename))
    }
}
