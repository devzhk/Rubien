import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RubienCore

/// A collection in the current user's Zotero desktop library.
public struct ZoteroLibraryCollection: Identifiable, Hashable, Sendable {
    public var id: String { key }

    public let key: String
    public let name: String
    public let parentKey: String?
    /// Number of items directly in this collection. Subcollections are not included.
    public let itemCount: Int
    public let childCollectionCount: Int

    public init(
        key: String,
        name: String,
        parentKey: String?,
        itemCount: Int,
        childCollectionCount: Int
    ) {
        self.key = key
        self.name = name
        self.parentKey = parentKey
        self.itemCount = itemCount
        self.childCollectionCount = childCollectionCount
    }
}

public struct ZoteroLibraryCollectionRow: Identifiable, Equatable, Sendable {
    public var id: String { collection.key }

    public let collection: ZoteroLibraryCollection
    public let depth: Int
    public let path: String
}

/// Lightweight paper metadata used only to preview a collection before the
/// user chooses its import scope. Full BibTeX and annotation data remain lazy
/// until import preparation begins.
public struct ZoteroLibraryItemSummary: Identifiable, Equatable, Sendable {
    public var id: String { key }

    public let key: String
    public let title: String
    public let pdfFilenames: [String]

    public init(
        key: String,
        title: String,
        pdfFilenames: [String]
    ) {
        self.key = key
        self.title = title
        self.pdfFilenames = pdfFilenames
    }
}

/// Pure collection-hierarchy helpers shared by the picker and importer.
public enum ZoteroLibraryCollectionTree {
    public static func rows(
        from collections: [ZoteroLibraryCollection]
    ) -> [ZoteroLibraryCollectionRow] {
        let knownKeys = Set(collections.map(\.key))
        var childrenByParent: [String: [ZoteroLibraryCollection]] = [:]
        var roots: [ZoteroLibraryCollection] = []

        for collection in collections {
            if let parentKey = collection.parentKey, knownKeys.contains(parentKey) {
                childrenByParent[parentKey, default: []].append(collection)
            } else {
                roots.append(collection)
            }
        }

        func sorted(_ values: [ZoteroLibraryCollection]) -> [ZoteroLibraryCollection] {
            values.sorted {
                let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                return comparison == .orderedSame ? $0.key < $1.key : comparison == .orderedAscending
            }
        }

        var result: [ZoteroLibraryCollectionRow] = []
        var visited: Set<String> = []

        func append(_ collection: ZoteroLibraryCollection, depth: Int, parentPath: String?) {
            guard visited.insert(collection.key).inserted else { return }
            let path = parentPath.map { "\($0) / \(collection.name)" } ?? collection.name
            result.append(
                ZoteroLibraryCollectionRow(collection: collection, depth: depth, path: path)
            )
            for child in sorted(childrenByParent[collection.key] ?? []) {
                append(child, depth: depth + 1, parentPath: path)
            }
        }

        for root in sorted(roots) {
            append(root, depth: 0, parentPath: nil)
        }

        // Defensive cycle handling. Zotero should never return a cyclic tree,
        // but keeping every collection visible is better than dropping corrupt
        // or forward-version data from the picker.
        for collection in sorted(collections) where !visited.contains(collection.key) {
            append(collection, depth: 0, parentPath: nil)
        }

        return result
    }

    public static func expandingDescendants(
        of selectedKeys: Set<String>,
        in collections: [ZoteroLibraryCollection]
    ) -> Set<String> {
        let knownKeys = Set(collections.map(\.key))
        var childrenByParent: [String: [String]] = [:]
        for collection in collections {
            guard let parentKey = collection.parentKey else { continue }
            childrenByParent[parentKey, default: []].append(collection.key)
        }

        var expanded = selectedKeys.intersection(knownKeys)
        var pending = Array(expanded)
        while let key = pending.popLast() {
            for child in childrenByParent[key] ?? [] where expanded.insert(child).inserted {
                pending.append(child)
            }
        }
        return expanded
    }
}

