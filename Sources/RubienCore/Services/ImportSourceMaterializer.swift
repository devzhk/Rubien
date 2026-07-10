import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The supported file kinds that can enter the shared import flow.
public enum ImportSourceKind: String, Sendable, Equatable {
    case pdf
    case markdown
}

/// A validated import file. Remote files are copied into a temporary
/// directory owned by this value; local files remain owned by their caller.
public struct MaterializedImportSource: Sendable {
    public let input: String
    public let fileURL: URL
    public let kind: ImportSourceKind
    public let temporaryDirectoryURL: URL?

    init(
        input: String,
        fileURL: URL,
        kind: ImportSourceKind,
        temporaryDirectoryURL: URL?
    ) {
        self.input = input
        self.fileURL = fileURL
        self.kind = kind
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    /// Removes only the temporary directory created while materializing a
    /// remote source. Local source files are never removed.
    public func cleanup() {
        guard let temporaryDirectoryURL else { return }
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
    }
}

/// Validates local paths and HTTP(S) file URLs before they enter an import
/// coordinator. Remote sources are copied into a caller-cleanable directory.
public enum ImportSourceMaterializer {
    public enum LocalPathPolicy: Sendable {
        /// Accept local paths only when they are absolute (the app's typed-path
        /// contract).
        case requireAbsolute
        /// Resolve a relative local path from a caller-supplied file URL (the
        /// CLI contract).
        case resolveRelative(to: URL)
    }

