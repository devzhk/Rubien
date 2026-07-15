import ArgumentParser
import Foundation
import RubienCore
import RubienPDFKit

/// Execution for `add --source` (spec §5): the CLI glue that runs the route
/// `ImportRouter` picked and assembles the unified `create_reference` envelope
/// (§5.4). Routing lives in RubienCore; this owns only argv→engine wiring and
/// the DTO mapping (`ItemOutcome.Reference` → `ReferenceDTO`) after commit.
enum CreateReferenceSource {
    typealias PDF = PDFDownloadStatusDTO
    typealias Item = CreateReferenceItem<ReferenceDTO, PDF>
    typealias Envelope = CreateReferenceEnvelope<ReferenceDTO, PDF>
    /// An outcome paired with an optional PDF-download status (resolver route).
    typealias OutcomePair = (outcome: ItemOutcome, pdf: PDF?)

    /// Entry point from `add --source`.
    static func run(
        source rawSource: String,
        downloadPdf: Bool?,
        format: String?,
        property: String?,
        value: String?
    ) async throws {
        // Normalize the locator once (trim surrounding whitespace + expand a
        // leading `~`), matching `ImportSourceMaterializer` — an MCP source has
        // no shell to do it. The router, the executors, and the `input`
        // provenance then all see the same resolved path.
        let source = (rawSource.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let route = ImportRouter.classify(source: source, explicitDownloadPdf: downloadPdf)

        // An unroutable locator is a source problem, not a usage error — emit one
        // synthetic failed item (the envelope, all-failed → stderr, exit nonzero).
        if case .unroutable(let reason) = route {
            try emit([(failed(source, reason), nil)], diagnostics: nil)
            return
        }

        // Reject options that don't apply to the resolved route (§5.1) — silent
        // no-ops train agents wrong. Usage errors, not envelope items.
        try validateOptions(route: route, downloadPdf: downloadPdf, format: format, property: property, value: value)

        switch route {
        case .stdin:
            try runStdin(source: source, format: format)
        case .existingPath(let isDirectory):
            try await runExistingPath(source: source, isDirectory: isDirectory, format: format, property: property, value: value)
        case .resolver(let impliedDownloadPdf):
            try await runResolver(source: source, downloadPdf: downloadPdf, impliedDownloadPdf: impliedDownloadPdf)
        case .downloadImport:
            try await runDownloadImport(source: source)
        case .unroutable:
            break  // handled above
        }
    }

    // MARK: - Inline routes (`add --bibtex` / `add --title`)

    /// Inline `--bibtex` (§5.3): persists PER ENTRY, continuing past entry
    /// failures — deliberately different from the file route's batch-atomic
    /// semantics, and a decision-logged behavior change vs the old
    /// stop-on-first-throw loop. Zero parsed entries → one synthetic failed
    /// item whose `input` is the constant `bibtex` (never the payload);
    /// per-entry provenance is `bibtex[<ordinal>]`.
    static func runInlineBibTeX(_ bib: String) throws {
        let parsed = BibTeXImporter.parse(bib)
        guard !parsed.isEmpty else {
            try emit([(failed("bibtex", "No valid BibTeX entries found"), nil)], diagnostics: nil)
            return
        }
        let pairs: [OutcomePair] = parsed.enumerated().map { i, ref in
            let input = "bibtex[\(i)]"
            do {
                var mutableRef = ref
                let saveResult = try AppDatabase.shared.saveReference(&mutableRef)
                return (ItemOutcome(
                    reference: mutableRef,
                    disposition: saveResult == .existing ? .existing : .created,
                    input: input
                ), nil)
            } catch {
                return (failed(input, error.localizedDescription), nil)
            }
        }
        try emit(pairs, diagnostics: nil)
    }

    /// Manual `--title` route: one minimal row; `input` is the title string
    /// (§5.3 provenance). A persistence/readback failure is emitted AS the
    /// unified failed-item envelope (not raw ArgumentParser stderr), matching
    /// every other route's contract.
    static func runTitle(_ title: String) throws {
        let outcome: ItemOutcome
        do {
            var ref = Reference(title: title)
            let saveResult = try AppDatabase.shared.saveReference(&ref)
            outcome = ItemOutcome(
                reference: ref,
                disposition: saveResult == .existing ? .existing : .created,
                input: title
            )
        } catch {
            try emit([(failed(title, error.localizedDescription), nil)], diagnostics: nil)
            return
        }
        try emit([(outcome, nil)], diagnostics: nil)
    }

    // MARK: - Option applicability (§5.1)

    private static func validateOptions(
        route: ImportRouter.Route,
        downloadPdf: Bool?,
        format: String?,
        property: String?,
        value: String?
    ) throws {
        // `downloadPdf` (either polarity) is meaningful only on the resolver route.
        if downloadPdf != nil {
            if case .resolver = route {} else {
                printJSONError("--download-pdf / --no-download-pdf requires an identifier or paper-URL source")
                throw ExitCode.failure
            }
        }
        // `--format` is a file/stdin hint; `--property` / `--value` stamp a folder.
        switch route {
        case .resolver, .downloadImport, .unroutable:
            if format != nil {
                printJSONError("--format applies to a file or stdin source only")
                throw ExitCode.failure
            }
            if property != nil || value != nil {
                printJSONError("--property / --value apply to a folder source only")
                throw ExitCode.failure
            }
        case .existingPath(let isDirectory):
            if !isDirectory, property != nil || value != nil {
                printJSONError("--property / --value apply to a folder source only")
                throw ExitCode.failure
            }
        case .stdin:
            if property != nil || value != nil {
                printJSONError("--property / --value apply to a folder source only")
                throw ExitCode.failure
            }
        }
    }

    // MARK: - Resolver route (identifier / paper URL)

    private static func runResolver(source: String, downloadPdf: Bool?, impliedDownloadPdf: Bool) async throws {
        // Fetch → verify → save → optionally attach the OA PDF. `impliedDownloadPdf`
        // already respects an explicit `--no-download-pdf` (the router cleared it).
        let wantPDF = (downloadPdf == true) || impliedDownloadPdf
        do {
            let (fetched, scrapedPDFURL) = try await MetadataFetcher.fetchWithScrapedPDFURL(from: source)
            var ref = MetadataVerifier.manuallyVerified(fetched, reviewedBy: "cli-source")
            let saveResult = try AppDatabase.shared.saveReference(&ref)
            let pdf = wantPDF ? await attemptPDFDownload(for: ref, pdfURLOverride: scrapedPDFURL) : nil
            let outcome = ItemOutcome(
                reference: ref,
                disposition: saveResult == .existing ? .existing : .created,
                input: source
            )
            try emit([(outcome, pdf)], diagnostics: nil)
        } catch let exit as ExitCode {
            // `emit`'s own all-failed exit (or a DTO-readback that flipped the
            // envelope to failure) is the intended nonzero path — never wrap it.
            throw exit
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MetadataFetcher.FetchError {
            try emit([(failed(source, error.errorDescription ?? String(describing: error)), nil)], diagnostics: nil)
        } catch {
            // Any other non-cancellation error (network URLError, persistence,
            // DTO readback) is a source-level failure → one synthetic failed item
            // in the full envelope, not an escape to ArgumentParser's raw stderr
            // (spec §5.3).
            try emit([(failed(source, error.localizedDescription), nil)], diagnostics: nil)
        }
    }

    // MARK: - Download-import route (PDF / Markdown file URL)

    private static func runDownloadImport(source: String) async throws {
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let materialized: MaterializedImportSource
        do {
            materialized = try await ImportSourceMaterializer.materialize(
                source,
                localPathPolicy: .resolveRelative(to: workingDirectory)
            )
        } catch {
            try emit([(failed(source, error.localizedDescription), nil)], diagnostics: CreateReferenceDiagnostics(file: source))
            return
        }
        defer { materialized.cleanup() }

        switch materialized.kind {
        case .pdf:
            do {
                let detailed = try await PDFImportCoordinator.importPDFDetailed(
                    from: materialized.fileURL,
                    database: AppDatabase.shared
                )
                try emitPDFImport(detailed, source: source)
            } catch {
                try emit([(failed(source, error.localizedDescription), nil)], diagnostics: CreateReferenceDiagnostics(file: source))
            }
        case .markdown:
            let content: String
            do {
                content = try String(contentsOf: materialized.fileURL, encoding: .utf8)
            } catch {
                try emit([(failed(source, "Cannot read \(materialized.fileURL.lastPathComponent): \(error.localizedDescription)"), nil)],
                         diagnostics: CreateReferenceDiagnostics(file: source))
                return
            }
            let reference = MarkdownImporter.parse(
                content,
                filename: materialized.fileURL.deletingPathExtension().lastPathComponent
            )
            try persistBatch([(input: source, reference: reference)], mergePolicy: .markdownFillOnly,
                             diagnostics: CreateReferenceDiagnostics(file: source))
        }
    }

    // MARK: - stdin route (CLI only)

    private static func runStdin(source: String, format: String?) throws {
        guard let fmt = format?.lowercased() else {
            printJSONError("--format (bib, ris, or md) is required when reading from stdin")
            throw ExitCode.failure
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else {
            printJSONError("Failed to decode stdin as UTF-8")
            throw ExitCode.failure
        }
        try runFileContent(content: content, format: fmt, provenancePath: nil, source: source)
    }

    // MARK: - Existing local path route

    private static func runExistingPath(
        source: String,
        isDirectory: Bool,
        format: String?,
        property: String?,
        value: String?
    ) async throws {
        if isDirectory {
            try runFolder(source: source, format: format, property: property, value: value)
            return
        }
        // Single file. Route the PDF decision by the ACTUAL path extension — a
        // `.pdf` is ALWAYS the PDF coordinator and `--format` can never
        // reinterpret it, matching the legacy `import` router
        // (`shouldMaterializeImportSource`). `--format` only overrides the
        // text-format selection among bib/ris/md, so a `.bib`/`.ris` never routes
        // into the PDF coordinator and a `.pdf --format bib` never parses as text.
        let url = URL(fileURLWithPath: source)
        if url.pathExtension.lowercased() == "pdf" {
            do {
                let detailed = try await PDFImportCoordinator.importPDFDetailed(from: url, database: AppDatabase.shared)
                try emitPDFImport(detailed, source: source)
            } catch {
                try emit([(failed(source, error.localizedDescription), nil)], diagnostics: CreateReferenceDiagnostics(file: source))
            }
            return
        }
        let ext = format?.lowercased() ?? url.pathExtension.lowercased()
        let content: String
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? UInt64, size > 50 * 1024 * 1024 {
                try emit([(failed(source, "File exceeds 50 MB limit (\(size / 1024 / 1024) MB)"), nil)],
                         diagnostics: CreateReferenceDiagnostics(file: source))
                return
            }
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            try emit([(failed(source, "Cannot read \(url.lastPathComponent): \(error.localizedDescription)"), nil)],
                     diagnostics: CreateReferenceDiagnostics(file: source))
            return
        }
        try runFileContent(content: content, format: ext, provenancePath: source, source: source)
    }

    /// Shared BibTeX/RIS/Markdown content handling for the file + stdin routes.
    /// BibTeX/RIS persist batch-atomically (§5.3 file semantics); a zero-parsed
    /// source is one synthetic failed item.
    private static func runFileContent(content: String, format: String, provenancePath: String?, source: String) throws {
        switch format {
        case "bib", "bibtex":
            try persistParsedEntries(
                BibTeXImporter.parse(content), kind: "bibtex",
                provenancePath: provenancePath, source: source, mergePolicy: .standard,
                emptyError: "No valid BibTeX entries found"
            )
        case "ris":
            try persistParsedEntries(
                RISImporter.parse(content), kind: "ris",
                provenancePath: provenancePath, source: source, mergePolicy: .standard,
                emptyError: "No valid RIS entries found"
            )
        case "md", "markdown":
            let basename = provenancePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            let reference = MarkdownImporter.parse(content, filename: basename)
            try persistBatch([(input: source, reference: reference)], mergePolicy: .markdownFillOnly,
                             diagnostics: CreateReferenceDiagnostics(file: source))
        default:
            printJSONError("Unsupported format: .\(format). Use bib, ris, or md")
            throw ExitCode.failure
        }
    }

    /// BibTeX/RIS batch: zero entries → one synthetic failed item; otherwise
    /// persist in one transaction, mapping a batch-throw to one failed item per
    /// parsed entry (shared error) so counts stay meaningful (§5.3).
    private static func persistParsedEntries(
        _ references: [Reference],
        kind: String,
        provenancePath: String?,
        source: String,
        mergePolicy: ImportMergePolicy,
        emptyError: String
    ) throws {
        // Preserve legacy `import`'s `"file": <path>` field under `diagnostics.file`
        // (§5.4) on success AND failure — the locator for a file, `"-"` for stdin.
        let diagnostics = CreateReferenceDiagnostics(file: source)
        guard !references.isEmpty else {
            try emit([(failed(source, emptyError), nil)], diagnostics: diagnostics)
            return
        }
        let entries: [AppDatabase.DetailedImportEntry] = references.enumerated().map { i, ref in
            let provenance = provenancePath.map { "\($0)#\(kind)[\(i)]" } ?? "\(kind)[\(i)]"
            return (input: provenance, reference: ref)
        }
        do {
            let outcomes = try AppDatabase.shared.batchImportReferencesDetailed(entries, mergePolicy: mergePolicy)
            try emit(outcomes.map { ($0, nil) }, diagnostics: diagnostics)
        } catch {
            // Batch persistence failed → one failed item per parsed entry.
            let failedItems = entries.map { (failed($0.input, error.localizedDescription), nil as PDF?) }
            try emit(failedItems, diagnostics: diagnostics)
        }
    }

    /// Single-entry / small markdown batch persist that maps a batch-throw to a
    /// failed item.
    private static func persistBatch(
        _ entries: [AppDatabase.DetailedImportEntry],
        mergePolicy: ImportMergePolicy,
        diagnostics: CreateReferenceDiagnostics
    ) throws {
        do {
            let outcomes = try AppDatabase.shared.batchImportReferencesDetailed(entries, mergePolicy: mergePolicy)
            try emit(outcomes.map { ($0, nil) }, diagnostics: diagnostics)
        } catch {
            let failedItems = entries.map { (failed($0.input, error.localizedDescription), nil as PDF?) }
            try emit(failedItems, diagnostics: diagnostics)
        }
    }

    // MARK: - Folder route

    private static func runFolder(source: String, format: String?, property: String?, value: String?) throws {
        let folderURL = URL(fileURLWithPath: source)
        let regularFiles: [URL]
        do {
            regularFiles = try Self.topLevelRegularFiles(in: folderURL)
        } catch {
            // Unenumerable folder → source-level failed item (§5.3).
            try emit([(failed(source, "Cannot read folder \(folderURL.lastPathComponent): \(error.localizedDescription)"), nil)],
                     diagnostics: nil)
            return
        }
        let hasBib = regularFiles.contains { $0.pathExtension.lowercased() == "bib" }
        let hasMD = regularFiles.contains { ["md", "markdown"].contains($0.pathExtension.lowercased()) }

        // Format disambiguation, mirroring the legacy `import` folder router.
        if let forced = format?.lowercased() {
            switch forced {
            case "bib", "bibtex":
                // Missing the requested type is a source-level failure → one
                // synthetic item in the unified envelope (§5.3), matching the
                // unforced (false,false) branch below — not a raw `{"error"}`.
                guard hasBib else {
                    try emit([(failed(source, "No .bib files found in folder"), nil)], diagnostics: nil)
                    return
                }
                try runZoteroFolder(source: source, folderURL: folderURL, property: property, value: value)
            case "md", "markdown":
                guard hasMD else {
                    try emit([(failed(source, "No .md files found in folder"), nil)], diagnostics: nil)
                    return
                }
                try runMarkdownFolder(source: source, folderURL: folderURL, files: regularFiles, property: property, value: value)
            default:
                printJSONError("Unsupported folder format: \(forced). Use bib or md.")
                throw ExitCode.failure
            }
            return
        }

        switch (hasBib, hasMD) {
        case (true, true):
            printJSONError("Ambiguous folder: contains both .bib and .md. Pass --format bib or --format md to choose.")
            throw ExitCode.failure
        case (true, false):
            try runZoteroFolder(source: source, folderURL: folderURL, property: property, value: value)
        case (false, true):
            try runMarkdownFolder(source: source, folderURL: folderURL, files: regularFiles, property: property, value: value)
        case (false, false):
            // No `.bib`/`.md` in the folder is a source-level failure → one
            // synthetic failed item in the unified envelope on stderr (§5.3/§5.4),
            // not a raw `{"error"}` that bypasses the items/summary shape.
            try emit([(failed(source, "No importable files found (expected .bib or .md)"), nil)], diagnostics: nil)
        }
    }

    private static func runZoteroFolder(source: String, folderURL: URL, property: String?, value: String?) throws {
        let db = AppDatabase.shared
        let propertyName = property ?? PropertyDefinition.tagsPropertyName
        let stampValue = value ?? folderURL.lastPathComponent
        guard let propDef = try db.findPropertyDefinition(byName: propertyName), let propId = propDef.id else {
            printJSONError("Property not found: '\(propertyName)'")
            throw ExitCode.failure
        }
        let target = ZoteroImportPropertyTarget(propertyId: propId, value: stampValue)
        do {
            let detailed = try ZoteroFolderImporter.importFolderDetailed(at: folderURL, db: db, propertyTarget: target)
            let diagnostics = CreateReferenceDiagnostics(
                file: source,
                property: propertyName,
                value: stampValue,
                attached: detailed.result.attached,
                duplicatesSkipped: detailed.result.duplicatesSkipped,
                missingPDFs: detailed.result.missingPDFs
            )
            // A `.bib` that parsed to zero entries would forward `items: []` — no
            // cardinality, no explanation. Synthesize one failed item so the
            // all-failed envelope carries both (§5.3); exit stays nonzero.
            guard !detailed.items.isEmpty else {
                try emit([(failed(source, "No entries found in the Zotero .bib export"), nil)], diagnostics: diagnostics)
                return
            }
            try emit(detailed.items.map { ($0, nil) }, diagnostics: diagnostics)
        } catch let error as ZoteroImportError {
            printJSONError(error.errorDescription ?? "\(error)")
            throw ExitCode.failure
        } catch let error as ZoteroFolderImporter.Error {
            // Root `.bib` read failure = source-level failure (§5.3).
            try emit([(failed(source, error.errorDescription ?? "\(error)"), nil)],
                     diagnostics: CreateReferenceDiagnostics(file: source, property: propertyName, value: stampValue))
        }
    }

    private static func runMarkdownFolder(source: String, folderURL: URL, files: [URL], property: String?, value: String?) throws {
        let db = AppDatabase.shared
        let propertyName = property ?? PropertyDefinition.tagsPropertyName
        let stampValue = value ?? folderURL.lastPathComponent
        guard let propDef = try db.findPropertyDefinition(byName: propertyName), let propId = propDef.id else {
            printJSONError("Property not found: '\(propertyName)'")
            throw ExitCode.failure
        }
        let mdFiles = files
            .filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Per-file read failures continue (failed items, file-path provenance);
        // successfully-read files persist as one batch (§5.3).
        var readEntries: [AppDatabase.DetailedImportEntry] = []
        var failedItems: [OutcomePair] = []
        for url in mdFiles {
            let provenance = url.path
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size <= 50 * 1024 * 1024, let content = try? String(contentsOf: url, encoding: .utf8) {
                readEntries.append((input: provenance, reference: MarkdownImporter.parse(
                    content, filename: url.deletingPathExtension().lastPathComponent
                )))
            } else {
                failedItems.append((failed(provenance, "Failed to read \(url.lastPathComponent)"), nil))
            }
        }

        let target = ZoteroImportPropertyTarget(propertyId: propId, value: stampValue)
        let diagnostics = CreateReferenceDiagnostics(file: source, property: propertyName, value: stampValue)
        guard !readEntries.isEmpty else {
            // Every candidate .md failed to read → all-failed envelope.
            try emit(failedItems, diagnostics: diagnostics)
            return
        }
        do {
            let outcomes = try db.batchImportReferencesDetailed(readEntries, stamping: target, mergePolicy: .markdownFillOnly)
            try emit(outcomes.map { ($0, nil) } + failedItems, diagnostics: diagnostics)
        } catch {
            // Batch persistence failed → every read entry becomes a failed item.
            let persistFailures = readEntries.map { (failed($0.input, error.localizedDescription), nil as PDF?) }
            try emit(persistFailures + failedItems, diagnostics: diagnostics)
        }
    }

    // MARK: - Assembly + helpers

    /// Build the unified envelope from outcome/PDF pairs and route diagnostics,
    /// then emit it (spec §5.4). Partial/full success → stdout, exit 0; all
    /// failed → the full envelope on stderr, exit nonzero (§5.3).
    private static func emit(_ pairs: [OutcomePair], diagnostics: CreateReferenceDiagnostics?) throws {
        let summary = ImportSummary(dispositions: pairs.map { $0.outcome.disposition })
        // Notify up front — BEFORE the fallible DTO assembly below — so a
        // committed mutation always triggers a library refresh even if building
        // the response DTO then throws (a post-commit readback failure must not
        // swallow the notification). Guarded by `succeeded > 0`, so an all-failed
        // envelope stays silent.
        if summary.succeeded > 0 { notifyLibraryChanged() }
        let items: [Item] = try pairs.map { pair in
            let dto = try pair.outcome.reference.map { try referenceDTO(for: $0) }
            return Item(
                reference: dto,
                status: pair.outcome.disposition,
                intakeId: pair.outcome.intakeId,
                input: pair.outcome.input,
                pdfDownload: pair.pdf,
                error: pair.outcome.error
            )
        }
        let diag = (diagnostics?.isEmpty == false) ? diagnostics : nil
        let envelope = Envelope(items: items, summary: summary, diagnostics: diag)
        if summary.isFailure {
            printJSONErrorEnvelope(envelope)
            throw ExitCode.failure
        }
        printJSON(envelope)
    }

    private static func failed(_ input: String, _ error: String) -> ItemOutcome {
        ItemOutcome(disposition: .failed, input: input, error: error)
    }

    private static func pdfOutcome(_ detailed: PDFImportDetailedOutcome, input: String) -> ItemOutcome {
        switch detailed.outcome {
        case .imported(let ref):
            return ItemOutcome(reference: ref, disposition: detailed.disposition, input: input)
        case .queued(let intake):
            return ItemOutcome(reference: nil, disposition: .queued, intakeId: intake.id, input: input)
        }
    }

    /// Emit a successful PDF import. Wakes the upload-queue drainer here, but
    /// leaves the library-changed notification to `emit` — which fires it exactly
    /// once for a succeeded item — so a PDF import notifies the library once, not
    /// twice (`postImportNotifications` + `emit` would otherwise both fire it).
    private static func emitPDFImport(_ detailed: PDFImportDetailedOutcome, source: String) throws {
        detailed.outcome.postImportNotifications(
            libraryChanged: {},
            uploadQueueChanged: PDFUploadQueueBroadcaster.postChangeNotification
        )
        try emit([(pdfOutcome(detailed, input: source), nil)], diagnostics: CreateReferenceDiagnostics(file: source))
    }

    /// Top-level, regular (non-directory, non-symlink), non-hidden files. Kept
    /// the folder routing for `add --source` (formerly the legacy `import`
    /// subcommand, now removed in the phase-D cutover).
    private static func topLevelRegularFiles(in folderURL: URL) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return entries.filter { url in
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return (vals?.isRegularFile ?? false) && !(vals?.isSymbolicLink ?? false)
        }
    }
}
