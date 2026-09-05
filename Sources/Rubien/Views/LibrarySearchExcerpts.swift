#if os(macOS)
import Foundation
import GRDB
import RubienCore

struct LibrarySearchExcerpt: Sendable {
    let source: String
    let text: String
}

/// Fetch annotations in batches, rather than querying once per visible row.
/// Results remain references so existing open, selection, and delete actions
/// keep their meaning even when several annotations match the same paper.
func librarySearchExcerpts(
    db: AppDatabase,
    references: [Reference],
    query: String,
    scope: ReferenceSearchScope,
    titleOnly: Bool
) throws -> [Int64: LibrarySearchExcerpt] {
    guard !titleOnly else { return [:] }
    let terms = ReferenceFilter.keywordTokens(query)
    guard !terms.isEmpty || scope == .notesAndHighlights else { return [:] }
    return try db.dbWriter.read { database in
        var excerpts: [Int64: LibrarySearchExcerpt] = [:]
        func add(_ id: Int64?, source: String, text: String?) {
            guard let id, excerpts[id] == nil, let text,
                  let snippet = librarySearchSnippet(text, terms: terms) else { return }
            excerpts[id] = LibrarySearchExcerpt(source: source, text: snippet)
        }
        for reference in references {
            try Task.checkCancellation()
            if scope != .notesAndHighlights {
                add(reference.id, source: String(localized: "Abstract", bundle: .module), text: reference.abstract)
            }
            if scope != .papers {
                add(reference.id, source: String(localized: "Note", bundle: .module), text: reference.notes)
            }
        }
        guard scope != .papers else { return excerpts }
        let ids = references.compactMap(\.id)
        for start in stride(from: 0, to: ids.count, by: 400) {
            try Task.checkCancellation()
            let batch = ids[start..<min(start + 400, ids.count)].filter { excerpts[$0] == nil }
            guard !batch.isEmpty else { continue }
            let pdf = try PDFAnnotationRecord.filter(batch.contains(PDFAnnotationRecord.Columns.referenceId))
                .order(PDFAnnotationRecord.Columns.pageIndex, PDFAnnotationRecord.Columns.id).fetchAll(database)
            for annotation in pdf {
                let page = String(format: String(localized: "Page %d", bundle: .module), annotation.pageIndex + 1)
                add(annotation.referenceId, source: String(localized: "Note", bundle: .module) + " · " + page, text: annotation.noteText)
                add(annotation.referenceId, source: String(localized: "Highlight", bundle: .module) + " · " + page, text: annotation.selectedText)
            }
            try Task.checkCancellation()
            let webIDs = batch.filter { excerpts[$0] == nil }
            guard !webIDs.isEmpty else { continue }
            let web = try WebAnnotationRecord.filter(webIDs.contains(WebAnnotationRecord.Columns.referenceId))
                .order(WebAnnotationRecord.Columns.id).fetchAll(database)
            for annotation in web {
                add(annotation.referenceId, source: String(localized: "Web note", bundle: .module), text: annotation.noteText)
                add(annotation.referenceId, source: String(localized: "Web highlight", bundle: .module), text: annotation.anchorText)
            }
        }
        return excerpts
    }
}

func librarySearchSnippet(_ text: String, terms: [String]) -> String? {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let match = terms.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
        .min { $0.lowerBound < $1.lowerBound }
    guard terms.isEmpty || match != nil else { return nil }
    let center = match?.lowerBound ?? text.startIndex
    let start = text.index(center, offsetBy: -45, limitedBy: text.startIndex) ?? text.startIndex
    let end = text.index(start, offsetBy: 180, limitedBy: text.endIndex) ?? text.endIndex
    let snippet = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return (start == text.startIndex ? "" : "…") + snippet + (end == text.endIndex ? "" : "…")
}
#endif
