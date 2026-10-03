import Foundation
import GRDB

/// Device-local reader state, bound to the immutable attachment bytes.
public enum ReferenceAttachmentPosition: Codable, Equatable, Sendable {
    case pdf(pageIndex: Int)
    case markdown(fraction: Double)

    public var kind: String {
        switch self { case .pdf: return "pdf"; case .markdown: return "markdown" }
    }

    private var isValid: Bool {
        switch self {
        case .pdf(let page): return page >= 0
        case .markdown(let fraction): return fraction.isFinite && (0...1).contains(fraction)
        }
    }

    public static func load(attachment: ReferenceAttachment, database: AppDatabase) throws -> Self? {
        try database.dbWriter.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT s.* FROM attachmentReaderState s
                JOIN referenceAttachment a ON a.syncId=s.attachmentSyncId
                WHERE a.syncId=? AND a.deletedAt IS NULL AND s.contentHash=?
                    AND s.readerKind=? AND s.positionVersion=1
                """, arguments: [attachment.syncId, attachment.contentHash, attachment.kind]),
                  let data = (row["positionJSON"] as String).data(using: .utf8),
                  let position = try? JSONDecoder().decode(Self.self, from: data),
                  position.kind == attachment.kind, position.isValid else { return nil }
            return position
        }
    }

    public func save(attachment: ReferenceAttachment, database: AppDatabase) throws {
        guard isValid, kind == attachment.kind else { throw ReferenceAttachmentAnnotationError.invalidAnchor }
        let json = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        try database.dbWriter.write { db in
            // A reader that closes after removal must not recreate local state.
            try db.execute(sql: """
                INSERT INTO attachmentReaderState
                    (attachmentSyncId, contentHash, readerKind, positionVersion, positionJSON)
                SELECT syncId, contentHash, kind, 1, ? FROM referenceAttachment
                WHERE syncId=? AND contentHash=? AND deletedAt IS NULL
                ON CONFLICT(attachmentSyncId) DO UPDATE SET
                    contentHash=excluded.contentHash, readerKind=excluded.readerKind,
                    positionVersion=1, positionJSON=excluded.positionJSON
                """, arguments: [json, attachment.syncId, attachment.contentHash])
        }
    }
}
