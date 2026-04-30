import ArgumentParser
import Foundation
import RubienCore

@main
struct RubienCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rubien-cli",
        abstract: "rubien-cli — manage your Rubien reference library from the command line",
        version: "1.0.0",
        subcommands: [
            Search.self,
            List.self,
            Get.self,
            Add.self,
            Update.self,
            Delete.self,
            Cite.self,
            Import.self,
            Tags.self,
            Properties.self,
            Annotations.self,
            Styles.self,
            Export.self,
            Views.self,
            Pdf.self,
            SyncCommand.self,
        ]
    )
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
    let propertyId: String
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
        self.readingStatus = ref.readingStatus.rawValue

        let refValues = ref.id.flatMap { valuesByRef[$0] } ?? [:]
        let customDefs = defs.filter { !$0.isDefault }
        self.customProperties = customDefs.compactMap { def -> CustomPropertyValueDTO? in
            guard let propId = def.id, let value = refValues[propId] else { return nil }
            return CustomPropertyValueDTO(
                propertyId: String(propId),
                name: def.name,
                type: def.type.rawValue,
                value: value
            )
        }
    }
}

struct PropertyDefinitionDTO: Encodable {
    let id: String
    let name: String
    let type: String
    let options: [SelectOption]
    let sortOrder: Int
    let isDefault: Bool
    let defaultFieldKey: String?
    let isVisible: Bool

    init(from def: PropertyDefinition) {
        self.id = def.id.map(String.init) ?? ""
        self.name = def.name
        self.type = def.type.rawValue
        self.options = def.options
        self.sortOrder = def.sortOrder
        self.isDefault = def.isDefault
        self.defaultFieldKey = def.defaultFieldKey
        self.isVisible = def.isVisible
    }
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
        let refs = try AppDatabase.shared.fetchReferences(scope: .all, filter: filter, limit: limit)
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

    @Option(name: .customLong("reading-status"), help: "Filter by reading status (unread, reading, skimmed, read)")
    var readingStatus: String?

    @Option(name: .customLong("sort-by"), help: "Sort by field (year, dateAdded, title)")
    var sortBy: String?

    @Flag(name: .long, help: "Sort ascending (default is descending)")
    var asc = false