public enum ZoteroLibraryScope: Equatable, Sendable {
    case entireLibrary
    case collections(Set<String>)
}

public enum ZoteroLocalAPIError: Error, LocalizedError, Equatable, Sendable {
    case notRunning
    case accessDisabled
    case unsupportedAPIVersion(String?)
    case invalidResponse
    case timedOut
    case communicationFailed(String)
    case requestFailed(statusCode: Int, message: String)
    case noCollectionsSelected

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Rubien could not connect to Zotero. Open Zotero and try again."
        case .accessDisabled:
            return "Zotero is running, but local library access is disabled. "
                + "In Zotero, open Settings → Advanced and enable “Allow other applications "
                + "on this computer to communicate with Zotero”, then try again."
        case .unsupportedAPIVersion(let version):
            let displayed = version ?? "unknown"
            return "This Zotero local API version (\(displayed)) is not supported by this version of Rubien."
        case .invalidResponse:
            return "Zotero returned an unreadable local API response."
        case .timedOut:
            return "Zotero took too long to prepare this library response. Try again or import a smaller collection."
        case .communicationFailed(let message):
            let suffix = message.isEmpty ? "" : ": \(message)"
            return "Rubien lost communication with Zotero\(suffix)"
        case .requestFailed(let statusCode, let message):
            let suffix = message.isEmpty ? "" : ": \(message)"
            return "Zotero returned HTTP \(statusCode)\(suffix)"
        case .noCollectionsSelected:
            return "Select at least one Zotero collection to import."
        }
    }
}

/// Read-only client for Zotero's supported desktop local API.
public struct ZoteroLocalAPIClient: Sendable {
    public struct Response: Sendable {
        public let data: Data
        public let statusCode: Int
        public let headers: [String: String]

        public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
            self.data = data
            self.statusCode = statusCode
            self.headers = headers
        }

