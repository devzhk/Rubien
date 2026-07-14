import Foundation
import RubienCore

public struct ZoteroFolderImportPlan: Sendable {
    public struct Entry: Identifiable, Sendable {
        public let id: UUID
        public let sourceIndex: Int
        public let reference: Reference
        /// Concrete source URLs aligned with `attachmentPaths`. Export-folder
        /// plans resolve relative BibTeX paths here; local-API plans carry the
        /// file URLs exposed by Zotero.
        public let attachmentURLs: [URL]
        public let attachmentPaths: [String]
        public let rejectedAttachmentPaths: [String]
        public let missingAttachmentPaths: [String]
        public let annotations: [PDFAnnotationDraft]
        public let skippedAnnotationCount: Int

        init(sourceIndex: Int, entry: BibTeXEntry, folderURL: URL) {
            self.id = UUID()
            self.sourceIndex = sourceIndex
            self.reference = entry.reference
            self.attachmentURLs = entry.attachmentPaths.map {
                folderURL.appendingPathComponent($0)
            }
            self.attachmentPaths = entry.attachmentPaths
            self.rejectedAttachmentPaths = entry.rejectedAttachmentPaths
            self.missingAttachmentPaths = zip(attachmentURLs, entry.attachmentPaths).compactMap { url, path in
                FileManager.default.fileExists(atPath: url.path) ? nil : path
            }
            self.annotations = []
            self.skippedAnnotationCount = 0
        }

        init(
            sourceIndex: Int,
            reference: Reference,
            attachmentURLs: [URL],
            attachmentPaths: [String],
            rejectedAttachmentPaths: [String] = [],
            missingAttachmentPaths: [String] = [],
            annotations: [PDFAnnotationDraft] = [],
            skippedAnnotationCount: Int = 0
        ) {
            precondition(
                attachmentURLs.count == attachmentPaths.count,
                "attachment URLs and display paths must stay aligned"
            )
            self.id = UUID()
            self.sourceIndex = sourceIndex
            self.reference = reference
            self.attachmentURLs = attachmentURLs
            self.attachmentPaths = attachmentPaths
            self.rejectedAttachmentPaths = rejectedAttachmentPaths
            self.missingAttachmentPaths = missingAttachmentPaths
            self.annotations = annotations
            self.skippedAnnotationCount = skippedAnnotationCount
        }
    }

    /// Present only for user-selected export folders that need their security
    /// scope reacquired during commit. A local Zotero plan already carries
    /// concrete file URLs and has no folder security scope.
    public let folderURL: URL?
    public let sourceName: String
    public let propertyTarget: ZoteroImportPropertyTarget?
    public let entries: [Entry]

    init(
        folderURL: URL?,
        sourceName: String,
        propertyTarget: ZoteroImportPropertyTarget?,
        entries: [Entry]
    ) {
        self.folderURL = folderURL
        self.sourceName = sourceName
        self.propertyTarget = propertyTarget
        self.entries = entries
    }
}

/// Imports a Zotero "Export Collection… with files" folder into Rubien:
/// parses the bundled `.bib`, copies referenced PDFs into the PDF store,
/// inserts/merges the references, and optionally stamps a property value
/// (e.g. the folder name on every imported reference).
public enum ZoteroFolderImporter {
    public struct Result: Equatable, Sendable {
        public let imported: Int
        public let attached: Int
        public let missingPDFs: [String]
        public let duplicatesSkipped: Int
        public let annotationsImported: Int
        public let annotationsSkipped: Int

        public init(
            imported: Int,
            attached: Int,
            missingPDFs: [String],
            duplicatesSkipped: Int,
            annotationsImported: Int = 0,
            annotationsSkipped: Int = 0
        ) {
            self.imported = imported
            self.attached = attached
            self.missingPDFs = missingPDFs
            self.duplicatesSkipped = duplicatesSkipped
            self.annotationsImported = annotationsImported
            self.annotationsSkipped = annotationsSkipped
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case bibFileNotFound(in: URL)
        case multipleBibFiles(in: URL, paths: [String])
        case bibReadFailed(URL, underlying: Swift.Error)

        public var errorDescription: String? {
            switch self {
            case .bibFileNotFound(let url):
                return "No .bib file found at the root of \(url.path)"
            case .multipleBibFiles(let url, let paths):
                return "Multiple .bib files found at the root of \(url.path): \(paths.joined(separator: ", "))"
            case .bibReadFailed(let url, let underlying):
                return "Failed to read \(url.lastPathComponent): \(underlying.localizedDescription)"
            }
        }
    }

