import Foundation
import GRDB

public enum ReferenceExportFormat: String, CaseIterable, Sendable {
    case json
    case bibtex
    case ris

    public var filenameExtension: String {
        switch self {
        case .json: "json"
        case .bibtex: "bib"
        case .ris: "ris"
        }
    }

    public var mediaType: String {
        switch self {
        case .json: "application/json"
        case .bibtex: "application/x-bibtex"
        case .ris: "application/x-research-info-systems"
        }
    }
}

public enum ReferenceExportScope: Sendable, Equatable {
    case all
    case ids([Int64])
    case savedView(Int64)
}

public struct ReferenceExportRequest: Sendable, Equatable {
    public let format: ReferenceExportFormat
    public let scope: ReferenceExportScope

    public init(format: ReferenceExportFormat, scope: ReferenceExportScope) {
        self.format = format
        self.scope = scope
    }
}

public struct ReferenceExportArtifact: Sendable, Equatable {
    public let format: ReferenceExportFormat
    public let data: Data
    public let referenceCount: Int

    public var filenameExtension: String { format.filenameExtension }
    public var mediaType: String { format.mediaType }

    init(
        format: ReferenceExportFormat,
        data: Data,
        referenceCount: Int
    ) {
        self.format = format
        self.data = data
        self.referenceCount = referenceCount
    }
}

public enum ReferenceExportError: Error, Equatable, Sendable, LocalizedError {
    case emptySelection
    case unresolvedReferenceIDs([Int64])
    case savedViewNotFound(Int64)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            "At least one reference ID is required"
        case .unresolvedReferenceIDs(let ids):
            "References not found: \(ids.map(String.init).joined(separator: ", "))"
        case .savedViewNotFound(let id):
            "View \(id) not found"
        }
    }
}

public struct ReferenceExportService: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func export(_ request: ReferenceExportRequest) throws -> ReferenceExportArtifact {
        let snapshot = try database.referenceExportSnapshot(for: request)
        let data: Data
        switch request.format {
        case .json:
            data = try ReferenceJSONExportEncoder.encode(
                snapshot.references,
                propertyDefinitions: snapshot.propertyDefinitions,
                propertyValues: snapshot.propertyValues,
                pdfFilenames: snapshot.pdfFilenames
            )
        case .bibtex:
            let keys = BibTeXCitationKeys.make(for: snapshot.citationIdentities)
            data = ReferenceBibTeXEncoder.encode(snapshot.references, citationKeys: keys)
        case .ris:
            data = ReferenceRISEncoder.encode(snapshot.references)
        }
        return ReferenceExportArtifact(
            format: request.format,
            data: data,
            referenceCount: snapshot.references.count
        )
    }
}

private struct ReferenceExportSnapshot {
    let references: [Reference]
    let propertyDefinitions: [PropertyDefinition]
    let propertyValues: [Int64: [Int64: String]]
    let pdfFilenames: [Int64: String]
    let citationIdentities: [BibTeXCitationIdentity]
}

private struct BibTeXCitationIdentity {
    let id: Int64
    let firstAuthorFamily: String?
    let year: Int?

    init(reference: Reference) {
        id = reference.id ?? 0
        firstAuthorFamily = reference.authors.first?.family
        year = reference.year
    }

    init(row: Row) {
        id = row["id"]
        let rawAuthors: String = row["authors"]
        if let data = rawAuthors.data(using: .utf8),
           let authors = try? JSONDecoder().decode([AuthorName].self, from: data) {
            firstAuthorFamily = authors.first?.family
        } else {
            firstAuthorFamily = AuthorName.parseList(rawAuthors).first?.family
        }
        year = row["year"]
    }
}

extension AppDatabase {
    /// Runs saved-view scope/filter/sort resolution in one database snapshot.
    public func fetchReferences(
        savedViewID: Int64,
        limit: Int = 0,
        offset: Int = 0
    ) throws -> [Reference] {
        try dbWriter.read { db in
            guard let view = try DatabaseView.fetchOne(db, id: savedViewID) else {
                throw ReferenceExportError.savedViewNotFound(savedViewID)
            }
            return try Self.resolveSavedView(
                view,
                db: db,
                limit: limit,
                offset: offset
            )
        }
    }