    func run() throws {
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
                guard let status = ReadingStatus(rawValue: rs) else {
                    let valid = ReadingStatus.allCases.map(\.rawValue).joined(separator: ", ")
                    printJSONError("Unknown reading status '\(rs)'. Valid: \(valid)")
                    throw ExitCode.failure
                }
                filter.readingStatus = status
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
    static let configuration = CommandConfiguration(abstract: "Add a reference via DOI, PMID, arXiv ID, or BibTeX")

    @Option(name: .long, help: "DOI, PMID, or arXiv ID")
    var identifier: String?

    @Option(name: .long, help: "BibTeX source")
    var bibtex: String?

    @Option(name: .long, help: "Title (for manual entry)")
    var title: String?

    func run() async throws {
        if let id = identifier {
            var ref = try await MetadataFetcher.fetch(from: id)
            ref = MetadataVerifier.manuallyVerified(ref, reviewedBy: "cli-identifier")
            try AppDatabase.shared.saveReference(&ref)
            notifyLibraryChanged()
            // saveReference may dedupe onto an existing row; surface that row's
            // existing custom properties so the contract matches get/list/export.
            printJSON(try referenceDTO(for: ref))
        } else if let bib = bibtex {
            let refs = BibTeXImporter.parse(bib)
            guard !refs.isEmpty else {
                printJSONError("No valid BibTeX entries found")
                throw ExitCode.failure
            }
            var saved: [Reference] = []
            for var ref in refs {
                try AppDatabase.shared.saveReference(&ref)
                saved.append(ref)
            }
            notifyLibraryChanged()
            printJSON(try mapReferenceDTOs(saved))
        } else if let t = title {
            var ref = Reference(title: t)
            try AppDatabase.shared.saveReference(&ref)
            notifyLibraryChanged()
            printJSON(try referenceDTO(for: ref))
        } else {
            printJSONError("Provide --identifier, --bibtex, or --title")
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

    @Option(name: .customLong("reading-status"), help: "Set reading status (unread, reading, skimmed, read)")
    var readingStatus: String?

    func run() throws {
        let refs = try AppDatabase.shared.fetchReferences(ids: [id])
        guard var ref = refs.first else {
            printJSONError("Reference \(id) not found")
            throw ExitCode.failure
        }
        if let t = title { ref.title = t }
        if let y = year { ref.year = y }
        if let a = authors { ref.authors = AuthorName.parseList(a) }
        if let rs = readingStatus {
            guard let status = ReadingStatus(rawValue: rs) else {
                let valid = ReadingStatus.allCases.map(\.rawValue).joined(separator: ", ")
                printJSONError("Unknown reading status '\(rs)'. Valid: \(valid)")
                throw ExitCode.failure
            }
            ref.readingStatus = status
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

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import references from a BibTeX/RIS file or a Zotero export folder (use '-' for stdin)"
    )

    @Argument(help: "Path to a .bib or .ris file, a Zotero export folder (containing a .bib + files/ tree), or '-' to read from stdin")
    var file: String

    @Option(name: .long, help: "Format hint when reading from stdin: bib, ris")
    var format: String?

    @Option(name: .long, help: "When importing a Zotero folder: stamp every reference with this property (default: Tags)")
    var property: String?

    @Option(name: .long, help: "When importing a Zotero folder: value to stamp on the property (default: folder basename)")
    var value: String?

    func run() throws {
        // Folder path → Zotero folder importer.
        if file != "-" {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: file, isDirectory: &isDir), isDir.boolValue {
                try runZoteroFolderImport(folderPath: file)
                return
            }
        }

        // File or stdin → existing BibTeX/RIS path.
        let content: String
        let ext: String

        if file == "-" {
            guard let fmt = format?.lowercased() else {
                printJSONError("--format (bib or ris) is required when reading from stdin")
                throw ExitCode.failure
            }
            ext = fmt
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let str = String(data: data, encoding: .utf8) else {
                printJSONError("Failed to decode stdin as UTF-8")
                throw ExitCode.failure
            }
            content = str
        } else {
            let url = URL(fileURLWithPath: file)
            ext = format?.lowercased() ?? url.pathExtension.lowercased()
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? UInt64, size > 50 * 1024 * 1024 {
                printJSONError("File exceeds 50 MB limit (\(size / 1024 / 1024) MB)")
                throw ExitCode.failure
            }
            content = try String(contentsOf: url, encoding: .utf8)
        }

        var refs: [Reference]
        switch ext {
        case "bib", "bibtex":
            refs = BibTeXImporter.parse(content)
        case "ris":
            refs = RISImporter.parse(content)
        default:
            printJSONError("Unsupported file format: .\(ext). Use .bib or .ris")
            throw ExitCode.failure
        }

        let count = try AppDatabase.shared.batchImportReferences(refs)
        notifyLibraryChanged()
        printJSON(["imported": "\(count)", "file": file])
    }

    private func runZoteroFolderImport(folderPath: String) throws {
        let folderURL = URL(fileURLWithPath: folderPath)
        let db = AppDatabase.shared

        let propertyName = property ?? PropertyDefinition.tagsPropertyName
        let stampValue = value ?? folderURL.lastPathComponent

        guard let propDef = try db.findPropertyDefinition(byName: propertyName) else {
            printJSONError("Property not found: '\(propertyName)'")
            throw ExitCode.failure
        }
        guard let propId = propDef.id else {
            printJSONError("Property '\(propertyName)' has no id")
            throw ExitCode.failure
        }

        let target = ZoteroImportPropertyTarget(propertyId: propId, value: stampValue)
        do {
            let result = try ZoteroFolderImporter.importFolder(
                at: folderURL,
                db: db,
                propertyTarget: target
            )
            notifyLibraryChanged()
            printJSON([
                "imported": "\(result.imported)",
                "attached": "\(result.attached)",
                "duplicatesSkipped": "\(result.duplicatesSkipped)",
                "missingPDFs": result.missingPDFs.joined(separator: ", "),
                "property": propertyName,
                "value": stampValue,
                "file": folderPath,
            ])
        } catch let error as ZoteroImportError {
            printJSONError(error.errorDescription ?? "\(error)")
            throw ExitCode.failure
        } catch let error as ZoteroFolderImporter.Error {
            printJSONError(error.errorDescription ?? "\(error)")
            throw ExitCode.failure
        }
    }
}

struct Tags: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List or manage tags, and assign/unassign them to references")

    @Flag(name: .long, help: "Create a new tag")
    var create = false

    @Option(name: .long, help: "Tag name (with --create or --rename)")
    var name: String?

    @Option(name: .long, help: "Tag color as hex (with --create, auto-assigned if omitted)")
    var color: String?

    @Option(name: .long, help: "Delete a tag by ID")
    var delete: Int64?

    @Flag(name: .long, help: "Assign tags to a reference (append, do not replace)")
    var assign = false

    @Flag(name: .customLong("remove-tags"), help: "Remove tags from a reference")
    var removeTags = false

    @Option(name: .long, help: "Reference ID (with --assign, --remove-tags, or to list a reference's tags)")
    var reference: Int64?

    @Option(name: .long, help: "Comma-separated tag IDs (with --assign or --remove-tags)")
    var tags: String?

    @Flag(name: .long, help: "Rename a tag")
    var rename = false

    @Option(name: .long, help: "Tag ID (with --rename)")
    var id: Int64?

    func run() throws {
        if let deleteId = delete {
            try AppDatabase.shared.deleteTag(id: deleteId)
            notifyLibraryChanged()
            printJSON(["deleted": "\(deleteId)"])
        } else if create, let n = name {
            let resolvedColor: String
            if let c = color {
                resolvedColor = c
            } else {
                let existing = try AppDatabase.shared.fetchAllTags()
                resolvedColor = ColorPalette.nextUnused(excluding: Set(existing.map(\.color)))
            }
            var t = Tag(name: n, color: resolvedColor)
            try AppDatabase.shared.saveTag(&t)
            notifyLibraryChanged()
            printJSON(["id": t.id.map(String.init) ?? "", "name": t.name, "color": t.color])
        } else if assign, let refId = reference {
            let tagIds = parseTagIds()
            guard !tagIds.isEmpty else {
                printJSONError("Provide --tags <id,...> to assign")
                throw ExitCode.failure
            }
            let existing = try AppDatabase.shared.fetchTags(forReference: refId).compactMap(\.id)
            let merged = Array(Set(existing + tagIds)).sorted()
            try AppDatabase.shared.setTags(forReference: refId, tagIds: merged)
            notifyLibraryChanged()
            let result = try AppDatabase.shared.fetchTags(forReference: refId)
            printJSON(result.map { ["id": $0.id.map(String.init) ?? "", "name": $0.name, "color": $0.color] })
        } else if removeTags, let refId = reference {
            let toRemove = Set(parseTagIds())
            guard !toRemove.isEmpty else {
                printJSONError("Provide --tags <id,...> to remove")
                throw ExitCode.failure
            }
            let existing = try AppDatabase.shared.fetchTags(forReference: refId).compactMap(\.id)
            let remaining = existing.filter { !toRemove.contains($0) }
            try AppDatabase.shared.setTags(forReference: refId, tagIds: remaining)
            notifyLibraryChanged()
            let result = try AppDatabase.shared.fetchTags(forReference: refId)
            printJSON(result.map { ["id": $0.id.map(String.init) ?? "", "name": $0.name, "color": $0.color] })
        } else if rename, let tagId = id, let n = name {
            let allTags = try AppDatabase.shared.fetchAllTags()
            guard var tag = allTags.first(where: { $0.id == tagId }) else {
                printJSONError("Tag \(tagId) not found")
                throw ExitCode.failure
            }
            tag.name = n
            if let c = color { tag.color = c }
            try AppDatabase.shared.saveTag(&tag)
            notifyLibraryChanged()
            printJSON(["id": tag.id.map(String.init) ?? "", "name": tag.name, "color": tag.color])
        } else if let refId = reference {
            // List tags for a specific reference
            let result = try AppDatabase.shared.fetchTags(forReference: refId)
            printJSON(result.map { ["id": $0.id.map(String.init) ?? "", "name": $0.name, "color": $0.color] })
        } else {
            let allTags = try AppDatabase.shared.fetchAllTags()
            let dtos = allTags.map { t in
                ["id": t.id.map(String.init) ?? "", "name": t.name, "color": t.color]
            }
            printJSON(dtos)
        }
    }

    private func parseTagIds() -> [Int64] {
        guard let s = tags else { return [] }
        return s.split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }
}

struct Properties: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "properties",
        abstract: "List or manage custom property definitions and per-reference values"
    )