    public enum MaterializationError: LocalizedError {
        case emptyInput
        case unsupportedScheme(String)
        case invalidHTTPURL
        case unsupportedExtension(String)
        case relativePathNotAllowed
        case notRegularFile(String)
        case markdownTooLarge(Int64)
        case invalidHTTPResponse
        case httpFailure(Int)
        case unsupportedMarkdownContentType(String?)
        case invalidMarkdownEncoding
        case temporaryWriteFailed(Error)
        case downloadFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "Enter a local PDF or Markdown path, or an HTTP(S) URL"
            case .unsupportedScheme(let scheme):
                return "Unsupported URL scheme: \(scheme). Use HTTP or HTTPS"
            case .invalidHTTPURL:
                return "Invalid HTTP(S) URL"
            case .unsupportedExtension(let ext):
                return ext.isEmpty
                    ? "Unsupported import file type (missing extension)"
                    : "Unsupported import file type: .\(ext)"
            case .relativePathNotAllowed:
                return "Local paths must be absolute"
            case .notRegularFile(let path):
                return "Local path is not a regular file: \(path)"
            case .markdownTooLarge:
                return "Markdown files must not exceed 50 MB"
            case .invalidHTTPResponse:
                return "Server returned an invalid HTTP response"
            case .httpFailure(let statusCode):
                return "Download failed (HTTP \(statusCode))"
            case .unsupportedMarkdownContentType(let contentType):
                let value = contentType?.isEmpty == false ? contentType! : "missing Content-Type"
                return "Server returned unsupported Markdown content type: \(value)"
            case .invalidMarkdownEncoding:
                return "Markdown response is not valid UTF-8"
            case .temporaryWriteFailed(let error):
                return "Failed to create temporary import file: \(error.localizedDescription)"
            case .downloadFailed(let error):
                return "Failed to download import source: \(error.localizedDescription)"
            }
        }
    }

    private static let maximumMarkdownBytes: Int64 = 50 * 1024 * 1024
    private static let markdownMediaTypes: Set<String> = [
        "text/markdown",
        "text/x-markdown",
        "text/plain",
        "application/markdown",
        "application/octet-stream",
    ]

    /// Materializes one local file path or direct HTTP(S) source URL.
    ///
    /// Input whitespace is trimmed. A leading `~` in a local path is expanded
    /// before the selected local-path policy is applied.
    public static func materialize(
        _ input: String,
        localPathPolicy: LocalPathPolicy,
        session: URLSession = .shared
    ) async throws -> MaterializedImportSource {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            throw MaterializationError.emptyInput
        }

        if let candidateURL = URL(string: trimmedInput), let scheme = candidateURL.scheme {
            let normalizedScheme = scheme.lowercased()
            guard normalizedScheme == "http" || normalizedScheme == "https" else {
                throw MaterializationError.unsupportedScheme(scheme)
            }
            guard candidateURL.host != nil else {
                throw MaterializationError.invalidHTTPURL
            }
            return try await materializeRemote(
                input: trimmedInput,
                url: candidateURL,
                session: session
            )
        }

        return try materializeLocal(input: trimmedInput, policy: localPathPolicy)
    }

    /// Validates a local file URL while retaining the exact URL supplied by the
    /// caller. AppKit open panels can return a security-scoped URL whose access
    /// capability is not recoverable by rebuilding one from `url.path`.
    public static func materialize(localFileURL: URL) throws -> MaterializedImportSource {
        guard localFileURL.isFileURL else {
            throw MaterializationError.notRegularFile(localFileURL.path)
        }
        return try materializeValidatedLocal(
            input: localFileURL.path,
            fileURL: localFileURL
        )
    }

    private static func materializeLocal(
        input: String,
        policy: LocalPathPolicy
    ) throws -> MaterializedImportSource {
        let expandedPath = (input as NSString).expandingTildeInPath
        let localURL: URL
        if expandedPath.hasPrefix("/") {
            localURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
        } else {
            switch policy {
            case .requireAbsolute:
                throw MaterializationError.relativePathNotAllowed
            case .resolveRelative(let baseURL):
                guard baseURL.isFileURL else {
                    throw MaterializationError.notRegularFile(baseURL.path)
                }
                localURL = baseURL
                    .appendingPathComponent(expandedPath)
                    .standardizedFileURL
            }
        }

        return try materializeValidatedLocal(input: input, fileURL: localURL)
    }

    private static func materializeValidatedLocal(
        input: String,
        fileURL: URL
    ) throws -> MaterializedImportSource {
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else {
            throw MaterializationError.notRegularFile(fileURL.path)
        }

        let kind = try kind(for: fileURL)
        if kind == .markdown, Int64(values?.fileSize ?? 0) > maximumMarkdownBytes {
            throw MaterializationError.markdownTooLarge(Int64(values?.fileSize ?? 0))
        }

        return MaterializedImportSource(
            input: input,
            fileURL: fileURL,
            kind: kind,
            temporaryDirectoryURL: nil
        )
    }

    private static func materializeRemote(
        input: String,
        url: URL,
        session: URLSession
    ) async throws -> MaterializedImportSource {
        let kind = try kind(for: url)
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RubienImport-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw MaterializationError.temporaryWriteFailed(error)
        }

        do {
            let fileURL: URL
            switch kind {
            case .markdown:
                fileURL = try await downloadMarkdown(
                    from: url,
                    destinationDirectory: temporaryDirectoryURL,
                    session: session
                )
            case .pdf:
                fileURL = try await PDFDownloadService.downloadTemporary(
                    from: url,
                    suggestedFilename: url.lastPathComponent,
                    destinationDirectory: temporaryDirectoryURL,
                    session: session
                )
            }
            return MaterializedImportSource(
                input: input,
                fileURL: fileURL,
                kind: kind,
                temporaryDirectoryURL: temporaryDirectoryURL
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
            throw error
        }
    }

    private static func kind(for url: URL) throws -> ImportSourceKind {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return .pdf
        case "md", "markdown":
            return .markdown
        default:
            throw MaterializationError.unsupportedExtension(ext)
        }
    }

    private static func downloadMarkdown(
        from remoteURL: URL,
        destinationDirectory: URL,
        session: URLSession
    ) async throws -> URL {
        let (downloadedURL, response) = try await download(from: remoteURL, session: session)
        guard let httpResponse = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw MaterializationError.invalidHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw MaterializationError.httpFailure(httpResponse.statusCode)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
        guard isSupportedMarkdownContentType(contentType) else {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw MaterializationError.unsupportedMarkdownContentType(contentType)
        }

        let fileSize = Int64((try? downloadedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard fileSize <= maximumMarkdownBytes else {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw MaterializationError.markdownTooLarge(fileSize)
        }
        guard (try? String(contentsOf: downloadedURL, encoding: .utf8)) != nil else {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw MaterializationError.invalidMarkdownEncoding
        }

        return try moveDownloadedFile(
            downloadedURL,
            to: destinationDirectory.appendingPathComponent(remoteURL.lastPathComponent)
        )
    }

    private static func download(
        from remoteURL: URL,
        session: URLSession
    ) async throws -> (URL, URLResponse) {
        do {
            return try await session.download(from: remoteURL)
        } catch {
            throw MaterializationError.downloadFailed(error)
        }
    }

    private static func moveDownloadedFile(_ downloadedURL: URL, to destinationURL: URL) throws -> URL {
        do {
            try FileManager.default.moveItem(at: downloadedURL, to: destinationURL)
            return destinationURL
        } catch {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw MaterializationError.temporaryWriteFailed(error)
        }
    }

    private static func isSupportedMarkdownContentType(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let mediaType = contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType.map(markdownMediaTypes.contains) ?? false
    }

}
