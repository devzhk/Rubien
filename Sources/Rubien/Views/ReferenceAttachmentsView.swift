#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import Combine
import GRDB
import RubienCore
import RubienPDFKit

@MainActor
final class ReferenceAttachmentsModel: ObservableObject {
    struct ImportStatus: Identifiable {
        let id = UUID()
        let filename: String
        var message: String
        var failed = false
    }
    @Published var transfers: [String: ReferenceAttachmentTransferState] = [:]
    @Published var attachments: [ReferenceAttachment] = []
    @Published var importStatuses: [ImportStatus] = []
    @Published var isImporting = false
    @Published var errorMessage: String?
    let reference: Reference
    let store: ReferenceAttachmentStore
    private var observation: AnyCancellable?
    private var importTask: Task<Void, Never>?

    init(reference: Reference, database: AppDatabase, libraryRoot: URL) {
        self.reference = reference
        store = ReferenceAttachmentStore(database: database, libraryRoot: libraryRoot,
                                         validatePDF: { try ReferenceAttachmentPDFValidator.validate($0) })
        let id = reference.id ?? -1
        observation = ValueObservation.tracking { db in
            let items = try ReferenceAttachment.fetchAll(db, sql: """
                SELECT * FROM referenceAttachment WHERE referenceId=? AND deletedAt IS NULL
                ORDER BY dateCreated, syncId
                """, arguments: [id])
            let transfers = try Dictionary(uniqueKeysWithValues: items.map { ($0.syncId, try ReferenceAttachmentTransferState.fetch(db, attachment: $0)) })
            return (items, transfers)
        }.publisher(in: database.dbWriter).receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] result in
                if case .failure(let error) = result { self?.errorMessage = error.localizedDescription }
            }, receiveValue: { [weak self] in self?.attachments = $0.0; self?.transfers = $0.1 })
    }

    func add(_ urls: [URL]) {
        guard !isImporting, let referenceId = reference.id, !urls.isEmpty else { return }
        isImporting = true
        importStatuses = urls.map { ImportStatus(filename: $0.lastPathComponent, message: "Waiting") }
        let store = store
        importTask = Task {
            defer { isImporting = false }
            for (index, url) in urls.enumerated() {
                if Task.isCancelled {
                    for remaining in index..<urls.count { importStatuses[remaining].message = "Cancelled" }
                    break
                }
                importStatuses[index].message = "Adding…"
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try store.importFile(at: url, referenceId: referenceId)
                    }.value
                    importStatuses[index].message = result.wasDuplicate ? "Already attached" : "Added"
                } catch {
                    importStatuses[index].message = error.localizedDescription
                    importStatuses[index].failed = true
                }
            }
        }
    }

    func retry(_ item: ReferenceAttachment) {
        do {
            try store.retrySync(syncId: item.syncId)
            NotificationCenter.default.post(name: .init("RubienAttachmentSyncRetry"), object: nil)
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelImport() { importTask?.cancel() }

    func open(_ item: ReferenceAttachment) {
        Task {
            do {
                let document = try await AttachmentReaderDocument.open(syncId: item.syncId, store: store)
                try ReaderWindowManager.shared.openAttachment(document, parent: reference)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func reveal(_ item: ReferenceAttachment) {
        let store = store
        Task {
            do {
                let url = try await Task.detached { try store.verifiedFileURL(syncId: item.syncId) }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func remove(_ item: ReferenceAttachment) {
        let store = store
        Task {
            do { try await Task.detached { try store.remove(syncId: item.syncId) }.value }
            catch { errorMessage = error.localizedDescription }
        }
    }


}

struct ReferenceAttachmentsView: View {
    @StateObject private var model: ReferenceAttachmentsModel
    @State private var dropTargeted = false
    @State private var removing: ReferenceAttachment?

    init(reference: Reference, database: AppDatabase, libraryRoot: URL = AppDatabase.libraryRootURL) {
        _model = StateObject(wrappedValue: ReferenceAttachmentsModel(reference: reference, database: database, libraryRoot: libraryRoot))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Attachments").font(.headline)
                Spacer()
                Button(action: pickFiles) { Label("Add Files…", systemImage: "plus") }
                    .buttonStyle(SLSecondaryButtonStyle())
                    .disabled(model.isImporting)
                    .controlSize(.small)
            }
            if !model.transfers.values.contains(where: { $0.status != "notEnabled" }) {
                Text("On this Mac · Not synced").font(.caption).foregroundStyle(.secondary)
            }
            Text(dropTargeted ? "Drop to add attachments" : "You can also drag PDF or Markdown files here.")
                .font(.caption)
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(model.attachments, id: \.syncId) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: item.supportedKind == .pdf ? "doc.richtext" : "doc.plaintext")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName).lineLimit(2).multilineTextAlignment(.leading)
                            Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let transfer = model.transfers[item.syncId], transfer.status != "notEnabled" {
                        HStack(alignment: .top) {
                            Text(transfer.error ?? transferLabel(transfer.status))
                                .font(.caption).foregroundStyle(.secondary)
                            if transfer.error != nil {
                                Button("Retry") { model.retry(item) }
                                    .buttonStyle(SLSecondaryButtonStyle()).controlSize(.mini)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Button { model.reveal(item) } label: {
                            Label("Reveal", systemImage: "folder")
                        }
                        .buttonStyle(SLSecondaryButtonStyle())
                        .help("Reveal in Finder")
                        Button { model.open(item) } label: {
                            Label("Open", systemImage: "book.pages")
                        }
                        .buttonStyle(SLSecondaryButtonStyle())
                        .help("Open in Reader")
                        Button { removing = item } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(SLDestructiveButtonStyle())
                        .help("Remove attachment")
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
            ForEach(model.importStatuses) { status in
                HStack(alignment: .top) {
                    Text(status.filename).lineLimit(1)
                    Spacer()
                    Text(status.message).foregroundStyle(status.failed ? Color.red : Color.secondary)
                }.font(.caption)
            }
            if model.isImporting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Adding files…").font(.caption)
                    Spacer()
                    Button("Cancel Remaining") { model.cancelImport() }
                        .buttonStyle(SLSecondaryButtonStyle()).controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(dropTargeted ? 0.10 : 0.035)))
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isImporting else { return false }
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .onDisappear { model.cancelImport() }
        .confirmationDialog("Remove this attachment?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Attachment", role: .destructive) { if let item = removing { model.remove(item) }; removing = nil }
        } message: { Text("The original file and main document are kept. This attachment’s reader will close.") }
        .alert("Attachment couldn’t be opened or changed", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func transferLabel(_ status: String) -> String {
        switch status {
        case "catchingUp": return "Checking iCloud…"
        case "pendingDownload": return "Waiting to download"
        case "pendingUpload": return "Waiting to sync"
        case "synced": return "Synced with iCloud"
        default: return "Sync needs attention"
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add Attachments"
        if panel.runModal() == .OK { model.add(panel.urls) }
    }
}
#endif