    @Flag(name: .long, help: "Only visible property definitions (with list)")
    var visible = false

    @Flag(name: .long, help: "Create a new property definition")
    var create = false

    @Option(name: .long, help: "Property name (with --create or --rename)")
    var name: String?

    @Option(name: .long, help: "Property type (with --create): string, url, number, singleSelect, multiSelect, date, checkbox")
    var type: String?

    @Option(name: .long, help: "Comma-separated option values for singleSelect/multiSelect (with --create), auto-colored")
    var options: String?

    @Option(name: .long, help: "Delete a property definition by ID (ignored for built-in defaults)")
    var delete: Int64?

    @Flag(name: .long, help: "Rename a property definition")
    var rename = false

    @Flag(name: .long, help: "Mark a property as visible")
    var show = false

    @Flag(name: .long, help: "Mark a property as hidden")
    var hide = false

    @Flag(name: .customLong("add-option"), help: "Append a select option to an existing property")
    var addOption = false

    @Option(name: .long, help: "Property definition ID (with --rename, --show, --hide, --add-option, --set, --clear)")
    var id: Int64?

    @Option(name: .long, help: "Option value (with --add-option or --set on select types)")
    var value: String?

    @Option(name: .long, help: "Option color as hex (with --add-option, auto-assigned if omitted)")
    var color: String?

