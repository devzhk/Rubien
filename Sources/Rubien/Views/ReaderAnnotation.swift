#if os(macOS)
import Foundation
import RubienCore

// Reader values deliberately have no database persistence conformance.
struct ReaderPDFAnnotation: Identifiable, Codable, Hashable {
    var id: Int64?
    var syncId: String
    let documentID: ReaderDocumentIdentity
    var referenceSyncId: String
    var type: AnnotationType
    var selectedText: String?
    var noteText: String?
    var color: String
    var pageIndex: Int
    var boundsX: Double
    var boundsY: Double
    var boundsWidth: Double
    var boundsHeight: Double
    var rectsData: String
    var dateCreated: Date
    var dateModified: Date

    init(
        id: Int64? = nil,
        syncId: String = SyncIdentifier.random(),
        documentID: ReaderDocumentIdentity,
        referenceSyncId: String = "",
        type: AnnotationType,
        selectedText: String? = nil,
        noteText: String? = nil,
        color: String = "#FFDE59",
        pageIndex: Int,
        rects: [CGRect],
        dateCreated: Date = Date(),
        dateModified: Date = Date()
    ) {
        let standardizedRects = rects.map { $0.standardized }
        let normalizedRects = standardizedRects.filter {
            !$0.isNull && !$0.isEmpty && $0.width > 0 && $0.height > 0
        }
        let union = normalizedRects.unionRect ?? .zero

        self.id = id
        self.syncId = syncId
        self.documentID = documentID
        self.referenceSyncId = referenceSyncId
        self.type = type
        self.selectedText = selectedText
        self.noteText = noteText
        self.color = color
        self.pageIndex = pageIndex
        self.boundsX = union.origin.x
        self.boundsY = union.origin.y
        self.boundsWidth = union.size.width
        self.boundsHeight = union.size.height
        if let data = try? JSONEncoder().encode(normalizedRects.map(PDFAnnotationRect.init)),
           let json = String(data: data, encoding: .utf8) {
            self.rectsData = json
        } else {
            self.rectsData = "[]"
        }
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }

    var rects: [CGRect] {
        guard let data = rectsData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([PDFAnnotationRect].self, from: data)
        else {
            return [unionBounds]
        }

        let rects = decoded.map(\.cgRect).filter { !$0.isNull && !$0.isEmpty }
        return rects.isEmpty ? [unionBounds] : rects
    }

    var unionBounds: CGRect {
        CGRect(x: boundsX, y: boundsY, width: boundsWidth, height: boundsHeight).standardized
    }

    var renderHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(type)
        hasher.combine(color)
        hasher.combine(pageIndex)
        hasher.combine(noteText)
        for rect in rects {
            hasher.combine(rect.origin.x)
            hasher.combine(rect.origin.y)
            hasher.combine(rect.size.width)
            hasher.combine(rect.size.height)
        }
        return hasher.finalize()
    }

    init(_ record: PDFAnnotationRecord) {
        documentID = .reference(record.referenceId)
        referenceSyncId = record.referenceSyncId
        id = record.id
        syncId = record.syncId
        type = record.type
        noteText = record.noteText
        color = record.color
        dateCreated = record.dateCreated
        dateModified = record.dateModified
        selectedText = record.selectedText
        pageIndex = record.pageIndex
        boundsX = record.boundsX
        boundsY = record.boundsY
        boundsWidth = record.boundsWidth
        boundsHeight = record.boundsHeight
        rectsData = record.rectsData
    }

    var primaryRecord: PDFAnnotationRecord? {
        guard case .reference(let referenceId) = documentID else { return nil }
        var record = PDFAnnotationRecord(
            id: id, syncId: syncId, referenceId: referenceId, referenceSyncId: referenceSyncId,
            type: type, selectedText: selectedText, noteText: noteText, color: color,
            pageIndex: pageIndex, rects: rects, dateCreated: dateCreated, dateModified: dateModified)
        record.boundsX = boundsX
        record.boundsY = boundsY
        record.boundsWidth = boundsWidth
        record.boundsHeight = boundsHeight
        record.rectsData = rectsData
        return record
    }
}

struct ReaderWebAnnotation: Identifiable, Codable, Hashable {
    var id: Int64?
    var syncId: String
    let documentID: ReaderDocumentIdentity
    var referenceSyncId: String
    var type: AnnotationType
    var noteText: String?
    var color: String
    var anchorText: String
    var prefixText: String?
    var suffixText: String?
    var dateCreated: Date
    var dateModified: Date

    init(
        id: Int64? = nil,
        syncId: String = SyncIdentifier.random(),
        documentID: ReaderDocumentIdentity,
        referenceSyncId: String = "",
        type: AnnotationType,
        noteText: String? = nil,
        color: String = "#FFDE59",
        anchorText: String,
        prefixText: String? = nil,
        suffixText: String? = nil,
        dateCreated: Date = Date(),
        dateModified: Date = Date()
    ) {
        self.id = id
        self.syncId = syncId
        self.documentID = documentID
        self.referenceSyncId = referenceSyncId
        self.type = type
        self.noteText = noteText
        self.color = color
        self.anchorText = anchorText
        self.prefixText = prefixText
        self.suffixText = suffixText
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }

    init(_ record: WebAnnotationRecord) {
        documentID = .reference(record.referenceId)
        referenceSyncId = record.referenceSyncId
        id = record.id
        syncId = record.syncId
        type = record.type
        noteText = record.noteText
        color = record.color
        dateCreated = record.dateCreated
        dateModified = record.dateModified
        anchorText = record.anchorText
        prefixText = record.prefixText
        suffixText = record.suffixText
    }

    var primaryRecord: WebAnnotationRecord? {
        guard case .reference(let referenceId) = documentID else { return nil }
        return WebAnnotationRecord(
            id: id, syncId: syncId, referenceId: referenceId, referenceSyncId: referenceSyncId,
            type: type, noteText: noteText, color: color, anchorText: anchorText,
            prefixText: prefixText, suffixText: suffixText, dateCreated: dateCreated, dateModified: dateModified)
    }
}

private extension Array where Element == CGRect {
    var unionRect: CGRect? {
        guard let first else { return nil }
        return dropFirst().reduce(first) { $0.union($1) }
    }
}
#endif
