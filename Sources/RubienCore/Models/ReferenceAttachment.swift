import Foundation
import GRDB

public enum ReferenceAttachmentKind: String, Codable, Sendable {
    case pdf, markdown

    public var fileExtension: String { self == .pdf ? "pdf" : "md" }
    public var maximumBytes: Int64 { self == .pdf ? 250 * 1_024 * 1_024 : 50 * 1_024 * 1_024 }
}

public struct ReferenceAttachment: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "referenceAttachment"
    public var id: Int64?
    public var syncId: String
    public var referenceId: Int64?
    public var referenceSyncId: String
    /// Preserve unknown wire values so a newer peer's file can remain in the library.
    public var kind: String
    public var originalFilename: String
    public var displayName: String
    public var byteCount: Int64
    public var contentHash: String
    public var dateCreated: Date
    public var dateModified: Date
    public var deletedAt: Date?

    public init(
        id: Int64? = nil, syncId: String, referenceId: Int64?, referenceSyncId: String,
        kind: String, originalFilename: String, displayName: String, byteCount: Int64,
        contentHash: String, dateCreated: Date, dateModified: Date, deletedAt: Date?
    ) {
        self.id = id
        self.syncId = syncId
        self.referenceId = referenceId
        self.referenceSyncId = referenceSyncId
        self.kind = kind
        self.originalFilename = originalFilename
        self.displayName = displayName
        self.byteCount = byteCount
        self.contentHash = contentHash
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.deletedAt = deletedAt
    }

    public var supportedKind: ReferenceAttachmentKind? { ReferenceAttachmentKind(rawValue: kind) }
}

public enum ReferenceAttachmentError: Error, LocalizedError, Equatable {
    case unsupportedFile, invalidMarkdown, invalidPDF, tooLarge(Int64), missingReference
    case missingAttachment, removed, unavailable, integrityMismatch, invalidPath, invalidName, busy

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: return "Choose a regular PDF or Markdown (.md) file."
        case .invalidMarkdown: return "The Markdown file must contain UTF-8 text."
        case .invalidPDF: return "The file is not a readable PDF."
        case .tooLarge(let limit): return "The attachment exceeds the \(limit / 1_024 / 1_024) MiB limit."
        case .missingReference: return "The reference no longer exists."
        case .missingAttachment: return "The attachment no longer exists."
        case .removed: return "The attachment has been removed."
        case .unavailable: return "The attachment is not available on this device."
        case .integrityMismatch: return "The stored file differs from the attached copy."
        case .invalidPath: return "The attachment path is outside its managed storage."
        case .invalidName: return "Enter a non-empty attachment name of at most 255 characters."
        case .busy: return "Another attachment operation is running. Try again shortly."
        }
    }
}

public struct ReferenceAttachmentImportResult: Sendable {
    public let attachment: ReferenceAttachment
    public let wasDuplicate: Bool
}

/// The PDF target supplies this validator so Core remains independent of PDF backends.
public typealias ReferenceAttachmentPDFValidation = @Sendable (URL) throws -> Void
