import Foundation
import GRDB
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum WebContentRepresentationError: LocalizedError, Equatable {
    case htmlUnavailable

    public var errorDescription: String? {
        switch self {
        case .htmlUnavailable:
            return "HTML is unavailable because this reference was imported as Markdown."
        }
    }
}

extension AppDatabase {
    /// Returns a web body in the requested representation. HTML-backed clips
    /// are projected to Markdown once and cached locally; Markdown imports are
    /// already agent-ready and bypass the cache.
    public func webContentRepresentation(
        referenceId: Int64,
        source: Reference.DecodedWebContent,
        format: Reference.WebContentFormat
    ) throws -> Reference.DecodedWebContent {
        switch (source.format, format) {
        case (.markdown, .markdown), (.html, .html):
            return source
        case (.markdown, .html):
            throw WebContentRepresentationError.htmlUnavailable
        case (.html, .markdown):
            break
        }

        let hash = Self.webContentSourceHash(source.body)
        if let cached: String = try dbWriter.read({ db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT markdown
                    FROM webContentMarkdownCache
                    WHERE referenceId = ?
                      AND sourceHash = ?
                      AND converterVersion = ?
                    """,
                arguments: [referenceId, hash, HTMLToMarkdownConverter.version]
            )
        }) {
            return Reference.DecodedWebContent(body: cached, format: .markdown)
        }

        let markdown = HTMLToMarkdownConverter.convert(source.body)
        // A cache failure must not turn readable library content into a failed
        // agent request (the reference may have been deleted concurrently).
        try? dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO webContentMarkdownCache
                        (referenceId, sourceHash, converterVersion, markdown)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(referenceId) DO UPDATE SET
                        sourceHash = excluded.sourceHash,
                        converterVersion = excluded.converterVersion,
                        markdown = excluded.markdown
                    """,
                arguments: [
                    referenceId,
                    hash,
                    HTMLToMarkdownConverter.version,
                    markdown,
                ]
            )
        }
        return Reference.DecodedWebContent(body: markdown, format: .markdown)
    }

    private static func webContentSourceHash(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