    public static func importFolder(
        at folderURL: URL,
        db: AppDatabase,
        propertyTarget: ZoteroImportPropertyTarget?
    ) throws -> Result {
        let plan = try prepareFolder(at: folderURL, db: db, propertyTarget: propertyTarget)
        return try commit(
            plan: plan,
            selectedEntryIDs: Set(plan.entries.map(\.id)),
            db: db
        )
    }

    public static func prepareFolder(
        at folderURL: URL,
        db: AppDatabase,
        propertyTarget: ZoteroImportPropertyTarget?
    ) throws -> ZoteroFolderImportPlan {
#if canImport(Darwin)
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
#endif

        let bibURL = try locateBibFile(in: folderURL)
        let content: String
        do {
            content = try String(contentsOf: bibURL, encoding: .utf8)
        } catch {
            throw Error.bibReadFailed(bibURL, underlying: error)
        }

        // Preserve the immediate import's error ordering while still rejecting
        // a bad target before review begins or any PDFs can be copied.
        if let propertyTarget {
            try db.validatePropertyTarget(propertyTarget)
        }

        let entries = BibTeXImporter.parseWithAttachments(content)
        return ZoteroFolderImportPlan(
            folderURL: folderURL,
            sourceName: folderURL.lastPathComponent,
            propertyTarget: propertyTarget,
            entries: entries.enumerated().map { index, entry in
                ZoteroFolderImportPlan.Entry(
                    sourceIndex: index,
                    entry: entry,
                    folderURL: folderURL
                )
            }
        )
    }