        fileprivate func header(named name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    public typealias Transport = @Sendable (URLRequest) async throws -> Response

    private static let supportedAPIVersion = "3"
    /// The local API otherwise returns every matching object in one response.
    /// Bound disclosure previews independently from full import preparation.
    private static let collectionPreviewObjectLimit = 500
    private static let collectionPreviewPaperLimit = 200
    private static let importPageSize = 200
    private let baseURL: URL
    private let transport: Transport

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:23119/api/")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.transport = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ZoteroLocalAPIError.invalidResponse
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
            return Response(data: data, statusCode: http.statusCode, headers: headers)
        }
    }

    /// Test and alternate-transport initializer. Keeping transport injection at
    /// the HTTP boundary makes status/error and JSON behavior deterministic.
    public init(baseURL: URL, transport: @escaping Transport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func probe() async throws {
        let response = try await send(path: "/")
        try validateAPIVersion(response)
    }

    public func fetchCollections() async throws -> [ZoteroLibraryCollection] {
        let response = try await send(path: "/users/0/collections")
        let envelopes: [CollectionEnvelope]
        do {
            envelopes = try JSONDecoder().decode([CollectionEnvelope].self, from: response.data)
        } catch {
            throw ZoteroLocalAPIError.invalidResponse
        }
        return envelopes.map {
            ZoteroLibraryCollection(
                key: $0.key,
                name: $0.data.name,
                parentKey: $0.data.parentCollection?.stringValue,
                itemCount: $0.meta?.numItems ?? 0,
                childCollectionCount: $0.meta?.numCollections ?? 0
            )
        }
    }

    /// Fetches the papers directly assigned to one collection for disclosure
    /// in the picker. Child collections are separate rows in the hierarchy.
    public func fetchCollectionItems(
        collectionKey: String
    ) async throws -> [ZoteroLibraryItemSummary] {
        let response = try await send(
            path: "/users/0/collections/\(collectionKey)/items",
            queryItems: [
                URLQueryItem(name: "include", value: "data"),
                URLQueryItem(name: "itemType", value: "-annotation"),
                URLQueryItem(
                    name: "limit",
                    value: String(Self.collectionPreviewObjectLimit)
                ),
                URLQueryItem(name: "sort", value: "title"),
                URLQueryItem(name: "direction", value: "asc"),
            ]
        )
        let envelopes = try decodeItems(response.data)
        var pdfFilenamesByParent: [String: [String]] = [:]
        for envelope in envelopes {
            guard envelope.data.itemType == "attachment",
                  envelope.data.isPDF,
                  let parentKey = envelope.data.parentItem?.stringValue
            else { continue }
            pdfFilenamesByParent[parentKey, default: []].append(
                envelope.data.attachmentLabel(fallbackKey: envelope.key)
            )
        }

        let summaries = envelopes
            .filter(\.data.isRegularItem)
            .map { envelope in
                ZoteroLibraryItemSummary(
                    key: envelope.key,
                    title: envelope.data.title?.nonBlank ?? "Untitled",
                    pdfFilenames: (pdfFilenamesByParent[envelope.key] ?? []).sorted {
                        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                    }
                )
            }
            .sorted {
                let comparison = $0.title.localizedCaseInsensitiveCompare($1.title)
                return comparison == .orderedSame
                    ? $0.key < $1.key
                    : comparison == .orderedAscending
            }
        return Array(summaries.prefix(Self.collectionPreviewPaperLimit))
    }

    fileprivate func fetchImportEntries(
        scope: ZoteroLibraryScope,
        collections: [ZoteroLibraryCollection],
        includeSubcollections: Bool,
        includeAnnotations: Bool
    ) async throws -> [LocalImportEntry] {
        let paths: [String]
        let isEntireLibrary: Bool
        let snapshotCollectionKeys: Set<String>?
        let collectionScopeCoversMostItems: Bool
        switch scope {
        case .entireLibrary:
            paths = ["/users/0/items"]
            isEntireLibrary = true
            snapshotCollectionKeys = nil
            collectionScopeCoversMostItems = true
        case .collections(let selectedKeys):
            let keys = includeSubcollections
                ? ZoteroLibraryCollectionTree.expandingDescendants(
                    of: selectedKeys,
                    in: collections
                )
                : selectedKeys.intersection(collections.map(\.key))
            guard !keys.isEmpty else { throw ZoteroLocalAPIError.noCollectionsSelected }
            let selectedItemEstimate = collections.reduce(into: 0) { count, collection in
                if keys.contains(collection.key) { count += max(0, collection.itemCount) }
            }
            let allFiledItemEstimate = collections.reduce(0) {
                $0 + max(0, $1.itemCount)
            }
            collectionScopeCoversMostItems = allFiledItemEstimate > 0
                && selectedItemEstimate * 2 >= allFiledItemEstimate
            // Selecting most of a large collection tree is substantially
            // faster as one local-library snapshot than as dozens of
            // sequential collection requests. Filter the snapshot back to
            // direct collection membership so unfiled references stay out.
            // Direct item-count estimates prevent many mostly-empty folders
            // from triggering a full-library BibTeX response.
            let useSnapshot = keys.count >= 12
                && keys.count * 2 >= collections.count
                && selectedItemEstimate >= 100
                && collectionScopeCoversMostItems
            paths = useSnapshot
                ? ["/users/0/items"]
                : keys.sorted().map { "/users/0/collections/\($0)/items" }
            isEntireLibrary = false
            snapshotCollectionKeys = useSnapshot ? keys : nil
        }

        var envelopesByKey: [String: ItemEnvelope] = [:]
        var keyOrder: [String] = []
        for path in paths {
            var queryItems = [URLQueryItem(name: "include", value: "data,bibtex")]
            if path == "/users/0/items" {
                // Library-wide item endpoints include annotations by default;
                // annotations are fetched separately only when requested.
                queryItems.append(URLQueryItem(name: "itemType", value: "-annotation"))
            }
            let decodedEnvelopes = try await fetchAllItems(
                path: path,
                queryItems: queryItems
            )
            let envelopes: [ItemEnvelope]
            if let snapshotCollectionKeys {
                let includedRegularKeys = Set(
                    decodedEnvelopes.lazy
                        .filter { envelope in
                            envelope.data.isRegularItem
                                && (envelope.data.collections ?? []).contains {
                                    snapshotCollectionKeys.contains($0)
                                }
                        }
                        .map(\.key)
                )
                envelopes = decodedEnvelopes.filter { envelope in
                    includedRegularKeys.contains(envelope.key)
                        || envelope.data.parentItem?.stringValue.map {
                            includedRegularKeys.contains($0)
                        } == true
                }
            } else {
                envelopes = decodedEnvelopes
            }
            for envelope in envelopes where envelopesByKey[envelope.key] == nil {
                envelopesByKey[envelope.key] = envelope
                keyOrder.append(envelope.key)
            }
        }

        var attachmentsByParent: [String: [ItemEnvelope]] = [:]
        for key in keyOrder {
            guard let envelope = envelopesByKey[key],
                  envelope.data.itemType == "attachment",
                  let parentKey = envelope.data.parentItem?.stringValue
            else { continue }
            attachmentsByParent[parentKey, default: []].append(envelope)
        }

        var annotationsByAttachment: [String: LocalAnnotationBucket] = [:]
        func recordAnnotation(_ annotation: ItemEnvelope, attachmentKey: String) {
            let draft = makeAnnotationDraft(from: annotation)
            annotationsByAttachment[attachmentKey, default: LocalAnnotationBucket()]
                .record(draft)
        }
        if includeAnnotations {
            let selectedAttachmentKeys = Set(
                attachmentsByParent.values
                    .flatMap { $0 }
                    .filter { $0.data.isPDF }
                    .map(\.key)
            )
            if !selectedAttachmentKeys.isEmpty {
                let useGlobalAnnotationQuery = isEntireLibrary
                    || (selectedAttachmentKeys.count > 64
                        && collectionScopeCoversMostItems)
                if !useGlobalAnnotationQuery {
                    // Narrow collection imports should not download every
                    // annotation in My Library. Ask only for each selected
                    // attachment's children; the higher cutoff avoids a
                    // whole-library scan for modest 10–20 PDF collections.
                    for attachmentKey in selectedAttachmentKeys.sorted() {
                        try await forEachItemPage(
                            path: "/users/0/items/\(attachmentKey)/children"
                        ) { annotations in
                            for annotation in annotations
                                where annotation.data.itemType == "annotation" {
                                recordAnnotation(annotation, attachmentKey: attachmentKey)
                            }
                        }
                    }
                } else {
                    try await forEachItemPage(
                        path: "/users/0/items",
                        queryItems: [URLQueryItem(name: "itemType", value: "annotation")]
                    ) { annotations in
                        for annotation in annotations {
                            guard let attachmentKey = annotation.data.parentItem?.stringValue,
                                  selectedAttachmentKeys.contains(attachmentKey)
                            else { continue }
                            recordAnnotation(annotation, attachmentKey: attachmentKey)
                        }
                    }
                }
            }
        }

        var entries: [LocalImportEntry] = []
        for key in keyOrder {
            guard let envelope = envelopesByKey[key], envelope.data.isRegularItem else { continue }
            // Reference timestamps describe Rubien's own library lifecycle.
            // Keep the fresh defaults instead of inheriting when Zotero added
            // or last changed its copy of the item.
            let reference = makeReference(from: envelope)

            var chosenAttachment: (envelope: ItemEnvelope, url: URL, label: String)?
            let pdfAttachments = (attachmentsByParent[key] ?? []).filter(\.data.isPDF)
            let rankedAttachments = pdfAttachments
                .enumerated()
                .map { index, attachment in
                    let supportedCount = annotationsByAttachment[attachment.key]?.drafts.count ?? 0
                    return (
                        attachment: attachment,
                        supportedCount: supportedCount,
                        originalIndex: index
                    )
                }
                .sorted {
                    if $0.supportedCount != $1.supportedCount {
                        return $0.supportedCount > $1.supportedCount
                    }
                    return $0.originalIndex < $1.originalIndex
                }
            var missingLabels: [String] = []
            for ranked in rankedAttachments {
                let attachment = ranked.attachment
                let label = attachment.data.attachmentLabel(fallbackKey: attachment.key)
                guard let url = try await localFileURL(for: attachment) else {
                    missingLabels.append(label)
                    continue
                }
                chosenAttachment = (attachment, url, label)
                break
            }

            let importedAnnotations = chosenAttachment.flatMap {
                annotationsByAttachment[$0.envelope.key]?.drafts
            } ?? []
            let totalAnnotationCount = includeAnnotations
                ? pdfAttachments.reduce(into: 0) { count, attachment in
                    count += annotationsByAttachment[attachment.key]?.totalCount ?? 0
                }
                : 0

            entries.append(
                LocalImportEntry(
                    sourceKey: envelope.key,
                    reference: reference,
                    attachmentURLs: chosenAttachment.map { [$0.url] } ?? [],
                    attachmentLabels: chosenAttachment.map { [$0.label] } ?? [],
                    missingAttachmentLabels: missingLabels,
                    annotations: importedAnnotations,
                    skippedAnnotationCount: totalAnnotationCount - importedAnnotations.count
                )
            )
        }

        return entries.sorted {
            let comparison = $0.reference.title.localizedCaseInsensitiveCompare($1.reference.title)
            return comparison == .orderedSame
                ? $0.sourceKey < $1.sourceKey
                : comparison == .orderedAscending
        }
    }

    private func decodeItems(_ data: Data) throws -> [ItemEnvelope] {
        do {
            return try JSONDecoder().decode([ItemEnvelope].self, from: data)
        } catch {
            throw ZoteroLocalAPIError.invalidResponse
        }
    }

    private func fetchAllItems(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> [ItemEnvelope] {
        var result: [ItemEnvelope] = []
        try await forEachItemPage(path: path, queryItems: queryItems) { page in
            result.append(contentsOf: page)
        }
        return result
    }

    private func forEachItemPage(
        path: String,
        queryItems: [URLQueryItem] = [],
        consume: ([ItemEnvelope]) throws -> Void
    ) async throws {
        var start = 0
        while true {
            var pageQueryItems = queryItems.filter {
                $0.name != "limit" && $0.name != "start"
            }
            pageQueryItems.append(
                URLQueryItem(name: "limit", value: String(Self.importPageSize))
            )
            pageQueryItems.append(URLQueryItem(name: "start", value: String(start)))

            let response = try await send(path: path, queryItems: pageQueryItems)
            let page = try decodeItems(response.data)
            try consume(page)

            guard !page.isEmpty else { return }
            start += page.count
            if let total = response.header(named: "Total-Results").flatMap(Int.init) {
                if start >= total { return }
            } else if page.count < Self.importPageSize {
                return
            }
        }
    }

    private func localFileURL(for attachment: ItemEnvelope) async throws -> URL? {
        // A linked URL can advertise a PDF MIME type but has no local file for
        // Rubien to copy. Zotero returns 400 from its file endpoint for these.
        guard attachment.data.linkMode != "linked_url" else { return nil }

        if let href = attachment.links?.enclosure?.href,
           let url = URL(string: href),
           url.isFileURL,
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        // Linked-file attachments may not expose an enclosure. Zotero's
        // supported file endpoint resolves both imported and linked files.
        let response: Response
        do {
            response = try await send(
                path: "/users/0/items/\(attachment.key)/file/view/url"
            )
        } catch ZoteroLocalAPIError.requestFailed(let statusCode, _)
            where statusCode == 400 || statusCode == 404 {
            return nil
        }
        let rawURL = String(data: response.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawURL,
              let url = URL(string: rawURL),
              url.isFileURL,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    private func send(path: String, queryItems: [URLQueryItem] = []) async throws -> Response {
        guard let url = makeURL(path: path, queryItems: queryItems) else {
            throw ZoteroLocalAPIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Large libraries can spend several seconds generating included
        // BibTeX, even though the connection itself is loopback-only.
        request.timeoutInterval = 30
        request.setValue(Self.supportedAPIVersion, forHTTPHeaderField: "Zotero-API-Version")

        let response: Response
        do {
            response = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ZoteroLocalAPIError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                throw ZoteroLocalAPIError.notRunning
            case .timedOut:
                throw ZoteroLocalAPIError.timedOut
            default:
                if Task.isCancelled { throw CancellationError() }
                throw ZoteroLocalAPIError.communicationFailed(error.localizedDescription)
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ZoteroLocalAPIError.communicationFailed(error.localizedDescription)
        }

        switch response.statusCode {
        case 200 ..< 300:
            try validateAPIVersion(response)
            return response
        case 403:
            throw ZoteroLocalAPIError.accessDisabled
        default:
            let body = String(data: response.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ZoteroLocalAPIError.requestFailed(
                statusCode: response.statusCode,
                message: String(body.prefix(300))
            )
        }
    }

    private func validateAPIVersion(_ response: Response) throws {
        let version = response.header(named: "Zotero-API-Version")
        guard version == Self.supportedAPIVersion else {
            throw ZoteroLocalAPIError.unsupportedAPIVersion(version)
        }
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + (path.hasPrefix("/") ? path : "/\(path)")
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private func makeReference(from envelope: ItemEnvelope) -> Reference {
        if let bibtex = envelope.bibtex,
           let parsed = BibTeXImporter.parse(bibtex).first {
            return parsed
        }

        let data = envelope.data
        let authors = data.creators?
            .filter { $0.creatorType == nil || $0.creatorType == "author" }
            .compactMap(\.authorName) ?? []
        let editors = data.creators?
            .filter { $0.creatorType == "editor" }
            .compactMap(\.authorName) ?? []
        let translators = data.creators?
            .filter { $0.creatorType == "translator" }
            .compactMap(\.authorName) ?? []

        return Reference(
            title: data.title?.nonBlank ?? "Untitled",
            authors: authors,
            year: Self.firstFourDigitYear(in: data.date),
            journal: data.publicationTitle?.nonBlank
                ?? data.proceedingsTitle?.nonBlank
                ?? data.bookTitle?.nonBlank,
            volume: data.volume?.nonBlank,
            issue: data.issue?.nonBlank,
            pages: data.pages?.nonBlank,
            doi: data.doi?.nonBlank,
            url: data.url?.nonBlank,
            abstract: data.abstractNote?.nonBlank,
            referenceType: Self.referenceType(for: data.itemType),
            publisher: data.publisher?.nonBlank,
            publisherPlace: data.place?.nonBlank,
            edition: data.edition?.nonBlank,
            editors: Reference.encodeNames(editors),
            isbn: data.isbn?.nonBlank,
            issn: data.issn?.nonBlank,
            accessedDate: data.accessDate?.nonBlank,
            translators: Reference.encodeNames(translators),
            eventTitle: data.conferenceName?.nonBlank,
            genre: data.thesisType?.nonBlank,
            institution: data.university?.nonBlank,
            collectionTitle: data.series?.nonBlank,
            numberOfPages: data.numPages?.nonBlank,
            language: data.language?.nonBlank
        )
    }

    private static func firstFourDigitYear(in value: String?) -> Int? {
        guard let value else { return nil }
        let digits = Array(value)
        guard digits.count >= 4 else { return nil }
        for index in 0 ... (digits.count - 4) {
            let candidate = String(digits[index ..< index + 4])
            if candidate.allSatisfy(\.isNumber), let year = Int(candidate) {
                return year
            }
        }
        return nil
    }

    private static func referenceType(for itemType: String) -> ReferenceType {
        switch itemType {
        case "journalArticle", "magazineArticle", "newspaperArticle": return .journalArticle
        case "conferencePaper", "presentation": return .conferencePaper
        case "book", "bookSection": return .book
        case "thesis": return .thesis
        case "webpage", "blogPost", "forumPost": return .webpage
        default: return .other
        }
    }

    private func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = try? Date(value, strategy: .iso8601) {
            return date
        }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
    }

    private func makeAnnotationDraft(from envelope: ItemEnvelope) -> PDFAnnotationDraft? {
        let type: AnnotationType
        switch envelope.data.annotationType {
        case "highlight": type = .highlight
        case "underline": type = .underline
        case "note": type = .note
        default: return nil
        }

        guard let position = envelope.data.annotationPosition?.value,
              let pageIndex = position.pageIndex,
              pageIndex >= 0
        else { return nil }
        let rects = (position.rects ?? []).compactMap { coordinates -> CGRect? in
            guard coordinates.count >= 4 else { return nil }
            let rect = CGRect(
                x: coordinates[0],
                y: coordinates[1],
                width: coordinates[2] - coordinates[0],
                height: coordinates[3] - coordinates[1]
            ).standardized
            guard !rect.isNull, !rect.isEmpty, rect.width > 0, rect.height > 0 else {
                return nil
            }
            return rect
        }
        guard !rects.isEmpty else { return nil }

        // Zotero annotation text/comment fields are already extracted text,
        // not HTML. Preserve literal angle brackets used in equations/code.
        let selectedText = envelope.data.annotationText?.nonBlank
        let noteText = envelope.data.annotationComment?.nonBlank
        return PDFAnnotationDraft(
            type: type,
            selectedText: type == .note ? nil : selectedText,
            noteText: noteText,
            color: envelope.data.annotationColor?.nonBlank ?? "#FFDE59",
            pageIndex: pageIndex,
            rects: rects,
            dateCreated: parseISO8601(envelope.data.dateAdded) ?? Date(),
            dateModified: parseISO8601(envelope.data.dateModified) ?? Date()
        )
    }

}

/// Converts a selected local-API scope into the same review/commit plan used by
/// the exported-folder importer.
public enum ZoteroLibraryImporter {
    public static func prepare(
        client: ZoteroLocalAPIClient = ZoteroLocalAPIClient(),
        scope: ZoteroLibraryScope,
        collections: [ZoteroLibraryCollection],
        includeSubcollections: Bool,
        includeAnnotations: Bool = true,
        db: AppDatabase,
        propertyTarget: ZoteroImportPropertyTarget?
    ) async throws -> ZoteroFolderImportPlan {
        if let propertyTarget {
            try db.validatePropertyTarget(propertyTarget)
        }

        let sourceEntries = try await client.fetchImportEntries(
            scope: scope,
            collections: collections,
            includeSubcollections: includeSubcollections,
            includeAnnotations: includeAnnotations
        )

        return ZoteroFolderImportPlan(
            folderURL: nil,
            sourceName: sourceName(for: scope, collections: collections),
            propertyTarget: propertyTarget,
            entries: sourceEntries.enumerated().map { index, entry in
                ZoteroFolderImportPlan.Entry(
                    sourceIndex: index,
                    reference: entry.reference,
                    attachmentURLs: entry.attachmentURLs,
                    attachmentPaths: entry.attachmentLabels,
                    missingAttachmentPaths: entry.missingAttachmentLabels,
                    annotations: entry.annotations,
                    skippedAnnotationCount: entry.skippedAnnotationCount
                )
            }
        )
    }

    private static func sourceName(
        for scope: ZoteroLibraryScope,
        collections: [ZoteroLibraryCollection]
    ) -> String {
        switch scope {
        case .entireLibrary:
            return "Zotero — My Library"
        case .collections(let keys):
            if keys.count == 1,
               let key = keys.first,
               let collection = collections.first(where: { $0.key == key }) {
                return "Zotero — \(collection.name)"
            }
            return "Zotero — \(keys.count) collections"
        }
    }
}

private struct LocalImportEntry: Sendable {
    let sourceKey: String
    let reference: Reference
    let attachmentURLs: [URL]
    let attachmentLabels: [String]
    let missingAttachmentLabels: [String]
    let annotations: [PDFAnnotationDraft]
    let skippedAnnotationCount: Int
}

private struct LocalAnnotationBucket {
    var drafts: [PDFAnnotationDraft] = []
    var totalCount = 0

    mutating func record(_ draft: PDFAnnotationDraft?) {
        totalCount += 1
        if let draft {
            drafts.append(draft)
        }
    }
}

private struct CollectionEnvelope: Decodable {
    struct DataObject: Decodable {
        let name: String
        let parentCollection: StringOrFalse?
    }

    struct Meta: Decodable {
        let numItems: Int?
        let numCollections: Int?
    }

    let key: String
    let data: DataObject
    let meta: Meta?
}

private struct ItemEnvelope: Decodable {
    struct Links: Decodable {
        struct Link: Decodable {
            let href: String
        }

        let enclosure: Link?
    }

    let key: String
    let data: ItemData
    let bibtex: String?
    let links: Links?
}

private struct ItemData: Decodable {
    let itemType: String
    let parentItem: StringOrFalse?
    let linkMode: String?
    let contentType: String?
    let filename: String?
    let title: String?
    let date: String?
    let dateAdded: String?
    let dateModified: String?
    let creators: [ItemCreator]?
    let publicationTitle: String?
    let proceedingsTitle: String?
    let bookTitle: String?
    let volume: String?
    let issue: String?
    let pages: String?
    let doi: String?
    let url: String?
    let abstractNote: String?
    let publisher: String?
    let place: String?
    let edition: String?
    let isbn: String?
    let issn: String?
    let accessDate: String?
    let conferenceName: String?
    let thesisType: String?
    let university: String?
    let series: String?
    let numPages: String?
    let language: String?
    let annotationType: String?
    let annotationText: String?
    let annotationComment: String?
    let annotationColor: String?
    let annotationPosition: AnnotationPositionValue?
    let collections: [String]?

    private enum CodingKeys: String, CodingKey {
        case itemType, parentItem, linkMode, contentType, filename, title, date, dateAdded, dateModified
        case creators, publicationTitle, proceedingsTitle, bookTitle, volume, issue, pages
        case doi = "DOI"
        case url, abstractNote, publisher, place, edition
        case isbn = "ISBN"
        case issn = "ISSN"
        case accessDate, conferenceName, thesisType, university, series, numPages, language
        case annotationType, annotationText, annotationComment, annotationColor, annotationPosition
        case collections
    }

    var isRegularItem: Bool {
        parentItem?.stringValue == nil
            && !["attachment", "note", "annotation"].contains(itemType)
    }

    var isPDF: Bool {
        contentType?.lowercased() == "application/pdf"
            || filename?.lowercased().hasSuffix(".pdf") == true
    }

    func attachmentLabel(fallbackKey: String) -> String {
        filename?.nonBlank ?? title?.nonBlank ?? fallbackKey
    }
}

private struct AnnotationPositionValue: Decodable {
    struct Position: Decodable {
        let pageIndex: Int?
        let rects: [[Double]]?
    }

    let value: Position?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let json = try? container.decode(String.self),
           let data = json.data(using: .utf8) {
            value = try? JSONDecoder().decode(Position.self, from: data)
            return
        }
        value = try? container.decode(Position.self)
    }
}

private struct ItemCreator: Decodable {
    let creatorType: String?
    let firstName: String?
    let lastName: String?
    let name: String?

    var authorName: AuthorName? {
        let family = lastName?.nonBlank ?? name?.nonBlank
        guard let family else { return nil }
        return AuthorName(given: firstName?.nonBlank ?? "", family: family)
    }
}

/// Zotero represents root parents as JSON `false` and child parents as keys.
private struct StringOrFalse: Decodable {
    let stringValue: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            stringValue = value
            return
        }
        if (try? container.decode(Bool.self)) != nil {
            stringValue = nil
            return
        }
        if container.decodeNil() {
            stringValue = nil
            return
        }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a Zotero key string or false"
            )
        )
    }
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
