#if os(macOS)
import AppKit
import SwiftUI
import Combine
import GRDB
import RubienCore
import RubienPDFKit

enum ReaderDocumentIdentity: Hashable, Codable {
    case reference(Int64)
    case attachment(String)
}

/// Carries verified attachment content and routes all reader writes to its own store.
@MainActor
final class AttachmentReaderDocument: ObservableObject {
    @Published private(set) var attachment: ReferenceAttachment
    let store: ReferenceAttachmentStore
    let fileURL: URL
    let markdown: String?
    let position: ReferenceAttachmentPosition?
    @Published var errorMessage: String?
    @Published private(set) var isRemoved = false
    private var fileLease: AttachmentFileLease?
    private var metadataObservation: AnyCancellable?
    private var pendingWrite: Task<Void, Never>?

    init(attachment: ReferenceAttachment, store: ReferenceAttachmentStore, fileURL: URL,
         markdown: String?, position: ReferenceAttachmentPosition?) {
        self.attachment = attachment
        self.store = store
        self.fileURL = fileURL
        self.markdown = markdown
        self.position = position
        let id = attachment.syncId
        metadataObservation = ValueObservation.tracking { db in
            try ReferenceAttachment.fetchOne(db, sql: "SELECT * FROM referenceAttachment WHERE syncId=?", arguments: [id])
        }.publisher(in: store.database.dbWriter)
            .sink(receiveCompletion: { [weak self] result in
                if case .failure(let error) = result { self?.errorMessage = error.localizedDescription }
            }, receiveValue: { [weak self] item in
                self?.isRemoved = item == nil || item?.deletedAt != nil
                if let item { self?.attachment = item }
            })
    }

    static func open(syncId: String, store: ReferenceAttachmentStore) async throws -> AttachmentReaderDocument {
        let prepared = try await Task.detached(priority: .userInitiated) {
            let lease = try store.acquireFileLease()
            let item = try store.attachment(syncId: syncId)
            guard item.supportedKind != nil else { throw ReferenceAttachmentError.unsupportedFile }
            let url = try store.verifiedFileURL(syncId: syncId)
            let markdown = item.supportedKind == .markdown ? try String(contentsOf: url, encoding: .utf8) : nil
            let position = try ReferenceAttachmentPosition.load(attachment: item, database: store.database)
            return (item, url, markdown, position, lease)
        }.value
        let document = AttachmentReaderDocument(attachment: prepared.0, store: store, fileURL: prepared.1,
                                                markdown: prepared.2, position: prepared.3)
        document.fileLease = prepared.4
        return document
    }

    var annotationPublisher: AnyPublisher<[ReferenceAttachmentAnnotation], Error> {
        let id = attachment.syncId
        let hash = attachment.contentHash
        return ValueObservation.tracking { db in
            try ReferenceAttachmentAnnotation.fetchAll(db, sql: """
                SELECT a.* FROM attachmentAnnotation a
                JOIN referenceAttachment p ON p.syncId=a.attachmentSyncId
                WHERE p.syncId=? AND p.deletedAt IS NULL AND a.deletedAt IS NULL AND a.contentHash=?
                ORDER BY a.dateCreated, a.syncId
                """, arguments: [id, hash])
        }.publisher(in: store.database.dbWriter).eraseToAnyPublisher()
    }

    func perform(_ operation: @escaping @Sendable (ReferenceAttachmentStore) throws -> Void) {
        let previous = pendingWrite
        let store = store
        pendingWrite = Task { [weak self] in
            await previous?.value
            do { try await Task.detached(priority: .userInitiated) { try operation(store) }.value }
            catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func savePosition(_ position: ReferenceAttachmentPosition) {
        let attachment = attachment
        perform { try position.save(attachment: attachment, database: $0.database) }
    }

    func add(type: AnnotationType, anchor: ReferenceAttachmentAnchor, text: String?, note: String?, color: String) {
        let id = attachment.syncId
        perform { try $0.addAnnotation(attachmentSyncId: id, type: type, anchor: anchor,
                                      selectedText: text, noteText: note, color: color) }
    }

    static func pdfAnnotation(_ item: ReferenceAttachmentAnnotation) -> ReaderPDFAnnotation? {
        guard case let .pdf(page, rects) = item.anchor,
              let rawType = item.type, let type = AnnotationType(rawValue: rawType) else { return nil }
        return ReaderPDFAnnotation(id: item.id, syncId: item.syncId, documentID: .attachment(item.attachmentSyncId),
                                   type: type, selectedText: item.selectedText, noteText: item.noteText,
                                   color: item.color ?? "#FFDE59", pageIndex: page, rects: rects.map(\.cgRect),
                                   dateCreated: item.dateCreated, dateModified: item.dateModified)
    }

    static func webAnnotation(_ item: ReferenceAttachmentAnnotation) -> ReaderWebAnnotation? {
        guard case let .markdown(text, prefix, suffix) = item.anchor,
              let rawType = item.type, let type = AnnotationType(rawValue: rawType) else { return nil }
        return ReaderWebAnnotation(id: item.id, syncId: item.syncId, documentID: .attachment(item.attachmentSyncId),
                                   type: type, noteText: item.noteText, color: item.color ?? "#FFDE59",
                                   anchorText: text, prefixText: prefix, suffixText: suffix,
                                   dateCreated: item.dateCreated, dateModified: item.dateModified)
    }
}

/// Attachment windows get their full title from ReaderWindowManager.
struct ReaderNavigationTitle: ViewModifier {
    let title: String
    let isAttachment: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isAttachment { content }
        else { content.navigationTitle(title) }
    }
}

/// Owns the renderer and the document-specific session for either reader kind.
@MainActor
final class ReaderAssistantState: ObservableObject {
    let renderer: ChatTranscriptController?
    let session: ChatSessionController?

    init(reference: Reference, database: AppDatabase = .shared, attachment: AttachmentReaderDocument? = nil) {
        let renderer = ChatTranscriptController()
        self.renderer = renderer
        if let attachment {
            session = ReaderChatSession.makeAttachment(document: attachment, transcript: renderer)
        } else {
            session = ReaderChatSession.make(reference: reference, transcript: renderer, database: database)
        }
    }
}
#endif