    fileprivate func referenceExportSnapshot(
        for request: ReferenceExportRequest
    ) throws -> ReferenceExportSnapshot {
        try dbWriter.read { db in
            let references = try Self.resolveExportScope(request.scope, db: db)
            let referenceIDs = references.compactMap(\.id)

            let propertyDefinitions: [PropertyDefinition]
            let propertyValues: [Int64: [Int64: String]]
            let pdfFilenames: [Int64: String]
            if request.format == .json {
                propertyDefinitions = try PropertyDefinition
                    .order(PropertyDefinition.Columns.sortOrder)
                    .fetchAll(db)
                propertyValues = try Self.loadPropertyValues(db: db, referenceIDs: referenceIDs)
                pdfFilenames = try Self.loadPDFFilenames(db: db, referenceIDs: referenceIDs)
            } else {
                propertyDefinitions = []
                propertyValues = [:]
                pdfFilenames = [:]
            }

            let citationIdentities: [BibTeXCitationIdentity]
            if request.format == .bibtex {
                if case .all = request.scope {
                    citationIdentities = references.map(BibTeXCitationIdentity.init(reference:))
                } else {
                    citationIdentities = try Self.loadCitationIdentities(db: db)
                }
            } else {
                citationIdentities = []
            }

            return ReferenceExportSnapshot(
                references: references,
                propertyDefinitions: propertyDefinitions,
                propertyValues: propertyValues,
                pdfFilenames: pdfFilenames,
                citationIdentities: citationIdentities
            )
        }
    }

    private static func resolveExportScope(
        _ scope: ReferenceExportScope,
        db: Database
    ) throws -> [Reference] {
        switch scope {
        case .all:
            return try loadAllReferences(db: db)
        case .ids(let ids):
            let orderedIDs = stableUnique(ids)
            guard !orderedIDs.isEmpty else {
                throw ReferenceExportError.emptySelection
            }
            let references = try loadReferences(db: db, ids: orderedIDs)
            let found = Set(references.compactMap(\.id))
            let missing = orderedIDs.filter { !found.contains($0) }
            guard missing.isEmpty else {
                throw ReferenceExportError.unresolvedReferenceIDs(missing)
            }
            return references
        case .savedView(let id):
            guard let view = try DatabaseView.fetchOne(db, id: id) else {
                throw ReferenceExportError.savedViewNotFound(id)
            }
            return try resolveSavedView(view, db: db, limit: 0, offset: 0)
        }
    }

    private static func resolveSavedView(
        _ view: DatabaseView,
        db: Database,
        limit: Int,
        offset rawOffset: Int
    ) throws -> [Reference] {
        let offset = max(0, rawOffset)
        let isPlainView = view.parsedFilters.isEmpty
            && view.parsedSorts.isEmpty
            && view.parsedGroupBy == nil
        if isPlainView {
            let fetchLimit: Int
            if limit > 0 {
                let (sum, overflow) = limit.addingReportingOverflow(offset)
                fetchLimit = overflow ? 0 : sum
            } else {
                fetchLimit = 0
            }
            let candidates = try loadReferences(
                db: db,
                scope: view.parsedScope,
                limit: fetchLimit
            )
            let dropped = offset > 0 ? Array(candidates.dropFirst(offset)) : candidates
            return limit > 0 ? Array(dropped.prefix(limit)) : dropped
        }

        let candidates = try loadReferences(db: db, scope: view.parsedScope, limit: 0)
        let candidateIDs = candidates.compactMap(\.id)
        let context = PipelineContext(
            tagMap: try loadReferenceTagMappings(db: db, referenceIDs: candidateIDs),
            propertyValueMap: try loadPropertyValues(db: db, referenceIDs: candidateIDs),
            propertyDefs: try PropertyDefinition
                .order(PropertyDefinition.Columns.sortOrder)
                .fetchAll(db),
            pdfAttachedRefIds: try loadPDFAttachedReferenceIDs(
                db: db,
                referenceIDs: candidateIDs
            )
        )
        let filtered = FilterEngine.apply(
            candidates,
            filters: view.parsedFilters,
            context: context
        )
        let resolved = SortEngine.apply(filtered, sorts: view.parsedSorts, context: context)

        let dropped = offset > 0 ? Array(resolved.dropFirst(offset)) : resolved
        return limit > 0 ? Array(dropped.prefix(limit)) : dropped
    }

    private static func loadAllReferences(db: Database) throws -> [Reference] {
        try loadReferences(db: db, scope: .all, limit: 0)
    }

