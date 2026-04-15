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
            Move.self,
            Cite.self,
            Import.self,
            Collections.self,
            Tags.self,
            Properties.self,
            Annotations.self,
            Styles.self,
            Export.self,
            Views.self,
        ]
    )
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
    let collectionId: Int64?
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
    let priority: Int
    let customProperties: [CustomPropertyValueDTO]

    init(from ref: Reference,
         defs: [PropertyDefinition] = [],
         valuesByRef: [Int64: [Int64: String]] = [:]) {
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
        self.collectionId = ref.collectionId
        self.dateAdded = ref.dateAdded
        self.dateModified = ref.dateModified
        self.pdfPath = ref.pdfPath
        self.notes = ref.notes
        self.isbn = ref.isbn
        self.issn = ref.issn
        self.publisher = ref.publisher
        self.language = ref.language
        self.edition = ref.edition
        self.readingStatus = ref.readingStatus.rawValue
        self.priority = ref.priority.rawValue

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
func mapReferenceDTOs(_ refs: [Reference]) throws -> [ReferenceDTO] {
    guard !refs.isEmpty else { return [] }
    let defs = try AppDatabase.shared.fetchAllPropertyDefinitions()
    let refIds = refs.compactMap(\.id)
    let valuesByRef = try AppDatabase.shared.fetchPropertyValues(forReferences: refIds)
    return refs.map { ReferenceDTO(from: $0, defs: defs, valuesByRef: valuesByRef) }
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
    return ReferenceDTO(from: ref, defs: defs, valuesByRef: valuesByRef)
}

// MARK: - Subcommands

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Full-text search across the library")

    @Argument(help: "Search query")
    var query: String

    @Option(name: .shortAndLong, help: "Maximum number of results")
    var limit: Int = 20

    func run() throws {
        let refs = try AppDatabase.shared.searchReferences(query: query, limit: limit)
        printJSON(try mapReferenceDTOs(refs))
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List references")

    @Option(name: .shortAndLong, help: "Maximum number of results (0 = all)")
    var limit: Int = 0

    @Option(name: .long, help: "Skip the first N results (pagination)")
    var offset: Int = 0

    @Option(name: .long, help: "Filter by collection ID")
    var collection: Int64?

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

    @Option(name: .long, help: "Filter by priority (0=none, 1=low, 2=medium, 3=high)")
    var priority: Int?

    @Option(name: .customLong("sort-by"), help: "Sort by field (year, dateAdded, priority, title)")
    var sortBy: String?

    @Flag(name: .long, help: "Sort ascending (default is descending)")
    var asc = false

    func run() throws {
        let hasAdvancedFilter = author != nil || yearFrom != nil || yearTo != nil
            || journal != nil || referenceType != nil || hasPdf || keyword != nil
            || readingStatus != nil || priority != nil
        var refs: [Reference]
        if hasAdvancedFilter {
            let scope: ReferenceScope = collection.map { .collection($0) }
                ?? tag.map { .tag($0) } ?? .all
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
            if let p = priority {
                guard let prio = Priority(rawValue: p) else {
                    printJSONError("Unknown priority '\(p)'. Valid: 0 (none), 1 (low), 2 (medium), 3 (high)")
                    throw ExitCode.failure
                }
                filter.priority = prio
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
        } else if let cid = collection {
            refs = try AppDatabase.shared.fetchReferences(collectionId: cid)
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

    @Option(name: .long, help: "Add to the given collection ID")
    var collection: Int64?

    func run() async throws {
        if let id = identifier {
            var ref = try await MetadataFetcher.fetch(from: id)
            ref.collectionId = collection
            ref = MetadataVerifier.manuallyVerified(ref, reviewedBy: "cli-identifier")
            try AppDatabase.shared.saveReference(&ref)
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
                ref.collectionId = collection
                try AppDatabase.shared.saveReference(&ref)
                saved.append(ref)
            }
            printJSON(try mapReferenceDTOs(saved))
        } else if let t = title {
            var ref = Reference(title: t)
            ref.collectionId = collection
            try AppDatabase.shared.saveReference(&ref)
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

    @Option(name: .long, help: "Move to the given collection ID")
    var collection: Int64?

    @Option(name: .customLong("clear-field"), help: "Clear a single field (repeatable, e.g. --clear-field doi)")
    var clearFields: [String] = []

    @Option(name: .customLong("reading-status"), help: "Set reading status (unread, reading, skimmed, read)")
    var readingStatus: String?

    @Option(name: .long, help: "Set priority (0=none, 1=low, 2=medium, 3=high)")
    var priority: Int?

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
        if let p = priority {
            guard let prio = Priority(rawValue: p) else {
                printJSONError("Unknown priority '\(p)'. Valid: 0 (none), 1 (low), 2 (medium), 3 (high)")
                throw ExitCode.failure
            }
            ref.priority = prio
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
        if let cid = collection { ref.collectionId = cid }
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
            case "collection": ref.collectionId = nil
            default:
                printJSONError("Unknown field '\(field)'. Valid: year, journal, volume, issue, pages, doi, url, abstract, notes, publisher, isbn, issn, language, edition, collection")
                throw ExitCode.failure
            }
        }
        try AppDatabase.shared.saveReference(&ref)
        printJSON(try referenceDTO(for: ref))
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete references by ID, or bulk-delete a collection")

    @Argument(help: "Reference IDs to delete (omit when using --collection for bulk deletion)")
    var ids: [Int64] = []

    @Flag(name: .shortAndLong, help: "Skip the confirmation prompt")
    var force = false

    @Option(name: .long, help: "Delete every reference in the given collection ID")
    var collection: Int64?

    @Flag(name: .customLong("delete-collection"), help: "Also delete the collection itself (with --collection)")
    var deleteCollection = false

    func run() throws {
        if let cid = collection, ids.isEmpty {
            // Bulk delete all references in the given collection
            let refs = try AppDatabase.shared.fetchReferences(collectionId: cid)
            let refIds = refs.compactMap(\.id)
            if !force && isatty(STDIN_FILENO) != 0 {
                let msg = "Delete \(refs.count) reference(s) in collection \(cid)" +
                    (deleteCollection ? " and delete the collection itself" : "") + "? [y/N] "
                FileHandle.standardError.write(Data(msg.utf8))
                guard let line = readLine(), line.lowercased().hasPrefix("y") else {
                    printJSONError("Aborted")
                    throw ExitCode.failure
                }
            }
            if !refIds.isEmpty {
                let pdfPaths = try AppDatabase.shared.deleteReferencesReturningPDFPaths(ids: refIds)
                for path in pdfPaths { PDFService.deletePDF(at: path) }
            }
            if deleteCollection {
                try AppDatabase.shared.deleteCollection(id: cid)
            }
            var result: [String: String] = ["deletedReferences": "\(refIds.count)"]
            if deleteCollection { result["deletedCollection"] = "\(cid)" }
            printJSON(result)
        } else if !ids.isEmpty {
            if !force && isatty(STDIN_FILENO) != 0 {
                FileHandle.standardError.write(Data("Delete \(ids.count) reference(s) and associated PDFs? [y/N] ".utf8))
                guard let line = readLine(), line.lowercased().hasPrefix("y") else {
                    printJSONError("Aborted")
                    throw ExitCode.failure
                }
            }
            let pdfPaths = try AppDatabase.shared.deleteReferencesReturningPDFPaths(ids: ids)
            for path in pdfPaths { PDFService.deletePDF(at: path) }
            printJSON(["deleted": ids.map(String.init).joined(separator: ",")])
        } else {
            printJSONError("Provide reference IDs as arguments, or --collection <id> for bulk deletion")
            throw ExitCode.failure
        }
    }
}

struct Move: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Move references into a collection")

    @Argument(help: "Reference IDs to move")
    var ids: [Int64]

    @Option(name: .long, help: "Target collection ID")
    var collection: Int64?

    @Flag(name: .long, help: "Remove from all collections (move to unfiled)")
    var remove = false

    func run() throws {
        let targetId: Int64?
        if remove {
            targetId = nil
        } else if let cid = collection {
            targetId = cid
        } else {
            printJSONError("Provide --collection <id> to move into a collection, or --remove to uncategorise")
            throw ExitCode.failure
        }
        try AppDatabase.shared.moveReferences(ids: ids, toCollectionId: targetId)
        printJSON([
            "moved": ids.map(String.init).joined(separator: ","),
            "toCollection": targetId.map(String.init) ?? "none",
        ])
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
        abstract: "Import references from a BibTeX or RIS file (use '-' for stdin)"
    )

    @Argument(help: "Path to a .bib or .ris file, or '-' to read from stdin")
    var file: String

    @Option(name: .long, help: "Import into the given collection ID")
    var collection: Int64?

    @Option(name: .long, help: "Format hint when reading from stdin: bib, ris")
    var format: String?

    func run() throws {
        let content: String
        let ext: String

        if file == "-" {
            // Read from stdin
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
            // Guard against excessively large files (50 MB limit)
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

        if let cid = collection {
            for i in refs.indices { refs[i].collectionId = cid }
        }

        let count = try AppDatabase.shared.batchImportReferences(refs)
        printJSON(["imported": "\(count)", "file": file])
    }
}

struct Collections: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List or manage collections")

    @Flag(name: .long, help: "Create a new collection")
    var create = false

    @Option(name: .long, help: "Collection name (with --create or --rename)")
    var name: String?

    @Option(name: .long, help: "Delete a collection by ID (its references are kept)")
    var delete: Int64?

    @Flag(name: .customLong("with-references"), help: "Also delete all references and PDFs inside the collection")
    var withReferences = false

    @Flag(name: .shortAndLong, help: "Skip the confirmation prompt for destructive actions")
    var force = false

    @Flag(name: .long, help: "Rename a collection")
    var rename = false

    @Option(name: .long, help: "Collection ID (with --rename)")
    var id: Int64?

    func run() throws {
        if let deleteId = delete {
            if withReferences {
                let refs = try AppDatabase.shared.fetchReferences(collectionId: deleteId)
                let refIds = refs.compactMap(\.id)
                if !force && isatty(STDIN_FILENO) != 0 {
                    let msg = "Delete collection \(deleteId), \(refIds.count) reference(s), and associated PDFs? [y/N] "
                    FileHandle.standardError.write(Data(msg.utf8))
                    guard let line = readLine(), line.lowercased().hasPrefix("y") else {
                        printJSONError("Aborted")
                        throw ExitCode.failure
                    }
                }
                if !refIds.isEmpty {
                    let pdfPaths = try AppDatabase.shared.deleteReferencesReturningPDFPaths(ids: refIds)
                    for path in pdfPaths { PDFService.deletePDF(at: path) }
                }
                try AppDatabase.shared.deleteCollection(id: deleteId)
                printJSON(["deletedCollection": "\(deleteId)", "deletedReferences": "\(refIds.count)"])
            } else {
                try AppDatabase.shared.deleteCollection(id: deleteId)
                printJSON(["deleted": "\(deleteId)"])
            }
        } else if create, let n = name {
            var c = Collection(name: n)
            try AppDatabase.shared.saveCollection(&c)
            printJSON(["id": c.id.map(String.init) ?? "", "name": c.name])
        } else if rename, let cid = id, let n = name {
            let all = try AppDatabase.shared.fetchAllCollections()
            guard var col = all.first(where: { $0.id == cid }) else {
                printJSONError("Collection \(cid) not found")
                throw ExitCode.failure
            }
            col.name = n
            try AppDatabase.shared.saveCollection(&col)
            printJSON(["id": col.id.map(String.init) ?? "", "name": col.name])
        } else {
            let collections = try AppDatabase.shared.fetchAllCollections()
            let dtos = collections.map { c in
                ["id": c.id.map(String.init) ?? "", "name": c.name, "icon": c.icon]
            }
            printJSON(dtos)
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
            printJSON(["deleted": "\(deleteId)"])
        } else if create, let n = name {
            let resolvedColor: String
            if let c = color {
                resolvedColor = c
            } else {
                let existing = try AppDatabase.shared.fetchAllTags()
                let usedColors = Set(existing.map(\.color))
                resolvedColor = Tag.colorPalette.first { !usedColors.contains($0) }
                    ?? Tag.colorPalette.randomElement() ?? Tag.colorPalette[0]
            }
            var t = Tag(name: n, color: resolvedColor)
            try AppDatabase.shared.saveTag(&t)
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
            printJSON(PropertyDefinitionDTO(from: prop))
            return
        }

        if show || hide {
            guard let propId = id else {
                printJSONError("--show / --hide requires --id")
                throw ExitCode.failure
            }
            try AppDatabase.shared.togglePropertyVisibility(id: propId, visible: show)
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
                let used = Set(opts.map(\.color))
                resolvedColor = SelectOption.colorPalette.first { !used.contains($0) }
                    ?? SelectOption.colorPalette.randomElement() ?? SelectOption.colorPalette[0]
            }
            opts.append(SelectOption(value: v, color: resolvedColor))
            prop.options = opts
            try AppDatabase.shared.savePropertyDefinition(&prop)
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
            let color = SelectOption.colorPalette.first { !used.contains($0) }
                ?? SelectOption.colorPalette.randomElement() ?? SelectOption.colorPalette[0]
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

    @Option(name: .long, help: "Filter by collection ID")
    var collection: Int64?

    func run() throws {
        let refs: [Reference]
        if let cid = collection {
            refs = try AppDatabase.shared.fetchReferences(collectionId: cid)
        } else {
            refs = try AppDatabase.shared.fetchAllReferences()
        }

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

    func run() throws {
        let db = AppDatabase.shared

        if create {
            guard let viewName = name else {
                printJSONError("--name is required with --create")
                throw ExitCode.failure
            }
            let parsedFilters: [ViewFilter] = {
                guard let json = filters, let data = json.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([ViewFilter].self, from: data) else { return [] }
                return decoded
            }()
            let parsedSorts: [ViewSort] = {
                guard let json = sorts, let data = json.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([ViewSort].self, from: data) else { return [.defaultSort] }
                return decoded
            }()
            let existing = try db.fetchAllDatabaseViews()
            let maxOrder = existing.map(\.displayOrder).max() ?? 0
            var view = DatabaseView(
                name: viewName,
                filters: parsedFilters,
                sorts: parsedSorts,
                displayOrder: maxOrder + 1
            )
            try db.saveDatabaseView(&view)
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
            printJSON(["deleted": deleteId])
        } else if let queryId = query {
            guard let view = try db.fetchDatabaseView(id: queryId) else {
                printJSONError("View \(queryId) not found")
                throw ExitCode.failure
            }
            let scope: ReferenceScope
            switch view.parsedScope {
            case .all: scope = .all
            case .collection(let id): scope = .collection(id)
            case .tag(let id): scope = .tag(id)
            }
            let refs = try db.fetchReferences(scope: scope, filter: ReferenceFilter(), limit: limit)
            printJSON(try mapReferenceDTOs(refs))
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
            printJSON(DatabaseViewDTO(from: view))
        } else {
            let views = try db.fetchAllDatabaseViews()
            printJSON(views.map(DatabaseViewDTO.init))
        }
    }
}

struct DatabaseViewDTO: Encodable {
    let id: Int64?
    let name: String
    let icon: String
    let isDefault: Bool
    let displayOrder: Int
    let scope: String
    let filters: String
    let sorts: String
    let dateCreated: Date
    let dateModified: Date

    init(from view: DatabaseView) {
        self.id = view.id
        self.name = view.name
        self.icon = view.icon
        self.isDefault = view.isDefault
        self.displayOrder = view.displayOrder
        self.scope = view.scopeJSON
        self.filters = view.filtersJSON
        self.sorts = view.sortsJSON
        self.dateCreated = view.dateCreated
        self.dateModified = view.dateModified
    }
}