    @Flag(name: .long, help: "Upsert a property value on a reference (requires --reference, --id, --value)")
    var set = false

    @Flag(name: .long, help: "Clear a property value on a reference (requires --reference and --id)")
    var clear = false

    @Option(name: .long, help: "Reference ID (with --set, --clear, or to list that reference's property values)")
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
            guard let n = name else {
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
            let existing = try AppDatabase.shared.fetchAllPropertyDefinitions()
            let maxOrder = existing.map(\.sortOrder).max() ?? 0
            var prop = PropertyDefinition(
                name: n,
                type: ptype,
                options: parsedOptions,
                sortOrder: maxOrder + 1,
                isDefault: false,
                isVisible: true
            )
            try AppDatabase.shared.savePropertyDefinition(&prop)
            notifyLibraryChanged()
            printJSON(PropertyDefinitionDTO(from: prop))
            return
        }

        if rename {
            guard let propId = id, let n = name else {
                printJSONError("--rename requires --id and --name")
                throw ExitCode.failure
            }
            let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
            guard var prop = defs.first(where: { $0.id == propId }) else {
                printJSONError("Property \(propId) not found")
                throw ExitCode.failure
            }
            if prop.isDefault {
                printJSONError("Cannot rename built-in property '\(prop.name)'")
                throw ExitCode.failure
            }
            prop.name = n
            try AppDatabase.shared.savePropertyDefinition(&prop)
            notifyLibraryChanged()
            printJSON(PropertyDefinitionDTO(from: prop))
            return
        }

        if show || hide {
            guard let propId = id else {
                printJSONError("--show / --hide requires --id")
                throw ExitCode.failure
            }
            try AppDatabase.shared.togglePropertyVisibility(id: propId, visible: show)
            notifyLibraryChanged()
            let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
            guard let prop = defs.first(where: { $0.id == propId }) else {
                printJSONError("Property \(propId) not found")
                throw ExitCode.failure
            }
            printJSON(PropertyDefinitionDTO(from: prop))
            return
        }

        if addOption {
            guard let propId = id, let v = value else {
                printJSONError("--add-option requires --id and --value")
                throw ExitCode.failure
            }
            let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
            guard var prop = defs.first(where: { $0.id == propId }) else {
                printJSONError("Property \(propId) not found")
                throw ExitCode.failure
            }
            if prop.isDefault {
                printJSONError("Cannot add options to built-in property '\(prop.name)'. Built-in select values are backed by enums and cannot be extended.")
                throw ExitCode.failure
            }
            guard prop.type == .singleSelect || prop.type == .multiSelect else {
                printJSONError("--add-option only applies to singleSelect or multiSelect types")
                throw ExitCode.failure
            }
            var opts = prop.options
            let resolvedColor: String
            if let c = color {
                resolvedColor = c
            } else {
                resolvedColor = ColorPalette.nextUnused(excluding: Set(opts.map(\.color)))
            }
            opts.append(SelectOption(value: v, color: resolvedColor))
            prop.options = opts
            try AppDatabase.shared.savePropertyDefinition(&prop)
            notifyLibraryChanged()
            printJSON(PropertyDefinitionDTO(from: prop))
            return
        }