    private static func loadReferences(
        db: Database,
        scope: ViewScope,
        limit: Int
    ) throws -> [Reference] {
        var request: QueryInterfaceRequest<Reference>
        switch scope {
        case .all:
            request = Reference.all()
        case .tag(let tagID):
            request = Reference.joining(
                required: Reference.referenceTagPivot
                    .filter(ReferenceTag.Columns.tagId == tagID)
            )
        }
        request = request
            .select(Reference.lightColumns)
            .order(Reference.Columns.dateAdded.desc, Reference.Columns.id.asc)
        if limit > 0 { request = request.limit(limit) }
        return try request.fetchAll(db)
    }

    private static func loadReferences(db: Database, ids: [Int64]) throws -> [Reference] {
        var byID: [Int64: Reference] = [:]
        for chunk in ids.chunkedForExport() {
            let rows = try Reference
                .filter(chunk.contains(Reference.Columns.id))
                .select(Reference.lightColumns)
                .fetchAll(db)
            for row in rows {
                if let id = row.id { byID[id] = row }
            }
        }
        return ids.compactMap { byID[$0] }
    }

    private static func loadReferenceTagMappings(
        db: Database,
        referenceIDs: [Int64]
    ) throws -> [Int64: [Tag]] {
        var map: [Int64: [Tag]] = [:]
        for chunk in referenceIDs.chunkedForExport() {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT rt.referenceId, t.id, t.name, t.color
                FROM referenceTag rt
                JOIN tag t ON t.id = rt.tagId
                WHERE rt.referenceId IN (\(placeholders))
                ORDER BY t.name
                """, arguments: StatementArguments(chunk))
            for row in rows {
                let referenceID: Int64 = row["referenceId"]
                map[referenceID, default: []].append(
                    Tag(id: row["id"], name: row["name"], color: row["color"])
                )
            }
        }
        return map
    }

    private static func loadPropertyValues(
        db: Database,
        referenceIDs: [Int64]
    ) throws -> [Int64: [Int64: String]] {
        var map: [Int64: [Int64: String]] = [:]
        for chunk in referenceIDs.chunkedForExport() {
            let rows = try PropertyValue
                .filter(chunk.contains(PropertyValue.Columns.referenceId))
                .fetchAll(db)
            for row in rows {
                if let value = row.value {
                    map[row.referenceId, default: [:]][row.propertyId] = value
                }
            }
        }
        return map
    }

    private static func loadPDFFilenames(
        db: Database,
        referenceIDs: [Int64]
    ) throws -> [Int64: String] {
        var result: [Int64: String] = [:]
        for chunk in referenceIDs.chunkedForExport() {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT referenceId, localFilename
                FROM pdfCache
                WHERE referenceId IN (\(placeholders))
                  AND materializedAt IS NOT NULL
                """, arguments: StatementArguments(chunk))
            for row in rows {
                result[row["referenceId"]] = row["localFilename"]
            }
        }
        return result
    }

    private static func loadPDFAttachedReferenceIDs(
        db: Database,
        referenceIDs: [Int64]
    ) throws -> Set<Int64> {
        var result = Set<Int64>()
        for chunk in referenceIDs.chunkedForExport() {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            result.formUnion(try Int64.fetchAll(
                db,
                sql: "SELECT referenceId FROM pdfCache WHERE referenceId IN (\(placeholders))",
                arguments: StatementArguments(chunk)
            ))
        }
        return result
    }

    private static func loadCitationIdentities(db: Database) throws -> [BibTeXCitationIdentity] {
        try Row.fetchAll(db, sql: """
            SELECT id, authors, year
            FROM reference
            ORDER BY dateAdded DESC, id ASC
            """).map(BibTeXCitationIdentity.init(row:))
    }

    private static func stableUnique(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { seen.insert($0).inserted }
    }
}

