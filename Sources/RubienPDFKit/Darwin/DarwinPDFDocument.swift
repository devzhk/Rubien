#if canImport(PDFKit)
import Foundation
import PDFKit

/// PDFKit-backed `PDFDocumentProtocol`. `@unchecked Sendable` holds because
/// the codebase keeps each instance single-owner (CLI open-extract-close, or
/// the SwiftUI reader's exclusive reference); same discipline applies to
/// `LinuxPDFDocument`.
final class DarwinPDFDocument: PDFDocumentProtocol, @unchecked Sendable {
    private let document: PDFDocument

    init(url: URL) throws {
        // No FileManager pre-check — TOCTOU race vs. concurrent deletes.
        // PDFDocument(url:) returns nil for missing/unreadable/corrupt;
        // collapsing those into .cannotOpen matches Linux's behavior.
        guard let doc = PDFDocument(url: url) else {
            throw PDFOpenError.cannotOpen(url)
        }
        if doc.isLocked {
            throw PDFOpenError.locked
        }
        self.document = doc
    }

    var pageCount: Int { document.pageCount }

    var isEncrypted: Bool { document.isEncrypted }

    var isLocked: Bool { document.isLocked }

    var metadata: PDFMetadata {
        guard let attrs = document.documentAttributes else { return PDFMetadata() }
        let keywords: [String]
        if let arr = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            keywords = arr
        } else if let s = attrs[PDFDocumentAttribute.keywordsAttribute] as? String, !s.isEmpty {
            keywords = s.components(separatedBy: CharacterSet(charactersIn: ",;"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            keywords = []
        }
        return PDFMetadata(
            title: attrs[PDFDocumentAttribute.titleAttribute] as? String,
            author: attrs[PDFDocumentAttribute.authorAttribute] as? String,
            subject: attrs[PDFDocumentAttribute.subjectAttribute] as? String,
            keywords: keywords,
            creator: attrs[PDFDocumentAttribute.creatorAttribute] as? String,
            producer: attrs[PDFDocumentAttribute.producerAttribute] as? String,
            creationDate: attrs[PDFDocumentAttribute.creationDateAttribute] as? Date,
            modificationDate: attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date
        )
    }

    func page(at index: Int) -> PDFPageProtocol? {
        guard index >= 0, index < document.pageCount, let p = document.page(at: index) else {
            return nil
        }
        return DarwinPDFPage(page: p)
    }

    func outlineRoot() -> PDFOutlineNode? {
        guard let root = document.outlineRoot, root.numberOfChildren > 0 else { return nil }
        let children = Self.walk(outline: root, in: document)
        guard !children.isEmpty else { return nil }
        return PDFOutlineNode(label: "", pageIndex: nil, children: children)
    }

    private static func walk(outline: PDFOutline, in doc: PDFDocument) -> [PDFOutlineNode] {
        var nodes: [PDFOutlineNode] = []
        for i in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: i) else { continue }
            let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let pageIndex0: Int? = child.destination?.page.flatMap { p in
                let idx = doc.index(for: p)
                return (idx >= 0 && idx < doc.pageCount) ? idx : nil
            }
            let grandChildren = walk(outline: child, in: doc)
            if title.isEmpty && grandChildren.isEmpty { continue }
            nodes.append(PDFOutlineNode(label: title, pageIndex: pageIndex0, children: grandChildren))
        }
        return nodes
    }
}
#endif