        if set {
            guard let refId = reference, let propId = id, let v = value else {
                printJSONError("--set requires --reference, --id, and --value")
                throw ExitCode.failure
            }
            let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
            guard let def = defs.first(where: { $0.id == propId }) else {
                printJSONError("Property \(propId) not found")
                throw ExitCode.failure
            }
            // Built-in properties back onto Reference fields, not the propertyValue table.
            // Writing a propertyValue row for them would appear to succeed but never render
            // in `get`/`list`/the UI. Redirect to `update` instead.
            if def.isDefault {
                printJSONError("Cannot --set built-in property '\(def.name)'. Use `rubien-cli update` for built-in fields.")
                throw ExitCode.failure
            }
            // multiSelect values are persisted as a JSON-encoded [String]; the UI
            // decoder silently returns [] for a raw scalar, so accept comma-separated
            // input here and encode before writing.
            let stored: String
            if def.type == .multiSelect {
                let values = v.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard let data = try? JSONEncoder().encode(values),
                      let json = String(data: data, encoding: .utf8) else {
                    printJSONError("Failed to encode multiSelect value")
                    throw ExitCode.failure
                }
                stored = json
            } else {
                stored = v
            }
            try AppDatabase.shared.setPropertyValue(referenceId: refId, propertyId: propId, value: stored)
            notifyLibraryChanged()
            printJSON(["referenceId": "\(refId)", "propertyId": "\(propId)", "value": stored])
            return
        }

        if clear {
            guard let refId = reference, let propId = id else {
                printJSONError("--clear requires --reference and --id")
                throw ExitCode.failure
            }
            let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
            guard let def = defs.first(where: { $0.id == propId }) else {
                printJSONError("Property \(propId) not found")
                throw ExitCode.failure
            }
            if def.isDefault {
                printJSONError("Cannot --clear built-in property '\(def.name)'. Use `rubien-cli update --clear-field <name>` for built-in fields.")
                throw ExitCode.failure
            }
            try AppDatabase.shared.setPropertyValue(referenceId: refId, propertyId: propId, value: nil)
            notifyLibraryChanged()
            printJSON(["cleared": "\(refId):\(propId)"])
            return
        }

        if let refId = reference {
            // List values set on this reference
            let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
            let defsById: [Int64: PropertyDefinition] = Dictionary(
                uniqueKeysWithValues: defs.compactMap { def in def.id.map { ($0, def) } }
            )
            let values = try AppDatabase.shared.fetchPropertyValues(forReference: refId)
            let dtos: [CustomPropertyValueDTO] = values.compactMap { v in
                guard let val = v.value, let def = defsById[v.propertyId] else { return nil }
                return CustomPropertyValueDTO(
                    propertyId: String(v.propertyId),
                    name: def.name,
                    type: def.type.rawValue,
                    value: val
                )
            }
            printJSON(dtos)
            return
        }

        // Default: list definitions
        let defs = visible
            ? try AppDatabase.shared.fetchVisiblePropertyDefinitions()
            : try AppDatabase.shared.fetchAllPropertyDefinitions()
        printJSON(defs.map(PropertyDefinitionDTO.init))
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

struct Annotations: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List PDF annotations for a reference")

    @Argument(help: "Reference ID")
    var referenceId: Int64

