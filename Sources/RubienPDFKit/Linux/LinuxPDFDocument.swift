#if os(Linux)
import Foundation
import CPoppler

/// Poppler-glib-backed `PDFDocumentProtocol`. See `Docs/Linux-PDF-Backend.md`
/// for the API and ownership rules this wraps; `@unchecked Sendable` matches
/// the Darwin discipline (single-owner per CLI/extractor session).
final class LinuxPDFDocument: PDFDocumentProtocol, @unchecked Sendable {
    private let docBox: GObjectBox

    init(url: URL) throws {
        var gerror: UnsafeMutablePointer<GError>? = nil
        guard let uriCStr = g_filename_to_uri(url.path, nil, &gerror) else {
            if let err = gerror { _ = GErrorWrapper(takingOwnershipOf: err) }
            throw PDFOpenError.cannotOpen(url)
        }
        let uri = String(cString: uriCStr)
        g_free(UnsafeMutableRawPointer(uriCStr))

        gerror = nil
        guard let docPtr = poppler_document_new_from_file(uri, nil, &gerror) else {
            // POPPLER_ERROR_ENCRYPTED → .locked preserves the Darwin
            // distinction between locked and unreadable.
            if let err = gerror {
                let wrapped = GErrorWrapper(takingOwnershipOf: err)
                if wrapped.code == POPPLER_ERROR_ENCRYPTED.rawValue {
                    throw PDFOpenError.locked
                }
            }
            throw PDFOpenError.cannotOpen(url)
        }
        self.docBox = GObjectBox(takingOwnershipOf: docPtr)
    }

    var pageCount: Int {
        Int(docBox.withPointer { poppler_document_get_n_pages($0) })
    }

    // poppler-glib gives no post-open access to the encrypted-file bit;
    // locked-PDF parity is enforced at `init` via PDFOpenError.locked.
    var isEncrypted: Bool { false }
    var isLocked: Bool { false }

    var metadata: PDFMetadata {
        docBox.withPointer { pd in
            let keywords: [String] = takeOwnedString(poppler_document_get_keywords(pd)).map { raw in
                raw.components(separatedBy: CharacterSet(charactersIn: ",;"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } ?? []
            return PDFMetadata(
                title: takeOwnedString(poppler_document_get_title(pd)),
                author: takeOwnedString(poppler_document_get_author(pd)),
                subject: takeOwnedString(poppler_document_get_subject(pd)),
                keywords: keywords,
                creator: takeOwnedString(poppler_document_get_creator(pd)),
                producer: takeOwnedString(poppler_document_get_producer(pd)),
                creationDate: dateFromPopplerTimeT(poppler_document_get_creation_date(pd)),
                modificationDate: dateFromPopplerTimeT(poppler_document_get_modification_date(pd))
            )
        }
    }

    func page(at index: Int) -> PDFPageProtocol? {
        docBox.withPointer { docPtr -> PDFPageProtocol? in
            let total = Int(poppler_document_get_n_pages(docPtr))
            guard index >= 0, index < total,
                  let pagePtr = poppler_document_get_page(docPtr, Int32(index)) else {
                return nil
            }
            return LinuxPDFPage(takingOwnershipOf: pagePtr)
        }
    }

    func outlineRoot() -> PDFOutlineNode? {
        docBox.withPointer { docPtr -> PDFOutlineNode? in
            guard let rootIter = poppler_index_iter_new(docPtr) else { return nil }
            defer { poppler_index_iter_free(rootIter) }
            let pageCount = Int(poppler_document_get_n_pages(docPtr))
            let children = walkOutline(iter: rootIter, doc: docPtr, pageCount: pageCount)
            guard !children.isEmpty else { return nil }
            return PDFOutlineNode(label: "", pageIndex: nil, children: children)
        }
    }

    /// Walk a poppler outline iter + its children into a `PDFOutlineNode`
    /// tree. Poppler `page_num` is 1-based; we emit 0-based. Container
    /// bookmarks with no destination of their own are kept so the
    /// cross-platform flattener can backfill their start page from the
    /// first descendant.
    private func walkOutline(iter: OpaquePointer, doc: OpaquePointer, pageCount: Int) -> [PDFOutlineNode] {
        var nodes: [PDFOutlineNode] = []
        repeat {
            let (label, pageIndex) = readCurrentEntry(iter: iter, doc: doc)
            let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)

            var children: [PDFOutlineNode] = []
            if let childIter = poppler_index_iter_get_child(iter) {
                children = walkOutline(iter: childIter, doc: doc, pageCount: pageCount)
                poppler_index_iter_free(childIter)
            }

            if cleanLabel.isEmpty && children.isEmpty { continue }
            let validated = pageIndex.flatMap { idx in (idx >= 0 && idx < pageCount) ? idx : nil }
            nodes.append(PDFOutlineNode(label: cleanLabel, pageIndex: validated, children: children))
        } while poppler_index_iter_next(iter) != 0
        return nodes
    }

    /// Read the current iter's title and resolved 0-based page index.
    /// Every `PopplerAction` variant starts with the `any` { type, title }
    /// header; we specialise on `.type == GOTO_DEST` to pull a page number.
    private func readCurrentEntry(iter: OpaquePointer, doc: OpaquePointer) -> (label: String, pageIndex: Int?) {
        guard let actionPtr = poppler_index_iter_get_action(iter) else {
            return ("", nil)
        }
        defer { poppler_action_free(actionPtr) }

        let any = actionPtr.pointee.any
        let label = any.title.map { String(cString: $0) } ?? ""
        guard any.type == POPPLER_ACTION_GOTO_DEST,
              let destPtr = actionPtr.pointee.goto_dest.dest else {
            return (label, nil)
        }
        if destPtr.pointee.type == POPPLER_DEST_NAMED,
           let namedDestCStr = destPtr.pointee.named_dest,
           let resolved = poppler_document_find_dest(doc, namedDestCStr) {
            defer { poppler_dest_free(resolved) }
            return (label, Int(resolved.pointee.page_num) - 1)
        }
        if destPtr.pointee.type == POPPLER_DEST_UNKNOWN {
            return (label, nil)
        }
        return (label, Int(destPtr.pointee.page_num) - 1)
    }
}

private func dateFromPopplerTimeT(_ t: time_t) -> Date? {
    t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
}
#endif