private extension Array where Element == Int64 {
    func chunkedForExport(size: Int = 500) -> [[Int64]] {
        guard !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

enum ReferenceJSONExportEncoder {
    static func encode(
        _ references: [Reference],
        propertyDefinitions: [PropertyDefinition],
        propertyValues: [Int64: [Int64: String]],
        pdfFilenames: [Int64: String]
    ) throws -> Data {
        let values = references.map {
            ReferenceDTO(
                from: $0,
                defs: propertyDefinitions,
                valuesByRef: propertyValues,
                pdfFilenamesByRef: pdfFilenames
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(values)
        data.append(0x0A)
        return data
    }
}

private enum BibTeXCitationKeys {
    static func make(for identities: [BibTeXCitationIdentity]) -> [Int64: String] {
        let bases = identities.map(baseKey(for:))
        let counts = Dictionary(grouping: bases.map(asciiLowercased), by: { $0 })
            .mapValues(\.count)
        var offsets: [String: Int] = [:]
        var result: [Int64: String] = [:]

        for (identity, base) in zip(identities, bases) {
            let canonical = asciiLowercased(base)
            guard counts[canonical, default: 0] > 1 else {
                result[identity.id] = base
                continue
            }
            let offset = offsets[canonical, default: 0]
            offsets[canonical] = offset + 1
            result[identity.id] = base + suffix(offset)
        }
        return result
    }

    private static func baseKey(for identity: BibTeXCitationIdentity) -> String {
        let family = identity.firstAuthorFamily.map(sanitizeFamily) ?? "unknown"
        let year = identity.year.flatMap { (1000...9999).contains($0) ? $0 : nil } ?? 0
        return "\(family)\(year)"
    }

    private static func sanitizeFamily(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122)
        }
        let result = String(String.UnicodeScalarView(scalars))
        return result.isEmpty ? "unknown" : result
    }

    private static func asciiLowercased(_ value: String) -> String {
        String(value.utf8.map { byte in
            (65...90).contains(byte) ? Character(UnicodeScalar(byte + 32)) : Character(UnicodeScalar(byte))
        })
    }

    private static func suffix(_ zeroBasedIndex: Int) -> String {
        var value = zeroBasedIndex + 1
        var characters: [Character] = []
        while value > 0 {
            value -= 1
            characters.append(Character(UnicodeScalar(97 + value % 26)!))
            value /= 26
        }
        return String(characters.reversed())
    }
}

enum ReferenceBibTeXEncoder {
    static func encode(_ references: [Reference], citationKeys: [Int64: String]) -> Data {
        var output = ""
        for reference in references {
            if !output.isEmpty { output.append("\n\n") }
            output.append(entry(
                reference,
                citationKey: reference.id.flatMap { citationKeys[$0] } ?? "unknown0"
            ))
        }
        if !output.isEmpty { output.append("\n") }
        return Data(output.utf8)
    }

    private static func entry(_ reference: Reference, citationKey: String) -> String {
        var lines = ["@\(entryType(reference)){\(citationKey),"]
        lines.append("  title = {{\(escape(reference.title))}},")
        appendNames(reference.authors, field: "author", to: &lines)
        appendNames(reference.parsedEditors, field: "editor", to: &lines)
        appendNames(reference.parsedTranslators, field: "translator", to: &lines)
        if let year = reference.year { append(String(year), field: "year", to: &lines) }
        if let month = reference.issuedMonth, (1...12).contains(month) {
            lines.append("  month = \(monthNames[month - 1]),")
        }
        if reference.referenceType == .journalArticle {
            append(reference.journal, field: "journal", to: &lines)
        }
        if reference.referenceType == .conferencePaper {
            append(reference.eventTitle, field: "booktitle", to: &lines)
        }
        append(reference.volume, field: "volume", to: &lines)
        append(
            reference.referenceType == .journalArticle ? reference.issue : reference.number,
            field: "number",
            to: &lines
        )
        append(reference.pages, field: "pages", to: &lines)
        append(reference.publisher, field: "publisher", to: &lines)
        let address = nonempty(reference.publisherPlace)
            ?? (reference.referenceType == .conferencePaper
                ? nonempty(reference.eventPlace) : nil)
        append(address, field: "address", to: &lines)
        append(reference.edition, field: "edition", to: &lines)
        if reference.referenceType == .thesis {
            append(reference.institution, field: "school", to: &lines)
        }
        append(reference.collectionTitle, field: "series", to: &lines)
        append(reference.isbn, field: "isbn", to: &lines)
        append(reference.issn, field: "issn", to: &lines)
        append(reference.doi, field: "doi", to: &lines)
        append(reference.url, field: "url", to: &lines)
        append(reference.accessedDate, field: "urldate", to: &lines)
        append(reference.language, field: "language", to: &lines)
        append(reference.pmid, field: "pmid", to: &lines)
        append(reference.pmcid, field: "pmcid", to: &lines)
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func entryType(_ reference: Reference) -> String {
        switch reference.referenceType {
        case .journalArticle: "article"
        case .conferencePaper: "inproceedings"
        case .book: "book"
        case .thesis:
            reference.genre?.localizedCaseInsensitiveContains("master") == true
                ? "mastersthesis" : "phdthesis"
        case .webpage, .markdown, .other: "misc"
        }
    }

    private static func appendNames(
        _ names: [AuthorName],
        field: String,
        to lines: inout [String]
    ) {
        let value = names
            .map { $0.given.isEmpty ? $0.family : "\($0.family), \($0.given)" }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " and ")
        append(value, field: field, to: &lines)
    }

    private static func append(_ value: String?, field: String, to lines: inout [String]) {
        guard let value = nonempty(value) else { return }
        lines.append("  \(field) = {\(escape(value))},")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func escape(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for character in value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n") {
            switch character {
            case "\\": output += "\\textbackslash{}"
            case "{": output += "\\{"
            case "}": output += "\\}"
            case "&": output += "\\&"
            case "%": output += "\\%"
            case "#": output += "\\#"
            case "_": output += "\\_"
            case "~": output += "\\textasciitilde{}"
            case "^": output += "\\textasciicircum{}"
            default: output.append(character)
            }
        }
        return output
    }

    private static let monthNames = [
        "jan", "feb", "mar", "apr", "may", "jun",
        "jul", "aug", "sep", "oct", "nov", "dec",
    ]
}

enum ReferenceRISEncoder {
    static func encode(_ references: [Reference]) -> Data {
        var output = ""
        for reference in references {
            if !output.isEmpty { output.append("\n") }
            output.append(record(reference))
        }
        if !output.isEmpty { output.append("\n") }
        return Data(output.utf8)
    }

    private static func record(_ reference: Reference) -> String {
        var lines = ["TY  - \(type(reference.referenceType))"]
        append(reference.title, tag: "TI", to: &lines)
        for author in reference.authors { append(name(author), tag: "AU", to: &lines) }
        for editor in reference.parsedEditors { append(name(editor), tag: "ED", to: &lines) }
        if let year = reference.year { append(String(year), tag: "PY", to: &lines) }
        if let year = reference.year,
           let month = reference.issuedMonth, (1...12).contains(month),
           let day = reference.issuedDay, (1...31).contains(day) {
            append(String(format: "%04d/%02d/%02d", year, month, day), tag: "DA", to: &lines)
        }
        append(reference.journal, tag: "JO", to: &lines)
        switch reference.referenceType {
        case .conferencePaper: append(reference.eventTitle, tag: "T2", to: &lines)
        case .book: append(reference.collectionTitle, tag: "T2", to: &lines)
        default: break
        }
        append(reference.volume, tag: "VL", to: &lines)
        append(reference.issue, tag: "IS", to: &lines)
        appendPages(reference.pages, to: &lines)
        append(reference.doi, tag: "DO", to: &lines)
        append(reference.url, tag: "UR", to: &lines)
        append(reference.isbn, tag: "SN", to: &lines)
        append(reference.issn, tag: "SN", to: &lines)
        append(reference.publisher, tag: "PB", to: &lines)
        append(nonempty(reference.publisherPlace) ?? nonempty(reference.eventPlace), tag: "CY", to: &lines)
        append(reference.edition, tag: "ET", to: &lines)
        append(reference.abstract, tag: "AB", to: &lines)
        append(reference.language, tag: "LA", to: &lines)
        if let pmid = nonempty(reference.pmid) { append("PMID: \(pmid)", tag: "N1", to: &lines) }
        if let pmcid = nonempty(reference.pmcid) { append("PMCID: \(pmcid)", tag: "N1", to: &lines) }
        append(reference.accessedDate, tag: "Y2", to: &lines)
        lines.append("ER  -")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func type(_ referenceType: ReferenceType) -> String {
        switch referenceType {
        case .journalArticle: "JOUR"
        case .conferencePaper: "CONF"
        case .book: "BOOK"
        case .thesis: "THES"
        case .webpage: "ELEC"
        case .markdown, .other: "GEN"
        }
    }

    private static func name(_ author: AuthorName) -> String {
        author.given.isEmpty ? author.family : "\(author.family), \(author.given)"
    }

    private static func appendPages(_ pages: String?, to lines: inout [String]) {
        guard let pages = nonempty(pages) else { return }
        for delimiter in ["--", "–", "—", "-"] {
            if let range = pages.range(of: delimiter) {
                append(String(pages[..<range.lowerBound]), tag: "SP", to: &lines)
                append(String(pages[range.upperBound...]), tag: "EP", to: &lines)
                return
            }
        }
        append(pages, tag: "SP", to: &lines)
    }

    private static func append(_ value: String?, tag: String, to lines: inout [String]) {
        guard let value = nonempty(value) else { return }
        let safe = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        lines.append("\(tag)  - \(safe)")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
