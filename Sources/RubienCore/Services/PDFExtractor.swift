import Foundation
#if canImport(PDFKit)
import PDFKit
#if canImport(AppKit)
import AppKit
#endif

public enum PDFExtractor {

    public struct Section: Sendable, Encodable, Equatable {
        public var title: String
        public var level: Int
        public var startPage: Int
        public var endPage: Int

        public init(title: String, level: Int, startPage: Int, endPage: Int) {
            self.title = title
            self.level = level
            self.startPage = startPage
            self.endPage = endPage
        }
    }

    public struct Info: Sendable, Encodable {
        public var pageCount: Int
        public var hasTextLayer: Bool
        public var fileBytes: Int
        public var isEncrypted: Bool
        public var documentTitle: String?
        public var sections: [Section]?
    }

    public enum Selection: Sendable {
        case allPages
        case pages([ClosedRange<Int>])
        /// Same as `.pages` but takes the raw range string and resolves
        /// `pageCount`-dependent forms (`12-`) inside `extractText`. Use this
        /// from the CLI/MCP boundary so we don't pay for two `PDFDocument`
        /// opens (one to read pageCount, one to extract).
        case pagesString(String)
        case sections([String])
    }

    public enum SelectionMode: String, Sendable, Encodable {
        case all
        case page
        case section
    }

    public struct PageContent: Sendable, Encodable {
        public var index: Int
        public var text: String
        public var sectionPath: [String]
    }

    public struct SelectionEcho: Sendable, Encodable {
        public var mode: SelectionMode
        public var pages: String?
        public var requested: [String]?
        public var matchedSections: [String]?
        public var unmatched: [String]?
    }

    public struct TextResult: Sendable, Encodable {
        public var pageCount: Int
        public var selection: SelectionEcho
        public var pages: [PageContent]
        public var truncated: Bool
        public var hasTextLayer: Bool
    }

    public struct PageImage: Sendable, Encodable {
        public var page: Int
        public var mimeType: String
        public var data: Data
        public var widthPx: Int
        public var heightPx: Int
        public var qualityUsed: Double?
    }

    public enum Format: String, Sendable, Encodable {
        case jpeg
        case png
    }

    public enum ExtractError: Error, CustomStringConvertible, Sendable {
        case fileMissing(String)
        case cannotOpen(String)
        case encrypted
        case noOutline
        case pageOutOfRange(Int)
        case renderFailed
        case maxBytesExceeded(Int)
        case invalidPageRange(String)

        public var description: String {
            switch self {
            case .fileMissing(let p): return "file-missing: \(p)"
            case .cannotOpen(let p): return "cannot-open: \(p)"
            case .encrypted: return "encrypted"
            case .noOutline: return "no-outline"
            case .pageOutOfRange(let p): return "page-out-of-range: \(p)"
            case .renderFailed: return "render-failed"
            case .maxBytesExceeded(let b): return "max-bytes-exceeded: \(b)"
            case .invalidPageRange(let s): return "invalid-page-range: \(s)"
            }
        }

        public var code: String {
            switch self {
            case .fileMissing: return "file-missing"
            case .cannotOpen: return "cannot-open"
            case .encrypted: return "encrypted"
            case .noOutline: return "no-outline"
            case .pageOutOfRange: return "page-out-of-range"
            case .renderFailed: return "render-failed"
            case .maxBytesExceeded: return "max-bytes-exceeded"
            case .invalidPageRange: return "invalid-page-range"
            }
        }
    }

    // MARK: - info

    public static func info(at url: URL) throws -> Info {
        let doc = try openDocument(at: url)
        let pageCount = doc.pageCount
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        var docTitle: String?
        if let t = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { docTitle = trimmed }
        }

        let sections = outline(from: doc)
        let hasText = sampleHasTextLayer(doc: doc)