    public static func commit(
        plan: ZoteroFolderImportPlan,
        selectedEntryIDs: Set<UUID>,
        db: AppDatabase
    ) throws -> Result {
#if canImport(Darwin)
        let accessing = plan.folderURL?.startAccessingSecurityScopedResource() ?? false
        defer { if accessing { plan.folderURL?.stopAccessingSecurityScopedResource() } }
#endif

        let entries = plan.entries
            .filter { selectedEntryIDs.contains($0.id) }
            .sorted { $0.sourceIndex < $1.sourceIndex }
        guard !entries.isEmpty else {
            return Result(imported: 0, attached: 0, missingPDFs: [], duplicatesSkipped: 0)
        }

        // Advisory classifier (read-only). Distinguishes DB duplicates whose existing row
        // already has a PDF (preserve it) from those that don't (copy — merge
        // will attach). Intra-batch duplicate candidates are copied
        // defensively so a later valid PDF can win when an earlier source is
        // missing; the transaction reports the one adopted copy and the rest
        // are deleted below.
        let classifications = try db.classifyImportEntries(entries.map(\.reference))

        var prepared: [Reference] = []
        prepared.reserveCapacity(entries.count)
        // Per-prepared-row PDF filename, populated only when we actually copied
        // a file for that row. Aligned 1:1 with `prepared`; passed to
        // `batchImportReferences(pdfFilenames:)` so the cache rows are written
        // inside the same transaction as the reference inserts.
        var copiedFilenames: [String?] = []
        copiedFilenames.reserveCapacity(entries.count)
        var annotationDrafts: [[PDFAnnotationDraft]] = []
        annotationDrafts.reserveCapacity(entries.count)
        var annotationAnchorFilenames: [String?] = []
        annotationAnchorFilenames.reserveCapacity(entries.count)
        var missing: [String] = []
        var duplicatesSkipped = 0
        var annotationsSkipped = entries.reduce(0) { $0 + $1.skippedAnnotationCount }
        var existingPDFHashes: [String: String] = [:]
        // Track every PDF we copy into the store. If the write transaction
        // throws, we delete these so nothing is left orphaned.
        var copiedPaths: [String] = []

        for (index, entry) in entries.enumerated() {
            let ref = entry.reference
            missing.append(contentsOf: entry.rejectedAttachmentPaths)

            let kind = classifications[index]
            if kind != .fresh { duplicatesSkipped += 1 }

            let shouldCopy: Bool = {
                guard entry.attachmentURLs.first != nil else { return false }
                switch kind {
                case .fresh, .dbDuplicateWithoutPDF, .intraBatchDuplicate: return true
                case .dbDuplicateWithPDF: return false
                }
            }()

            var copiedThisRow: String? = nil
            if shouldCopy, let sourceURL = entry.attachmentURLs.first {
                let attachmentLabel = entry.attachmentPaths.first ?? sourceURL.lastPathComponent
                if FileManager.default.fileExists(atPath: sourceURL.path) {
                    do {
                        let stored = try PDFService.importPDF(from: sourceURL)
                        copiedThisRow = stored
                        copiedPaths.append(stored)
                    } catch {
                        missing.append(attachmentLabel)
                    }
                } else {
                    missing.append(attachmentLabel)
                }
            }
            prepared.append(ref)
            copiedFilenames.append(copiedThisRow)

            var annotationAnchorFilename = copiedThisRow
            if case .dbDuplicateWithPDF(let existingFilename) = kind,
               annotationAnchorFilename == nil,
               !entry.annotations.isEmpty,
               let sourceURL = entry.attachmentURLs.first,
               let sourceHash = try? PDFContentHasher.sha256(of: sourceURL) {
                let existingURL = AppDatabase.pdfStorageURL.appendingPathComponent(existingFilename)
                let existingHash: String?
                if let cached = existingPDFHashes[existingFilename] {
                    existingHash = cached
                } else if FileManager.default.fileExists(atPath: existingURL.path),
                          let hash = try? PDFContentHasher.sha256(of: existingURL) {
                    existingPDFHashes[existingFilename] = hash
                    existingHash = hash
                } else {
                    existingHash = nil
                }
                if let existingHash, sourceHash == existingHash {
                    annotationAnchorFilename = existingFilename
                }
            }

            if annotationAnchorFilename != nil {
                annotationDrafts.append(entry.annotations)
            } else {
                annotationDrafts.append([])
                annotationsSkipped += entry.annotations.count
            }
            annotationAnchorFilenames.append(annotationAnchorFilename)
        }

        // Reference inserts + pdfCache attaches share one write transaction
        // so a partial failure can't leave references without their cache
        // rows. The `pdfFilenames` array aligns 1:1 with `prepared` and the
        // attach is skipped per-row when the destination already has a cache
        // entry — preserves prior attachments on merge, matching the
        // "don't orphan an existing PDF" invariant the classifier enforces.
        let outcome: (
            count: Int,
            ids: [Int64],
            annotationsInserted: Int,
            annotationsSkipped: Int,
            attachedPDFFilenames: [String]
        )
        do {
            outcome = try db.batchImportReferences(
                prepared,
                stamping: plan.propertyTarget,
                pdfFilenames: copiedFilenames,
                pdfAnnotationDrafts: annotationDrafts,
                annotationAnchorFilenames: annotationAnchorFilenames
            )
        } catch {
            for path in copiedPaths { PDFService.deletePDF(at: path) }
            throw error
        }

        let adoptedPDFs = Set(outcome.attachedPDFFilenames)
        for path in copiedPaths where !adoptedPDFs.contains(path) {
            PDFService.deletePDF(at: path)
        }
        annotationsSkipped += outcome.annotationsSkipped

        return Result(
            imported: outcome.count,
            attached: adoptedPDFs.count,
            missingPDFs: missing,
            duplicatesSkipped: duplicatesSkipped,
            annotationsImported: outcome.annotationsInserted,
            annotationsSkipped: annotationsSkipped
        )
    }

    private static func locateBibFile(in folderURL: URL) throws -> URL {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let bibs = contents.filter { $0.pathExtension.lowercased() == "bib" }
        switch bibs.count {
        case 0:
            throw Error.bibFileNotFound(in: folderURL)
        case 1:
            return bibs[0]
        default:
            throw Error.multipleBibFiles(in: folderURL, paths: bibs.map(\.lastPathComponent))
        }
    }
}
