import Foundation

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

        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? ""
        let isPDF = contentType.contains("application/pdf")
            || remote.pathExtension.lowercased() == "pdf"
        if !isPDF {
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

    public static func downloadPDF(for reference: Reference) async throws -> String {
        let pdfURL = try await resolvePDFURL(for: reference)
        let suggestedName = suggestedFilename(for: reference)
        return try await download(from: pdfURL, suggestedFilename: suggestedName)
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
            let last = doi.components(separatedBy: "/").last ?? doi
            return last
        }
        return "download"
    }
}