        return Info(
            pageCount: pageCount,
            hasTextLayer: hasText,
            fileBytes: bytes,
            isEncrypted: doc.isEncrypted,
            documentTitle: docTitle,
            sections: sections
        )
    }

    // MARK: - outline

    /// Flattened depth-first outline. `level` is 1-indexed (1 = top-level chapter).
    /// `endPage` is computed as `(next entry at same-or-shallower level).startPage - 1`,
    /// falling back to `pageCount` for the last entry — so a parent section's range
    /// spans all of its descendants.
    public static func outline(from doc: PDFDocument) -> [Section]? {
        guard let flat = walkOutline(doc) else { return nil }
        let ends = computeEndPages(for: flat, pageCount: doc.pageCount)
        return zip(flat, ends).map { entry, endPage in
            Section(
                title: entry.title,
                level: entry.level,
                startPage: entry.startPage,
                endPage: endPage
            )
        }
    }

    /// UI-flavored outline that retains `PDFDestination` for precise navigation.
    /// Not `Sendable` because `PDFDestination` is a class. Use this from the
    /// same thread that opened the document.
    public struct OutlineNavNode {
        public let title: String
        public let level: Int
        public let startPage: Int
        public let endPage: Int
        public let destination: PDFDestination?

        public init(title: String, level: Int, startPage: Int, endPage: Int, destination: PDFDestination?) {
            self.title = title
            self.level = level
            self.startPage = startPage
            self.endPage = endPage
            self.destination = destination
        }
    }

    public static func outlineForUI(from doc: PDFDocument) -> [OutlineNavNode]? {
        guard let flat = walkOutline(doc) else { return nil }
        let ends = computeEndPages(for: flat, pageCount: doc.pageCount)
        return zip(flat, ends).map { entry, endPage in
            OutlineNavNode(
                title: entry.title,
                level: entry.level,
                startPage: entry.startPage,
                endPage: endPage,
                destination: entry.destination
            )
        }
    }

    private struct OutlineRaw {
        let title: String
        let level: Int
        let startPage: Int
        let destination: PDFDestination?
    }

    private static func walkOutline(_ doc: PDFDocument) -> [OutlineRaw]? {
        guard let root = doc.outlineRoot, root.numberOfChildren > 0 else { return nil }
        var flat: [OutlineRaw] = []
        collect(root, level: 1, doc: doc, into: &flat)
        return flat.isEmpty ? nil : flat
    }

    private static func computeEndPages(for flat: [OutlineRaw], pageCount: Int) -> [Int] {
        var ends: [Int] = []
        ends.reserveCapacity(flat.count)
        for (i, entry) in flat.enumerated() {
            var endPage = pageCount
            for j in (i + 1)..<flat.count where flat[j].level <= entry.level {
                endPage = max(entry.startPage, flat[j].startPage - 1)
                break
            }
            ends.append(endPage)
        }
        return ends
    }

    private static func collect(
        _ outline: PDFOutline,
        level: Int,
        doc: PDFDocument,
        into flat: inout [OutlineRaw]
    ) {
        for i in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: i) else { continue }
            let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let dest = child.destination
            let pageIndex0 = dest?.page.flatMap { doc.index(for: $0) }
            let ownStartPage: Int?
            if let p0 = pageIndex0, p0 >= 0, p0 < doc.pageCount {
                ownStartPage = p0 + 1
            } else {
                ownStartPage = nil
            }

            // Reserve the parent slot before recursing so we can backfill
            // startPage from the first descendant if this is a container
            // bookmark with no destination of its own (common in books and
            // some publisher PDFs — would otherwise be dropped, taking the
            // section access for the parent with it).
            let placeholderIndex = flat.count
            let appendedPlaceholder = !title.isEmpty
            if appendedPlaceholder {
                flat.append(OutlineRaw(
                    title: title,
                    level: level,
                    startPage: ownStartPage ?? 0,
                    destination: dest
                ))
            }
            let firstChildIndex = flat.count
            collect(child, level: level + 1, doc: doc, into: &flat)
            let descendantsAdded = flat.count - firstChildIndex

            if appendedPlaceholder, ownStartPage == nil {
                if descendantsAdded > 0 {
                    // Container without its own destination: borrow startPage
                    // from the first descendant that survived the recursion.
                    flat[placeholderIndex] = OutlineRaw(
                        title: title,
                        level: level,
                        startPage: flat[firstChildIndex].startPage,
                        destination: dest
                    )
                } else {
                    // Truly empty container — no own destination and no
                    // descendants with destinations. Drop the orphan so it
                    // doesn't show up as a section pointing nowhere.
                    flat.remove(at: placeholderIndex)
                }
            }
        }
    }

    // MARK: - text extraction

    public static func extractText(
        at url: URL,
        selection: Selection,
        maxChars: Int = 50_000
    ) throws -> TextResult {
        let doc = try openDocument(at: url)
        let pageCount = doc.pageCount
        let sections = outline(from: doc)

        let candidatePages: [Int]
        let echo: SelectionEcho

        switch selection {
        case .allPages:
            candidatePages = Array(1...max(1, pageCount))
            echo = SelectionEcho(mode: .all, pages: nil, requested: nil, matchedSections: nil, unmatched: nil)

        case .pages(let ranges):
            candidatePages = pagesInRanges(ranges, pageCount: pageCount)
            echo = SelectionEcho(
                mode: .page,
                pages: formatRanges(ranges),
                requested: nil,
                matchedSections: nil,
                unmatched: nil
            )

        case .pagesString(let raw):
            let ranges = try parsePageRange(raw, pageCount: pageCount)
            candidatePages = pagesInRanges(ranges, pageCount: pageCount)
            echo = SelectionEcho(
                mode: .page,
                pages: formatRanges(ranges),
                requested: nil,
                matchedSections: nil,
                unmatched: nil
            )

        case .sections(let queries):
            guard let sections, !sections.isEmpty else {
                throw ExtractError.noOutline
            }
            let (matched, unmatched) = resolveSections(queries, in: sections)
            var set = Set<Int>()
            for s in matched {
                if s.startPage < 1 || s.startPage > pageCount { continue }
                let lo = max(1, s.startPage)
                let hi = min(pageCount, s.endPage)
                if lo > hi { continue }
                for p in lo...hi { set.insert(p) }
            }
            candidatePages = set.sorted()
            echo = SelectionEcho(
                mode: .section,
                pages: nil,
                requested: queries,
                matchedSections: matched.map(\.title),
                unmatched: unmatched.isEmpty ? [] : unmatched
            )
        }

        var collected: [PageContent] = []
        var total = 0
        var truncated = false
        for p in candidatePages {
            guard let page = doc.page(at: p - 1) else { continue }
            let text = page.string ?? ""
            if !collected.isEmpty, total + text.count > maxChars {
                truncated = true
                break
            }
            let path = sections.flatMap { sectionPath(forPage: p, in: $0) } ?? []
            collected.append(PageContent(index: p, text: text, sectionPath: path))
            total += text.count
        }

        return TextResult(
            pageCount: pageCount,
            selection: echo,
            pages: collected,
            truncated: truncated,
            hasTextLayer: sampleHasTextLayer(doc: doc)
        )
    }

    /// Substring (case-insensitive) match of `queries` against `sections[].title`.
    /// Returns the matched sections (deduped, in flat-list order) and the queries that matched no title.
    public static func resolveSections(
        _ queries: [String],
        in sections: [Section]
    ) -> (matched: [Section], unmatched: [String]) {
        var matchedIdx = Set<Int>()
        var unmatched: [String] = []
        for query in queries {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let needle = trimmed.lowercased()
            var didMatch = false
            for (idx, s) in sections.enumerated() {
                if s.title.lowercased().contains(needle) {
                    matchedIdx.insert(idx)
                    didMatch = true
                }
            }
            if !didMatch { unmatched.append(query) }
        }
        let matched = matchedIdx.sorted().map { sections[$0] }
        return (matched, unmatched)
    }

    /// Breadcrumb from outermost containing section down to the deepest one whose
    /// `[startPage, endPage]` covers `page`. When two sections at the same level
    /// both cover the page (e.g. siblings starting on the same page in the outline),
    /// the later one (in flat order) wins.
    public static func sectionPath(forPage page: Int, in sections: [Section]) -> [String] {
        guard !sections.isEmpty else { return [] }
        var maxLevel = 0
        for s in sections where s.level > maxLevel { maxLevel = s.level }
        if maxLevel == 0 { return [] }

        var path: [String] = []
        for level in 1...maxLevel {
            var match: Section?
            for s in sections where s.level == level && s.startPage <= page && page <= s.endPage {
                match = s
            }
            if let m = match { path.append(m.title) } else { break }
        }
        return path
    }

    // MARK: - page rendering

    public static func renderPage(
        at url: URL,
        page: Int,
        scale: CGFloat = 2.0,
        maxBytes: Int = 2_000_000,
        format: Format = .jpeg
    ) throws -> PageImage {
        let doc = try openDocument(at: url)
        guard page >= 1, page <= doc.pageCount, let pdfPage = doc.page(at: page - 1) else {
            throw ExtractError.pageOutOfRange(page)
        }

        let pageBounds = pdfPage.bounds(for: .mediaBox)
        let widthPx = max(1, Int((pageBounds.width * scale).rounded()))
        let heightPx = max(1, Int((pageBounds.height * scale).rounded()))

        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = widthPx * 4
        guard let ctx = CGContext(
            data: nil,
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ExtractError.renderFailed }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))
        ctx.scaleBy(x: scale, y: scale)
        pdfPage.draw(with: .mediaBox, to: ctx)

        guard let cgImage = ctx.makeImage() else { throw ExtractError.renderFailed }
        let rep = NSBitmapImageRep(cgImage: cgImage)

        switch format {
        case .jpeg:
            for q in [0.9, 0.75, 0.6, 0.45] {
                let props: [NSBitmapImageRep.PropertyKey: Any] = [
                    .compressionFactor: NSNumber(value: q)
                ]
                guard let data = rep.representation(using: .jpeg, properties: props) else {
                    throw ExtractError.renderFailed
                }
                if data.count <= maxBytes {
                    return PageImage(
                        page: page,
                        mimeType: "image/jpeg",
                        data: data,
                        widthPx: widthPx,
                        heightPx: heightPx,
                        qualityUsed: q
                    )
                }
            }
            throw ExtractError.maxBytesExceeded(maxBytes)

        case .png:
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw ExtractError.renderFailed
            }
            if data.count > maxBytes { throw ExtractError.maxBytesExceeded(maxBytes) }
            return PageImage(
                page: page,
                mimeType: "image/png",
                data: data,
                widthPx: widthPx,
                heightPx: heightPx,
                qualityUsed: nil
            )
        }
    }

    // MARK: - helpers

    /// Single entry point for opening a PDF for any of the public extractors.
    /// `PDFDocument(url:)` returns nil for missing/unreadable/corrupt — we map
    /// that to `cannotOpen` rather than pre-checking with `FileManager`, which
    /// would race with concurrent deletes (TOCTOU).
    private static func openDocument(at url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ExtractError.cannotOpen(url.path) }
        if doc.isLocked { throw ExtractError.encrypted }
        return doc
    }

    private static func pagesInRanges(_ ranges: [ClosedRange<Int>], pageCount: Int) -> [Int] {
        var set = Set<Int>()
        for r in ranges {
            let lo = max(1, r.lowerBound)
            let hi = min(pageCount, r.upperBound)
            if lo > hi { continue }
            for p in lo...hi { set.insert(p) }
        }
        return set.sorted()
    }

    /// Samples first/middle/last page; returns true if any sample yields non-empty text.
    private static func sampleHasTextLayer(doc: PDFDocument) -> Bool {
        let count = doc.pageCount
        guard count > 0 else { return false }
        let indices: [Int]
        if count == 1 {
            indices = [0]
        } else if count == 2 {
            indices = [0, 1]
        } else {
            indices = [0, count / 2, count - 1]
        }
        for i in indices {
            if let p = doc.page(at: i),
               let s = p.string,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    /// Parse a page-range string like `"1-3"`, `"1-3,8-10"`, `"12-"`.
    /// Open-ended ranges (`12-`) need `pageCount` to resolve; pass it in.
    public static func parsePageRange(_ raw: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ExtractError.invalidPageRange(raw) }
        var result: [ClosedRange<Int>] = []
        for part in trimmed.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if let single = Int(token) {
                if single < 1 { throw ExtractError.invalidPageRange(raw) }
                result.append(single...single)
                continue
            }
            let halves = token.split(separator: "-", omittingEmptySubsequences: false)
            guard halves.count == 2 else { throw ExtractError.invalidPageRange(raw) }
            let loStr = halves[0].trimmingCharacters(in: .whitespaces)
            let hiStr = halves[1].trimmingCharacters(in: .whitespaces)
            let lo: Int
            let hi: Int
            if loStr.isEmpty {
                lo = 1
            } else {
                guard let n = Int(loStr), n >= 1 else { throw ExtractError.invalidPageRange(raw) }
                lo = n
            }
            if hiStr.isEmpty {
                hi = pageCount
            } else {
                guard let n = Int(hiStr), n >= 1 else { throw ExtractError.invalidPageRange(raw) }
                hi = n
            }
            if lo > hi { throw ExtractError.invalidPageRange(raw) }
            result.append(lo...hi)
        }
        if result.isEmpty { throw ExtractError.invalidPageRange(raw) }
        return result
    }

    private static func formatRanges(_ ranges: [ClosedRange<Int>]) -> String {
        ranges.map { r in r.lowerBound == r.upperBound ? "\(r.lowerBound)" : "\(r.lowerBound)-\(r.upperBound)" }
            .joined(separator: ",")
    }
}
#endif // canImport(PDFKit)
