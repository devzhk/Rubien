import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PDFDownloadService {

    public enum DownloadError: LocalizedError {
        case noIdentifier
        case noOpenAccessPDF
        case httpFailure(Int)
        case notAPDF
        case writeFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .noIdentifier:
                return "No DOI or arXiv identifier available"
            case .noOpenAccessPDF:
                return "No open-access PDF available"
            case .httpFailure(let code):
                return "Download failed (HTTP \(code))"
            case .notAPDF:
                return "Server returned a non-PDF response"
            case .writeFailed(let error):
                return "Failed to save PDF: \(error.localizedDescription)"
            }
        }
    }

    public static func resolvePDFURL(for reference: Reference) async throws -> URL {
        // 1. arXiv direct — from URL or DataCite DOI
        if let arxivID = extractArxivID(from: reference) {
            return URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")!
        }

        // 2. OpenAlex OA lookup by DOI
        if let doi = reference.doi, !doi.isEmpty {
            if let pdfURL = try await fetchOpenAlexPDFURL(doi: doi) {
                return pdfURL
            }
            throw DownloadError.noOpenAccessPDF
        }

        throw DownloadError.noIdentifier
    }

    public static func download(from remote: URL, suggestedFilename: String) async throws -> String {
        let (tempURL, response) = try await URLSession.shared.download(from: remote)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadError.httpFailure(http.statusCode)
        }

        // Content-Type must claim PDF. The previous OR-on-pathExtension shortcut
        // let bioRxiv withdrawal pages (HTML served at `.full.pdf` with 200) save
        // as fake PDFs. URLSession.shared.download transparently handles
        // Content-Encoding (gzip/br), so the downloaded body is already decoded.
        // Media types are case-insensitive per RFC 7231 §3.1.1.1; lowercase
        // before matching so `Application/PDF` and friends aren't rejected.
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        if !contentType.contains("application/pdf") {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadError.notAPDF
        }

        // Magic-byte sniff: defends against servers that claim application/pdf
        // but actually return HTML/error bodies (CDN intercepts, misconfigured
        // S3). Encrypted and linearized PDFs both start with `%PDF-`.
        if !fileStartsWithPDFMagic(tempURL) {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadError.notAPDF
        }

        let sanitized = suggestedFilename
            .replacingOccurrences(of: #"[^a-zA-Z0-9._-]"#, with: "_", options: .regularExpression)
        let fileName = "\(UUID().uuidString)_\(sanitized).pdf"
        let destURL = AppDatabase.pdfStorageURL.appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(
                at: AppDatabase.pdfStorageURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: tempURL, to: destURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadError.writeFailed(error)
        }

        return fileName
    }

    public static func downloadPDF(
        for reference: Reference,
        overrideURL: String? = nil
    ) async throws -> String {
        let suggestedName = suggestedFilename(for: reference)

        // 0. Caller-supplied override (e.g., scraped paper-URL PDF for a
        // venue page with no DOI). Skip preprint and arXiv/OpenAlex resolution
        // entirely so we honor exactly the URL the resolver chose.
        if let override = overrideURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           let url = URL(string: override) {
            return try await download(from: url, suggestedFilename: suggestedName)
        }

        // 1. Try preprint-server direct (bioRxiv / medRxiv). On any error other
        // than local-write failure or cancellation, fall through so OpenAlex can
        // still try — a 404, HTML stub, or transient transport error on the
        // direct URL doesn't mean OpenAlex won't have an OA copy.
        //
        // Cancellation is special: URLSession's async download propagates Task
        // cancellation as `URLError(.cancelled)`, NOT `CancellationError`. We
        // must catch both, otherwise a cancelled task would silently continue
        // into the OpenAlex fallback and keep doing network work.
        if let preprintURL = preprintServerPDFURL(for: reference) {
            do {
                return try await download(from: preprintURL, suggestedFilename: suggestedName)
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw urlError
            } catch DownloadError.writeFailed(let inner) {
                throw DownloadError.writeFailed(inner)
            } catch {
                // Fall through to arXiv/OpenAlex resolution.
            }
        }

        // 2. Existing path: arXiv-direct or OpenAlex OA lookup.
        let pdfURL = try await resolvePDFURL(for: reference)
        return try await download(from: pdfURL, suggestedFilename: suggestedName)
    }

    /// Read the first 4 bytes of a downloaded file and check for the `%PDF`
    /// magic. Returns false if the file is unreadable or shorter than 4 bytes.
    private static func fileStartsWithPDFMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4)) ?? Data()
        return head == Data([0x25, 0x50, 0x44, 0x46]) // %PDF
    }

    // MARK: - Internal (testable)

    /// Construct a direct PDF URL for bioRxiv / medRxiv preprints. Pure (no
    /// network). Returns nil whenever the reference isn't clearly a bioRxiv /
    /// medRxiv preprint — caller falls back to OpenAlex.
    ///
    /// **Detection signals (in priority order):**
    /// 1. CrossRef-supplied `url` containing `biorxiv.org/` or `medrxiv.org/`.
    ///    Most robust signal — bioRxiv has issued at least two DOI prefixes
    ///    (`10.1101/` and `10.64898/`) and CrossRef doesn't always populate
    ///    `container-title` for `posted-content` records, so URL is the only
    ///    consistently reliable disambiguator. Also naturally rules out Cold
    ///    Spring Harbor journals (Genome Research, RNA, …) which share the
    ///    `10.1101/` prefix but resolve to `*.cshlp.org` URLs.
    /// 2. Fallback: DOI prefix is a known preprint prefix AND
    ///    container-title (journal) names the server. Useful when CrossRef
    ///    didn't populate the URL field.
    internal static func preprintServerPDFURL(for reference: Reference) -> URL? {
        guard let doi = reference.doi, !doi.isEmpty else { return nil }

        let urlLower = reference.url?.lowercased() ?? ""
        if urlLower.contains("biorxiv.org/") {
            return URL(string: "https://www.biorxiv.org/content/\(doi).full.pdf")
        }
        if urlLower.contains("medrxiv.org/") {
            return URL(string: "https://www.medrxiv.org/content/\(doi).full.pdf")
        }

        // Known bioRxiv/medRxiv DOI prefixes. Both registrants are Cold Spring
        // Harbor Laboratory, which also issues `10.1101/` for its journals —
        // hence the journal-name gate below.
        let preprintPrefixes = ["10.1101/", "10.64898/"]
        let doiLower = doi.lowercased()
        guard preprintPrefixes.contains(where: { doiLower.hasPrefix($0) }) else {
            return nil
        }
        let journal = reference.journal?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch journal {
        case "biorxiv":
            return URL(string: "https://www.biorxiv.org/content/\(doi).full.pdf")
        case "medrxiv":
            return URL(string: "https://www.medrxiv.org/content/\(doi).full.pdf")
        default:
            return nil
        }
    }

    // MARK: - Private

    private static func extractArxivID(from reference: Reference) -> String? {
        if let url = reference.url {
            let pattern = #"arxiv\.org/abs/(.+?)(?:\?|$)"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
               let range = Range(match.range(at: 1), in: url) {
                return String(url[range])
            }
        }

        if let doi = reference.doi {
            let lowered = doi.lowercased()
            let prefix = "10.48550/arxiv."
            if lowered.hasPrefix(prefix) {
                var id = String(doi.dropFirst(prefix.count))
                if let vRange = id.range(of: #"v\d+$"#, options: .regularExpression) {
                    id = String(id[id.startIndex..<vRange.lowerBound])
                }
                return id
            }
        }

        return nil
    }

    private static func fetchOpenAlexPDFURL(doi: String) async throws -> URL? {
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let requestURL = URL(string: "https://api.openalex.org/works/doi:\(encoded)?select=best_oa_location,open_access")
        else { return nil }

        var request = URLRequest(url: requestURL)
        let email = MetadataFetcher.contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty, email.contains("@") {
            request.setValue("Rubien/1.0 (mailto:\(email))", forHTTPHeaderField: "User-Agent")
        } else {
            request.setValue("Rubien/1.0", forHTTPHeaderField: "User-Agent")
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let bestOA = json["best_oa_location"] as? [String: Any],
           let pdfStr = bestOA["pdf_url"] as? String,
           let url = URL(string: pdfStr) {
            return url
        }

        if let openAccess = json["open_access"] as? [String: Any],
           let oaStr = openAccess["oa_url"] as? String,
           let url = URL(string: oaStr) {
            return url
        }

        return nil
    }

    private static func suggestedFilename(for reference: Reference) -> String {
        if let arxivID = extractArxivID(from: reference) {
            return "arxiv_\(arxivID)"
        }
        if let doi = reference.doi {
            // Recognize bioRxiv/medRxiv via the same signals as
            // preprintServerPDFURL — URL field first, journal name as fallback.
            let urlLower = reference.url?.lowercased() ?? ""
            let suffix = doi.components(separatedBy: "/").last ?? doi
            if urlLower.contains("biorxiv.org/") { return "biorxiv_\(suffix)" }
            if urlLower.contains("medrxiv.org/") { return "medrxiv_\(suffix)" }
            let journal = reference.journal?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if journal == "biorxiv" { return "biorxiv_\(suffix)" }
            if journal == "medrxiv" { return "medrxiv_\(suffix)" }
            return suffix
        }
        return "download"
    }
}
