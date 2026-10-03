import ArgumentParser
import Foundation
import RubienCore
import RubienPDFKit

struct AttachmentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attachment", abstract: "Manage local PDF and Markdown attachments",
        subcommands: [AttachmentList.self, AttachmentAdd.self, AttachmentStatus.self,
                      AttachmentRetry.self, AttachmentRead.self, AttachmentExport.self, AttachmentRename.self, AttachmentRemove.self])
}

private func attachmentStore() -> ReferenceAttachmentStore {
    ReferenceAttachmentStore(database: .shared, libraryRoot: AppDatabase.libraryRootURL,
                             validatePDF: { try ReferenceAttachmentPDFValidator.validate($0) })
}

private func attachmentUUID(_ value: String) throws -> String {
    guard let id = UUID(uuidString: value) else { throw ValidationError("Expected an attachment UUID") }
    return id.uuidString.lowercased()
}

private func attachmentPath(_ value: String) -> URL {
    URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
}

private func attachmentOperation(_ body: () throws -> Void) throws {
    do { try body() }
    catch {
        printJSONError((error as? ValidationError)?.description ?? error.localizedDescription)
        throw ExitCode.failure
    }
}

struct AttachmentList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List a reference's attachments")
    @Argument var referenceId: Int64
    func run() throws {
        try attachmentOperation {
            guard try AppDatabase.shared.fetchReferences(ids: [referenceId]).first != nil else {
                throw ReferenceAttachmentError.missingReference
            }
            let store = attachmentStore()
            printJSON(try store.list(referenceId: referenceId).map { try store.status(syncId: $0.syncId, verifyContents: false) })
        }
    }
}

struct AttachmentAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Attach PDF/Markdown files; return one result per input")
    @Argument var referenceId: Int64
    @Argument var files: [String]
    struct Result: Encodable {
        let file: String
        let outcome: String
        let status: ReferenceAttachmentStatus?
        let error: String?
    }
    func run() throws {
        guard !files.isEmpty else { throw ValidationError("Provide at least one PDF or Markdown file") }
        let store = attachmentStore()
        var changed = false
        let results = files.map { path -> Result in
            do {
                let result = try store.importFile(at: attachmentPath(path), referenceId: referenceId)
                changed = changed || !result.wasDuplicate
                return Result(file: path, outcome: result.wasDuplicate ? "duplicate" : "added",
                              status: try store.status(syncId: result.attachment.syncId), error: nil)
            } catch {
                return Result(file: path, outcome: "error", status: nil, error: error.localizedDescription)
            }
        }
        if changed { notifyLibraryChanged() }
        printJSON(results)
    }
}

struct AttachmentStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Check local bytes and pending attachment state")
    @Argument var id: String
    func run() throws {
        try attachmentOperation { printJSON(try attachmentStore().status(syncId: attachmentUUID(id))) }
    }
}

struct AttachmentRename: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: "Change an attachment's display name")
    @Argument var id: String
    @Option var name: String
    func run() throws {
        try attachmentOperation {
            let store = attachmentStore(), uuid = try attachmentUUID(id)
            try store.rename(syncId: uuid, to: name)
            notifyLibraryChanged()
            printJSON(try store.status(syncId: uuid))
        }
    }
}

struct AttachmentRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove an attachment while retaining its removal marker")
    @Argument var id: String
    func run() throws {
        try attachmentOperation {
            let store = attachmentStore(), uuid = try attachmentUUID(id)
            try store.remove(syncId: uuid)
            notifyLibraryChanged()
            printJSON(try store.status(syncId: uuid))
        }
    }
}

struct AttachmentExport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Save original attachment bytes to a new file")
    @Argument var id: String
    @Option var output: String
    func run() throws {
        try attachmentOperation {
            let uuid = try attachmentUUID(id), destination = attachmentPath(output)
            try attachmentStore().export(syncId: uuid, to: destination)
            printJSON(["attachmentSyncId": uuid, "output": destination.path])
        }
    }
}

struct AttachmentRead: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "read", abstract: "Read attachment PDF pages or a Markdown character window")
    @Argument var id: String
    @Option var pages: String?
    @Option var start: Int?
    @Option(name: .customLong("max-chars")) var maxChars: Int = 50_000
    struct MarkdownOutput: Encodable {
        let attachmentSyncId: String
        let source = "markdown"
        let content: String
        let contentLength: Int
        let start: Int
        let returnedChars: Int
        let truncated: Bool
    }
    struct PDFOutput: Encodable {
        let attachmentSyncId: String
        let source = "pdf"
        let pageCount: Int
        let selection: PDFExtractor.SelectionEcho
        let pages: [PDFExtractor.PageContent]
        let truncated: Bool
        let hasTextLayer: Bool
    }
    func run() throws {
        try attachmentOperation {
            guard maxChars > 0, maxChars <= 500_000, (start ?? 0) >= 0 else {
                throw ValidationError("Use --max-chars between 1 and 500000 and --start >= 0")
            }
            let store = attachmentStore(), uuid = try attachmentUUID(id)
            let lease = try store.acquireFileLease()
            defer { withExtendedLifetime(lease) {} }
            let item = try store.attachment(syncId: uuid)
            let url = try store.verifiedFileURL(syncId: uuid)
            switch item.supportedKind {
            case .pdf:
                guard start == nil else { throw ValidationError("Use --pages for PDF attachments; --start is Markdown-only") }
                let result = try PDFExtractor.extractText(at: url, selection: pages.map { .pagesString($0) } ?? .allPages,
                                                         maxChars: maxChars)
                printJSON(PDFOutput(attachmentSyncId: uuid, pageCount: result.pageCount,
                                    selection: result.selection, pages: result.pages,
                                    truncated: result.truncated, hasTextLayer: result.hasTextLayer))
            case .markdown:
                guard pages == nil else { throw ValidationError("Use --start for Markdown attachments; --pages is PDF-only") }
                var text = try String(contentsOf: url, encoding: .utf8)
                if text.first == "\u{FEFF}" { text.removeFirst() }
                let count = text.count, offset = min(start ?? 0, count)
                let content = String(text.dropFirst(offset).prefix(maxChars))
                printJSON(MarkdownOutput(attachmentSyncId: uuid, content: content, contentLength: count,
                                         start: offset, returnedChars: content.count,
                                         truncated: offset + content.count < count))
            case nil: throw ReferenceAttachmentError.unsupportedFile
            }
        }
    }
}

struct AttachmentRetry: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "retry", abstract: "Retry pending attachment sync work")
    @Argument var id: String
    func run() throws {
        try attachmentOperation {
            let store = attachmentStore(), uuid = try attachmentUUID(id)
            try store.retrySync(syncId: uuid)
            notifyLibraryChanged()
            printJSON(try store.status(syncId: uuid, verifyContents: false))
        }
    }
}