    func run() throws {
        let annotations = try AppDatabase.shared.fetchAnnotations(referenceId: referenceId)
        struct AnnotationDTO: Encodable {
            let id: Int64?
            let type: String
            let color: String
            let pageIndex: Int
            let selectedText: String?
            let noteText: String?
        }
        let dtos = annotations.map { a in
            AnnotationDTO(
                id: a.id,
                type: a.type.rawValue,
                color: a.color,
                pageIndex: a.pageIndex,
                selectedText: a.selectedText,
                noteText: a.noteText
            )
        }
        printJSON(dtos)
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
                case .journalArticle: entryType = "article"
                case .magazineArticle: entryType = "article"
                case .newspaperArticle: entryType = "article"
                case .preprint: entryType = "unpublished"
                case .book: entryType = "book"
                case .bookSection: entryType = "incollection"
                case .conferencePaper: entryType = "inproceedings"
                case .thesis: entryType = "phdthesis"
                case .dataset: entryType = "misc"
                case .software: entryType = "misc"
                case .standard: entryType = "misc"
                case .manuscript: entryType = "unpublished"
                case .interview: entryType = "misc"
                case .presentation: entryType = "misc"
                case .blogPost: entryType = "misc"
                case .forumPost: entryType = "misc"
                case .legalCase: entryType = "misc"
                case .legislation: entryType = "misc"
                case .webpage: entryType = "misc"
                case .report: entryType = "techreport"
                case .patent: entryType = "misc"
                case .other: entryType = "misc"
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
                case .journalArticle, .magazineArticle, .newspaperArticle: risType = "JOUR"
                case .book: risType = "BOOK"
                case .bookSection: risType = "CHAP"
                case .conferencePaper: risType = "CONF"
                case .thesis: risType = "THES"
                case .report: risType = "RPRT"
                case .patent: risType = "PAT"
                case .webpage, .blogPost, .forumPost: risType = "ELEC"
                case .preprint, .manuscript: risType = "UNPB"
                default: risType = "GEN"
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

    @Option(name: .long, help: "Execute a view's query and return matching references")
    var query: Int64?

    @Option(name: .shortAndLong, help: "Max results for --query (0 = all)")
    var limit: Int = 0

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
        } else if let queryId = query {
            guard let view = try db.fetchDatabaseView(id: queryId) else {
                printJSONError("View \(queryId) not found")
                throw ExitCode.failure
            }
            let scope: ReferenceScope
            switch view.parsedScope {
            case .all: scope = .all
            case .tag(let id): scope = .tag(id)
            }
            // Fast path: no filters/sorts/groupBy → push limit to SQL, skip engines.
            if view.parsedFilters.isEmpty && view.parsedSorts.isEmpty && view.parsedGroupBy == nil {
                let refs = try db.fetchReferences(scope: scope, filter: ReferenceFilter(), limit: limit)
                printJSON(try mapReferenceDTOs(refs))
                return
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
            let truncated = limit > 0 ? Array(sorted.prefix(limit)) : sorted
            printJSON(try mapReferenceDTOs(truncated))
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

struct Pdf: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "Inspect and extract content from a reference's attached PDF",
        subcommands: [PdfInfo.self, PdfText.self, PdfPageImage.self]
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

struct PdfTextOutput: Encodable {
    let id: Int64
    let pageCount: Int
    let selection: PDFExtractor.SelectionEcho
    let pages: [PDFExtractor.PageContent]
    let truncated: Bool
    let hasTextLayer: Bool
}

struct PdfText: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text",
        abstract: "Extract text from a reference's PDF by page range or section title"
    )

    @Argument(help: "Reference ID")
    var id: Int64

    @Option(
        name: .customLong("pages"),
        help: "Page range: e.g. 1-3, 1-3,8-10, 12-. Mutually exclusive with --section."
    )
    var pages: String?

    @Option(
        name: .customLong("section"),
        parsing: .singleValue,
        help: "Section title (case-insensitive substring match against the outline). Repeatable. Mutually exclusive with --pages."
    )
    var sections: [String] = []

    @Option(
        name: .customLong("max-chars"),
        help: "Cap total returned characters (default 50000)"
    )
    var maxChars: Int = 50_000

    func run() throws {
        if pages != nil && !sections.isEmpty {
            printJSONError("--pages and --section are mutually exclusive")
            throw ExitCode.failure
        }
        try runPdfSubcommand(referenceId: id) { url in
            let selection: PDFExtractor.Selection
            if !sections.isEmpty {
                selection = .sections(sections)
            } else if let pages, !pages.isEmpty {
                selection = .pagesString(pages)
            } else {
                selection = .allPages
            }
            let result = try PDFExtractor.extractText(at: url, selection: selection, maxChars: maxChars)
            return PdfTextOutput(
                id: id,
                pageCount: result.pageCount,
                selection: result.selection,
                pages: result.pages,
                truncated: result.truncated,
                hasTextLayer: result.hasTextLayer
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
