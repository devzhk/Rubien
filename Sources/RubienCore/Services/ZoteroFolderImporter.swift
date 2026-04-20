import Foundation

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
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }

        let bibURL = try locateBibFile(in: folderURL)
        let content: String
        do {
            content = try String(contentsOf: bibURL, encoding: .utf8)
        } catch {
            throw Error.bibReadFailed(bibURL, underlying: error)
        }

        // Fail fast on a bad property target BEFORE we start copying PDFs —
        // otherwise e.g. `--property Year` throws `unsupportedPropertyType` from
        // inside the write transaction and leaves orphan files on disk.
        if let target = propertyTarget {
            try db.validatePropertyTarget(target)
        }

        let entries = BibTeXImporter.parseWithAttachments(content)
        guard !entries.isEmpty else {
            return Result(imported: 0, attached: 0, missingPDFs: [], duplicatesSkipped: 0)
        }

        // Advisory classifier (read-only). Distinguishes DB duplicates whose existing row
        // already has a pdfPath (skip copy — would orphan the existing file) from those
        // that don't (copy — merge will attach), and also catches intra-batch duplicates
        // so two entries sharing the same DOI don't both copy.
        let classifications = try db.classifyImportEntries(entries.map(\.reference))

        var prepared: [Reference] = []
        prepared.reserveCapacity(entries.count)
        var missing: [String] = []
        var attachedCount = 0
        var duplicatesSkipped = 0
        // Track every PDF we copy into the store. If the write transaction
        // throws, we delete these so nothing is left orphaned.
        var copiedPaths: [String] = []

        for (index, entry) in entries.enumerated() {
            var ref = entry.reference
            missing.append(contentsOf: entry.rejectedAttachmentPaths)

            let kind = classifications[index]
            if kind != .fresh { duplicatesSkipped += 1 }

            let shouldCopy: Bool = {
                guard entry.attachmentPaths.first != nil else { return false }
                switch kind {
                case .fresh, .dbDuplicateWithoutPDF: return true
                case .dbDuplicateWithPDF, .intraBatchDuplicate: return false
                }
            }()

            if shouldCopy, let relPath = entry.attachmentPaths.first {
                let sourceURL = folderURL.appendingPathComponent(relPath)
                if FileManager.default.fileExists(atPath: sourceURL.path) {
                    do {
                        let stored = try PDFService.importPDF(from: sourceURL)
                        ref.pdfPath = stored
                        copiedPaths.append(stored)
                        attachedCount += 1
                    } catch {
                        missing.append(relPath)
                    }
                } else {
                    missing.append(relPath)
                }
            }
            prepared.append(ref)
        }

        let outcome: (count: Int, ids: [Int64])
        do {
            outcome = try db.batchImportReferences(prepared, stamping: propertyTarget)
        } catch {
            for path in copiedPaths { PDFService.deletePDF(at: path) }
            throw error
        }

        return Result(
            imported: outcome.count,
            attached: attachedCount,
            missingPDFs: missing,
            duplicatesSkipped: duplicatesSkipped
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
