import Foundation

/// Classifies a `create_reference` / `add --source` locator into an import
/// route (spec §5.2). This is the single source of truth both MCP servers
/// route through, so it lives in RubienCore (the URL registry + identifier
/// detector already do). It only *decides* the route — the CLI executes it,
/// because the resolver, materializer, and PDF/Zotero coordinators span
/// RubienCore + RubienPDFKit. Pure except for an injectable filesystem probe,
/// so the routing matrix is unit-testable here (portable, Linux-covered).
public enum ImportRouter {

    /// The chosen route for a locator.
    public enum Route: Equatable, Sendable {
        /// `"-"` — read from stdin (CLI-only; requires a `--format` hint).
        case stdin
        /// An existing local path. `isDirectory` selects folder vs single-file
        /// import. Paths win over identifier-looking strings (§5.2 step 1), so a
        /// DOI-shaped filename that exists on disk routes here.
        case existingPath(isDirectory: Bool)
        /// A resolver route: a bare identifier (DOI / arXiv / PMID / PMCID /
        /// ISBN) or a known paper-host URL. The associated value is the
        /// effective choice after applying the tri-state override: resolver
        /// routes fetch an open-access PDF by default, and an explicit `false`
        /// opts out. The original `impliedDownloadPdf` label is retained for
        /// source compatibility with existing RubienCore clients.
        case resolver(impliedDownloadPdf: Bool)
        /// A URL with a `.pdf` / `.md` / `.markdown` path extension on an
        /// *unregistered* host → download-then-import (materializer) route.
        case downloadImport
        /// The locator is neither a path, a resolvable URL, nor a recognized
        /// identifier. `reason` is a caller-facing message.
        case unroutable(reason: String)
    }

    /// Result of a filesystem existence probe.
    public struct PathProbe: Equatable, Sendable {
        public let exists: Bool
        public let isDirectory: Bool
        public init(exists: Bool, isDirectory: Bool) {
            self.exists = exists
            self.isDirectory = isDirectory
        }
    }

    /// Classify `source`. `explicitDownloadPdf` is the caller's tri-state
    /// `downloadPdf` flag (nil = unset); resolver routes default to downloading,
    /// while an explicit `false` opts out. `probe` checks whether a bare
    /// (non-URL) string names an existing local path — defaults to `FileManager`,
    /// and is injectable so the routing matrix runs without touching disk.
    public static func classify(
        source rawSource: String,
        explicitDownloadPdf: Bool? = nil,
        probe: (String) -> PathProbe = ImportRouter.defaultProbe
    ) -> Route {
        // Normalize the locator the way `ImportSourceMaterializer` does before it
        // acts (`ImportSourceMaterializer.swift:123`): trim surrounding whitespace
        // so an MCP source — no shell to strip it — classifies the same as the
        // materializer would import it.
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let downloadPdf = explicitDownloadPdf != false

        // Step 0: stdin (CLI-only).
        if source == "-" { return .stdin }

        // Step 1: an existing local path wins over any identifier shape. Only a
        // bare path (no explicit `scheme://`) is probed as a filename — an
        // `http://…` string is never treated as a local path. The reverse
        // escape hatch for identifier-shaped filenames is `./10.1234/foo`.
        if !hasURLScheme(source) {
            // Expand a leading `~` for the probe, matching the materializer
            // (`ImportSourceMaterializer.swift:176`) — an MCP source like
            // `~/Downloads/paper.pdf` has no shell to expand it, so probing the
            // raw string would miss the file and misroute it as unroutable.
            let probePath = (source as NSString).expandingTildeInPath
            let p = probe(probePath)
            if p.exists { return .existingPath(isDirectory: p.isDirectory) }
        }

        // Step 2: an http/https URL.
        if let url = URL(string: source),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            if KnownPaperHost.classify(url) != nil {
                // Registered paper host → resolver route (incl. the resolver's
                // own PDF-URL → landing rewrite). All resolver routes download
                // by default unless the caller explicitly opts out.
                return .resolver(impliedDownloadPdf: downloadPdf)
            }
            if ImportSourceKind(pathExtension: pathExtension(of: url)) != nil {
                // Unregistered host with a file extension → download-import
                // (e.g. `arxiv.org/pdf/…` — arXiv is not in the registry).
                return .downloadImport
            }
            // Unregistered host, no file extension → last-chance identifier
            // extraction (a `doi.org/…` or `arxiv.org/abs/…` URL).
            if MetadataFetcher.extractIdentifier(from: source) != nil {
                return .resolver(impliedDownloadPdf: downloadPdf)
            }
            return .unroutable(reason: Self.unroutableURLMessage)
        }

        // Step 3: a bare string — identifier patterns only.
        if MetadataFetcher.extractIdentifier(from: source) != nil {
            return .resolver(impliedDownloadPdf: downloadPdf)
        }
        return .unroutable(reason: Self.unroutableBareMessage)
    }

    // MARK: - Helpers

    /// Default filesystem probe (`FileManager`). Overridden in tests.
    public static let defaultProbe: (String) -> PathProbe = { path in
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return PathProbe(exists: exists, isDirectory: isDir.boolValue)
    }

    /// True only for explicit `scheme://` syntax. A bare `scheme:` prefix does
    /// NOT count so POSIX filenames whose relative form starts with `name:`
    /// (`notes:2026.md` parses a scheme of "notes") stay local paths — matching
    /// the CLI's existing `Import.hasURLScheme` contract.
    static func hasURLScheme(_ input: String) -> Bool {
        guard let scheme = URL(string: input)?.scheme else { return false }
        return input.prefix(scheme.count + 3).lowercased() == scheme.lowercased() + "://"
    }

    private static func pathExtension(of url: URL) -> String {
        url.pathExtension.lowercased()
    }

    static let unroutableURLMessage =
        "Could not route this URL. Supported: known paper-host pages, and direct .pdf / .md / .markdown file URLs. Remote .bib / .ris URLs are not supported — download the file first, then import it."
    static let unroutableBareMessage =
        "Could not recognize an identifier (DOI, arXiv, PMID, PMCID, or ISBN), a URL, or an existing file path. If you meant a local file, check that the path exists (use ./name for an identifier-looking filename)."
}
