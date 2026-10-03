import Foundation
import GRDB

public enum ReferenceAttachmentAnchor: Codable, Sendable {
    case pdf(pageIndex: Int, rects: [PDFAnnotationRect])
    case markdown(text: String, prefix: String?, suffix: String?)

    public var kind: String {
        switch self { case .pdf: return "pdf"; case .markdown: return "markdown" }
    }

    func validate() throws {
        switch self {
        case .pdf(let page, let rects):
            guard page >= 0, !rects.isEmpty, rects.allSatisfy({
                $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite
                    && $0.width > 0 && $0.height > 0
            }) else { throw ReferenceAttachmentAnnotationError.invalidAnchor }
        case .markdown(let text, _, _):
            guard !text.isEmpty else { throw ReferenceAttachmentAnnotationError.invalidAnchor }
        }
    }
}

public enum ReferenceAttachmentAnnotationError: Error {
    case invalidAnchor, wrongDocumentKind, missingAnnotation, removed
}

public struct ReferenceAttachmentAnnotation: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "attachmentAnnotation"
    public var id: Int64?
    public var syncId: String
    public var attachmentId: Int64?
    public var attachmentSyncId: String
    public var contentHash: String
    public var type: String?
    public var color: String?
    public var selectedText: String?
    public var noteText: String?
    public var anchorKind: String?
    public var anchorVersion: Int?
    public var anchorJSON: String?
    public var dateCreated: Date
    public var dateModified: Date
    public var deletedAt: Date?

    public init(
        id: Int64? = nil, syncId: String, attachmentId: Int64?, attachmentSyncId: String,
        contentHash: String, type: String?, color: String?, selectedText: String?,
        noteText: String?, anchorKind: String?, anchorVersion: Int?, anchorJSON: String?,
        dateCreated: Date, dateModified: Date, deletedAt: Date?
    ) {
        self.id = id
        self.syncId = syncId
        self.attachmentId = attachmentId
        self.attachmentSyncId = attachmentSyncId
        self.contentHash = contentHash
        self.type = type
        self.color = color
        self.selectedText = selectedText
        self.noteText = noteText
        self.anchorKind = anchorKind
        self.anchorVersion = anchorVersion
        self.anchorJSON = anchorJSON
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.deletedAt = deletedAt
    }

    public var anchor: ReferenceAttachmentAnchor? {
        guard deletedAt == nil, anchorVersion == 1,
              let data = anchorJSON?.data(using: .utf8),
              let anchor = try? JSONDecoder().decode(ReferenceAttachmentAnchor.self, from: data),
              anchor.kind == anchorKind, (try? anchor.validate()) != nil else { return nil }
        return anchor
    }
}

extension ReferenceAttachmentStore {
    public func updateAnnotationColor(syncId: String, color: String) throws {
        try database.dbWriter.write { db in
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM attachmentAnnotation a
                JOIN referenceAttachment p ON p.syncId=a.attachmentSyncId
                WHERE a.syncId=? AND a.deletedAt IS NULL AND p.deletedAt IS NULL)
                """, arguments: [syncId]) == true else {
                throw ReferenceAttachmentAnnotationError.removed
            }
            try db.execute(sql: "UPDATE attachmentAnnotation SET color=?, dateModified=? WHERE syncId=?",
                           arguments: [color, Date(), syncId])
        }
    }

    public func annotations(attachmentSyncId: String) throws -> [ReferenceAttachmentAnnotation] {
        try database.dbWriter.read { db in
            try ReferenceAttachmentAnnotation.fetchAll(db, sql: """
                SELECT a.* FROM attachmentAnnotation a
                JOIN referenceAttachment p ON p.syncId=a.attachmentSyncId
                WHERE p.syncId=? AND p.deletedAt IS NULL AND a.deletedAt IS NULL
                ORDER BY a.dateCreated, a.syncId
                """, arguments: [attachmentSyncId])
        }
    }

    @discardableResult
    public func addAnnotation(
        attachmentSyncId: String, type: AnnotationType, anchor: ReferenceAttachmentAnchor,
        selectedText: String? = nil, noteText: String? = nil, color: String = "#FFDE59"
    ) throws -> ReferenceAttachmentAnnotation {
        try anchor.validate()
        let json = String(decoding: try JSONEncoder().encode(anchor), as: UTF8.self)
        return try database.dbWriter.write { db in
            guard let parent = try ReferenceAttachment.fetchOne(db, sql: "SELECT * FROM referenceAttachment WHERE syncId=?",
                                                               arguments: [attachmentSyncId]) else {
                throw ReferenceAttachmentError.missingAttachment
            }
            guard parent.deletedAt == nil else { throw ReferenceAttachmentError.removed }
            guard parent.kind == anchor.kind else { throw ReferenceAttachmentAnnotationError.wrongDocumentKind }
            let now = Date()
            var record = ReferenceAttachmentAnnotation(
                id: nil, syncId: SyncIdentifier.random(), attachmentId: parent.id,
                attachmentSyncId: parent.syncId, contentHash: parent.contentHash,
                type: type.rawValue, color: color, selectedText: selectedText, noteText: noteText,
                anchorKind: anchor.kind, anchorVersion: 1, anchorJSON: json,
                dateCreated: now, dateModified: now, deletedAt: nil)
            try record.insert(db)
            record.id = db.lastInsertedRowID
            return record
        }
    }

    public func updateAnnotationNote(syncId: String, note: String?) throws {
        try database.dbWriter.write { db in
            guard let record = try ReferenceAttachmentAnnotation.fetchOne(db, sql: "SELECT * FROM attachmentAnnotation WHERE syncId=?",
                                                                         arguments: [syncId]) else {
                throw ReferenceAttachmentAnnotationError.missingAnnotation
            }
            guard record.deletedAt == nil,
                  try Bool.fetchOne(db, sql: "SELECT deletedAt IS NULL FROM referenceAttachment WHERE syncId=?",
                                    arguments: [record.attachmentSyncId]) == true else {
                throw ReferenceAttachmentAnnotationError.removed
            }
            try db.execute(sql: "UPDATE attachmentAnnotation SET noteText=?, dateModified=? WHERE syncId=?",
                           arguments: [note, Date(), syncId])
        }
    }

    public func removeAnnotation(syncId: String) throws {
        try database.dbWriter.write { db in
            guard let record = try ReferenceAttachmentAnnotation.fetchOne(db, sql: "SELECT * FROM attachmentAnnotation WHERE syncId=?",
                                                                         arguments: [syncId]) else {
                throw ReferenceAttachmentAnnotationError.missingAnnotation
            }
            guard record.deletedAt == nil else { return }
            try db.execute(sql: """
                UPDATE attachmentAnnotation SET deletedAt=?, dateModified=?, type=NULL, color=NULL,
                    selectedText=NULL, noteText=NULL, anchorKind=NULL, anchorVersion=NULL, anchorJSON=NULL
                WHERE syncId=?
                """, arguments: [Date(), Date(), syncId])
        }
    }
}
