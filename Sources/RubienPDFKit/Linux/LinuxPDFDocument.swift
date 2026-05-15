#if os(Linux)
import Foundation
import CPoppler

/// Poppler-glib-backed implementation of `PDFDocumentProtocol`.
///
/// `@unchecked Sendable` rationale: poppler objects are reference-counted
/// via GObject (`g_object_ref`/`g_object_unref` are atomic per the GLib
/// docs), but mutating a `PopplerDocument` from multiple threads is not
/// supported. Each instance is single-owner in this codebase (CLI
/// open-extract-close), matching the Darwin discipline.
final class LinuxPDFDocument: PDFDocumentProtocol, @unchecked Sendable {
    private let docBox: GObjectBox

    init(url: URL) throws {
        // Convert the file path to a percent-encoded URI. `g_filename_to_uri`
        // handles non-ASCII paths and spaces correctly.
        var gerror: UnsafeMutablePointer<GError>? = nil
        guard let uriCStr = g_filename_to_uri(url.path, nil, &gerror) else {
            if let err = gerror { _ = GErrorWrapper(takingOwnershipOf: err) }
            throw PDFOpenError.cannotOpen(url)
        }
        let uri = String(cString: uriCStr)
        g_free(UnsafeMutableRawPointer(uriCStr))

        gerror = nil
        guard let docPtr = poppler_document_new_from_file(uri, nil, &gerror) else {
            // POPPLER_ERROR_ENCRYPTED → .locked; everything else → .cannotOpen.
            // Inspecting the GError's code lets us preserve the Darwin
            // contract that encrypted/locked PDFs surface as a distinct error.
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

    var isEncrypted: Bool {
        // poppler-glib only hands out documents that opened successfully. By
        // the time we hold a reference, the document is readable. Darwin's
        // `PDFDocument.isEncrypted` reports the document's *attribute* (whether
        // the file was encrypted), which is independent of whether you have a
        // password — but poppler does not expose that bit for already-opened
        // documents. Reporting `false` matches the practical observation that
        // a successfully opened poppler document is, from the caller's
        // standpoint, readable. The locked-PDF parity test exercises the
        // `init` path that throws `.locked` before getting here.
        false
    }

    var isLocked: Bool { false }

    var metadata: PDFMetadata {
        docBox.withPointer { pd in
            let title = takeOwnedString(poppler_document_get_title(pd))
            let author = takeOwnedString(poppler_document_get_author(pd))
            let subject = takeOwnedString(poppler_document_get_subject(pd))
            let keywordsRaw = takeOwnedString(poppler_document_get_keywords(pd))
            let creator = takeOwnedString(poppler_document_get_creator(pd))
            let producer = takeOwnedString(poppler_document_get_producer(pd))

            let creationDate: Date? = {
                let t = poppler_document_get_creation_date(pd)
                return t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
            }()
            let modificationDate: Date? = {
                let t = poppler_document_get_modification_date(pd)
                return t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
            }()

            let keywords: [String] = keywordsRaw.map { raw in
                raw.components(separatedBy: CharacterSet(charactersIn: ",;"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } ?? []

            return PDFMetadata(
                title: title,
                author: author,
                subject: subject,
                keywords: keywords,
                creator: creator,
                producer: producer,
                creationDate: creationDate,
                modificationDate: modificationDate
            )
        }
    }

    func page(at index: Int) -> PDFPageProtocol? {
        guard index >= 0, index < pageCount else { return nil }
        return docBox.withPointer { docPtr -> PDFPageProtocol? in
            guard let pagePtr = poppler_document_get_page(docPtr, Int32(index)) else {
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

    /// Walk a poppler outline iter and its children into a `PDFOutlineNode`
    /// tree. The iter is consumed in-place via `poppler_index_iter_next`; the
    /// caller frees the iter itself. Page numbers are converted from poppler's
    /// 1-based to the facade's 0-based; out-of-range entries surface as nil.
    private func walkOutline(iter: OpaquePointer, doc: OpaquePointer, pageCount: Int) -> [PDFOutlineNode] {
        var nodes: [PDFOutlineNode] = []
        repeat {
            var label = ""
            var pageIndex: Int? = nil

            if let actionPtr = poppler_index_iter_get_action(iter) {
                // Every variant of the PopplerAction union starts with
                // PopplerActionAny { type, title }. Read those for the
                // generic case, then specialise on .type for GOTO_DEST to
                // resolve the page number.
                let any = actionPtr.pointee.any
                label = any.title.map { String(cString: $0) } ?? ""

                if any.type == POPPLER_ACTION_GOTO_DEST,
                   let destPtr = actionPtr.pointee.goto_dest.dest {
                    if destPtr.pointee.type == POPPLER_DEST_NAMED,
                       let namedDestCStr = destPtr.pointee.named_dest,
                       let resolved = poppler_document_find_dest(doc, namedDestCStr) {
                        pageIndex = Int(resolved.pointee.page_num) - 1
                        poppler_dest_free(resolved)
                    } else if destPtr.pointee.type != POPPLER_DEST_UNKNOWN {
                        pageIndex = Int(destPtr.pointee.page_num) - 1
                    }
                }
                poppler_action_free(actionPtr)
            }

            let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)

            var children: [PDFOutlineNode] = []
            if let childIter = poppler_index_iter_get_child(iter) {
                children = walkOutline(iter: childIter, doc: doc, pageCount: pageCount)
                poppler_index_iter_free(childIter)
            }

            // Drop empty-label leaves; keep empty-label containers (the
            // cross-platform `flattenOutline` step folds them out via the
            // container-bookmark backfill, borrowing startPage from the
            // first descendant with a destination).
            if cleanLabel.isEmpty && children.isEmpty { continue }

            let validatedPageIndex: Int? = pageIndex.flatMap { idx in
                (idx >= 0 && idx < pageCount) ? idx : nil
            }

            nodes.append(PDFOutlineNode(label: cleanLabel, pageIndex: validatedPageIndex, children: children))
        } while poppler_index_iter_next(iter) != 0
        return nodes
    }
}

/// Free a g_malloc'd string and return it as a Swift `String?`. Empty
/// strings collapse to `nil` so the metadata reads "absent" the way
/// PDFKit does (PDFKit returns nil for missing attributes, not empty).
private func takeOwnedString(_ ptr: UnsafeMutablePointer<gchar>?) -> String? {
    guard let p = ptr else { return nil }
    let s = String(cString: p)
    g_free(UnsafeMutableRawPointer(p))
    return s.isEmpty ? nil : s
}
#endif
