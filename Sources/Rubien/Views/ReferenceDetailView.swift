#if os(macOS)
import SwiftUI
import os
import PDFKit
import RubienCore
import RubienPDFKit

private let detailLog = Logger(subsystem: "Rubien", category: "reference-detail")

/// Runs manual PDF file I/O and the potentially-contended SQLite write away
/// from the main actor. The injected operations keep the threading and cleanup
/// contract directly testable without opening an `NSOpenPanel`.
enum ReferenceDetailPDFAttachmentWorker {
    enum Outcome: Equatable, Sendable {
        case attached
        case alreadyAttached
        case failed(String)
    }

    typealias Importer = @Sendable (URL) throws -> String
    typealias Downloader = @Sendable (Reference) async throws -> String
    typealias Attacher = @Sendable (AppDatabase, Int64, String) throws -> Bool
    typealias Replacer = @Sendable (AppDatabase, Int64, String) throws -> String?
    typealias Deleter = @Sendable (String) -> Void

    static func attach(
        sourceURL: URL,
        referenceId: Int64,
        database: AppDatabase,
        importer: @escaping Importer = { try PDFService.importPDF(from: $0) },
        attacher: @escaping Attacher = { database, referenceId, filename in
            try database.attachImportedPDF(
                referenceId: referenceId,
                filename: filename
            )
        },
        deleter: @escaping Deleter = { PDFService.deletePDF(at: $0) }
    ) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            let filename: String
            do {
                filename = try importer(sourceURL)
            } catch {
                return .failed(error.localizedDescription)
            }

            return persistImportedPDF(
                filename: filename,
                referenceId: referenceId,
                database: database,
                attacher: attacher,
                deleter: deleter
            )
        }.value
    }

    /// Download first, then commit the new cache state. A failed download never
    /// touches the current attachment; a failed commit removes only the new file.
    static func downloadAndAttach(
        reference: Reference,
        referenceId: Int64,
        database: AppDatabase,
        replacingExisting: Bool,
        downloader: @escaping Downloader = { try await PDFDownloadService.downloadPDF(for: $0) },
        attacher: @escaping Attacher = { database, referenceId, filename in
            try database.attachImportedPDF(referenceId: referenceId, filename: filename)
        },
        replacer: @escaping Replacer = { database, referenceId, filename in
            try database.replaceImportedPDF(referenceId: referenceId, filename: filename)
        },
        deleter: @escaping Deleter = { PDFService.deletePDF(at: $0) }
    ) async -> Outcome {
        let filename: String
        do {
            filename = try await downloader(reference)
        } catch {
            return .failed(error.localizedDescription)
        }

        if replacingExisting {
            return await replaceImportedPDF(
                filename: filename,
                referenceId: referenceId,
                database: database,
                replacer: replacer,
                deleter: deleter
            )
        }
        return await registerImportedPDF(
            filename: filename,
            referenceId: referenceId,
            database: database,
            attacher: attacher,
            deleter: deleter
        )
    }

    /// Register a file that is already in Rubien's PDF storage, such as a
    /// finished network download. The same loser/error cleanup contract as
    /// manual attachment prevents unowned files during concurrent operations.
    static func registerImportedPDF(
        filename: String,
        referenceId: Int64,
        database: AppDatabase,
        attacher: @escaping Attacher = { database, referenceId, filename in
            try database.attachImportedPDF(referenceId: referenceId, filename: filename)
        },
        deleter: @escaping Deleter = { PDFService.deletePDF(at: $0) }
    ) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            persistImportedPDF(
                filename: filename,
                referenceId: referenceId,
                database: database,
                attacher: attacher,
                deleter: deleter
            )
        }.value
    }

    /// Atomically replace the cache row before deleting the prior file. If the
    /// transaction fails, the current attachment remains and only the new copy
    /// is removed.
    static func replaceImportedPDF(
        filename: String,
        referenceId: Int64,
        database: AppDatabase,
        replacer: @escaping Replacer = { database, referenceId, filename in
            try database.replaceImportedPDF(referenceId: referenceId, filename: filename)
        },
        deleter: @escaping Deleter = { PDFService.deletePDF(at: $0) }
    ) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            do {
                let previousFilename = try replacer(database, referenceId, filename)
                if let previousFilename, previousFilename != filename {
                    deleter(previousFilename)
                }
                return .attached
            } catch {
                deleter(filename)
                return .failed(error.localizedDescription)
            }
        }.value
    }

    private static func persistImportedPDF(
        filename: String,
        referenceId: Int64,
        database: AppDatabase,
        attacher: Attacher,
        deleter: Deleter
    ) -> Outcome {
        do {
            let attached = try attacher(database, referenceId, filename)
            guard attached else {
                deleter(filename)
                return .alreadyAttached
            }
            return .attached
        } catch {
            // The cache transaction failed, so this copy has no durable owner.
            deleter(filename)
            return .failed(error.localizedDescription)
        }
    }
}

struct ReferenceDetailPDFOperationRegistry {
    enum Operation: Equatable {
        case attachment
        case download
    }

    private var operations: [Int64: Operation] = [:]
    private(set) var revision = 0

    func operation(for referenceId: Int64?) -> Operation? {
        guard let referenceId else { return nil }
        return operations[referenceId]
    }

    mutating func begin(_ operation: Operation, for referenceId: Int64) -> Bool {
        guard operations[referenceId] == nil else { return false }
        operations[referenceId] = operation
        revision &+= 1
        return true
    }

    mutating func finish(_ operation: Operation, for referenceId: Int64) {
        guard operations[referenceId] == operation else { return }
        operations.removeValue(forKey: referenceId)
        revision &+= 1
    }
}

struct ReferenceDetailView: View {
    let reference: Reference
    let allTags: [Tag]
    let db: AppDatabase
    let isActive: Bool
    let onSave: (Reference) -> Void
    let onDelete: () -> Void
    var onOpenPDFReader: ((Reference) -> Void)?
    var onOpenWebReader: ((Reference) -> Void)?
    var onUpdateTags: ((Int64, [Int64]) -> Void)?
    var onCreateTag: ((String) -> Int64?)?
    var onDeleteTag: ((Int64) -> Void)?
    var deleteTagUnlessInUse: ((Int64) -> Int?)?

    @State private var editedRef: Reference
    @State private var editingField: String?
    @State private var previewWindow: NSWindow?
    @State private var previewWindowCloseObserver: NSObjectProtocol?
    @State private var referenceTags: [Tag] = []
    @State private var pdfAnnotationCount: Int = 0
    @State private var webAnnotationCount: Int = 0
    @State private var hasStoredWebContent = false
    @State private var cachedHasPDFInCache = false
    @State private var pdfDownloadState: PDFDownloadState = .idle
    @State private var pdfAttachmentState: PDFAttachmentState = .idle
    @Binding private var pdfOperations: ReferenceDetailPDFOperationRegistry
    @State private var showOverwriteConfirmation = false
    @Binding var propertyDefs: [PropertyDefinition]
    @State private var customValues: [Int64: String] = [:]
    @State private var showPropertyManager = false

    @Environment(\.syncCoordinator) private var syncCoordinator: SyncCoordinator?

    private enum PDFDownloadState {
        case idle, downloading, failed(String)
    }

    private enum PDFAttachmentState {
        case idle, attaching, failed(String)
    }

    private var activePDFOperation: ReferenceDetailPDFOperationRegistry.Operation? {
        pdfOperations.operation(for: editedRef.id)
    }

    private var isPDFDownloadActive: Bool { activePDFOperation == .download }
    private var isPDFAttachmentActive: Bool { activePDFOperation == .attachment }
    private var pdfCacheRefreshID: String {
        "\(reference.id ?? -1)-\(reference.dateModified.timeIntervalSinceReferenceDate)-\(isActive)-\(pdfOperations.revision)"
    }

    let liveTags: [Tag]

    init(reference: Reference, allTags: [Tag], liveTags: [Tag] = [], db: AppDatabase,
         isActive: Bool = true,
         onSave: @escaping (Reference) -> Void, onDelete: @escaping () -> Void,
         onOpenPDFReader: ((Reference) -> Void)? = nil, onOpenWebReader: ((Reference) -> Void)? = nil,
         onUpdateTags: ((Int64, [Int64]) -> Void)? = nil,
         onCreateTag: ((String) -> Int64?)? = nil,
         onDeleteTag: ((Int64) -> Void)? = nil,
         deleteTagUnlessInUse: ((Int64) -> Int?)? = nil,
         pdfOperations: Binding<ReferenceDetailPDFOperationRegistry>,
         propertyDefs: Binding<[PropertyDefinition]>) {
        self.reference = reference
        self.allTags = allTags
        self.liveTags = liveTags
        self.db = db
        self.isActive = isActive
        self.onSave = onSave
        self.onDelete = onDelete
        self.onOpenPDFReader = onOpenPDFReader
        self.onOpenWebReader = onOpenWebReader
        self.onUpdateTags = onUpdateTags
        self.onCreateTag = onCreateTag
        self.onDeleteTag = onDeleteTag
        self.deleteTagUnlessInUse = deleteTagUnlessInUse
        self._editedRef = State(initialValue: reference)
        self._pdfOperations = pdfOperations
        self._propertyDefs = propertyDefs
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                propertiesCard
                if canOpenWebReader { webReaderCard }
                if cachedHasPDFInCache { pdfCard }
                abstractSection
                notesSection
                footerSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            if editingField == nil, cachedHasPDFInCache {
                quickPreviewShortcut
            }
        }
        .onChange(of: reference) { oldRef, newRef in
            commitPendingEdit()
            closeQuickPreviewWindow()
            editedRef = newRef
            editingField = nil
            guard oldRef.id != newRef.id else { return }
            pdfAttachmentState = .idle
            cachedHasPDFInCache = false
            pdfDownloadState = .idle
            referenceTags = []
            pdfAnnotationCount = 0
            webAnnotationCount = 0
            hasStoredWebContent = false
            customValues = [:]
        }
        .task(id: reference.id) {
            await loadSupplementaryData(for: reference.id)
            await loadCustomPropertyValues(for: reference.id)
        }
        .task(id: pdfCacheRefreshID) {
            guard isActive else { return }
            cachedHasPDFInCache = reference.hasPDFInCache(in: db)
        }
        .onChange(of: liveTags) { _, newTags in
            referenceTags = newTags
        }
        .onChange(of: isActive) { _, active in
            if !active { closeQuickPreviewWindow() }
        }
        .onDisappear { closeQuickPreviewWindow() }
    }

    // MARK: - Header (Title + Authors)

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title — click to edit
            if editingField == "title" {
                InlineTitleEditor(
                    text: Binding(
                        get: { editedRef.title },
                        set: { editedRef.title = $0 }
                    ),
                    onCommit: { commitFieldAndSave("title") },
                    onCancel: { cancelEdit() }
                )
            } else {
                HoverRegion { isHovering in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(reference.title)
                            .font(.title2.bold())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if isHovering {
                            editPencil("title", help: String(localized: "Edit title", bundle: .module))
                        }
                    }
                }
            }

            // Authors — click to edit
            if editingField == "authors" {
                InlineAuthorsEditor(
                    text: Binding(
                        get: { editedRef.authors.displayString },
                        set: { editedRef.authors = AuthorName.parseList($0) }
                    ),
                    onCommit: { commitFieldAndSave("authors") },
                    onCancel: { cancelEdit() }
                )
            } else if !reference.authors.isEmpty {
                HoverRegion { isHovering in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(reference.authors.displayString)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)
                            .truncationMode(.tail)
                        if isHovering {
                            editPencil("authors", help: String(localized: "Edit authors", bundle: .module))
                        }
                    }
                }
            } else {
                Text("Add authors")
                    .font(.body)
                    .foregroundStyle(.quaternary)
                    .contentShape(Rectangle())
                    .onTapGesture { beginEdit("authors") }
            }

            // Publication line (read-only summary when fields have values)
            let pubParts: [String] = [
                reference.journal.flatMap { $0.isEmpty ? nil : $0 },
                reference.volume.map { "Vol. \($0)" },
                reference.issue.map { "(\($0))" },
                reference.pages.map { "pp. \($0)" },
                reference.year.map { "(\(String($0)))" }
            ].compactMap { $0 }
            if !pubParts.isEmpty {
                HStack(spacing: 8) {
                    if let journal = reference.journal, !journal.isEmpty {
                        Text(journal).italic()
                    }
                    if let vol = reference.volume { Text("Vol. \(vol)") }
                    if let issue = reference.issue { Text("(\(issue))") }
                    if let pages = reference.pages { Text("pp. \(pages)") }
                    if let year = reference.year { Text("(\(String(year)))") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Properties Card

    @ViewBuilder
    private var propertiesCard: some View {
        let visibleDefs = propertyDefs.filter(\.isVisible).sorted { $0.sortOrder < $1.sortOrder }

        VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleDefs) { prop in
                propertyRow(for: prop)
                if prop.id != visibleDefs.last?.id {
                    Divider().padding(.leading, 100)
                }
            }

            // PDF attach/remove actions
            Divider().padding(.leading, 100)
            PropertyRowLayout(label: "PDF") {
                if cachedHasPDFInCache {
                    HStack(spacing: 8) {
                        Label("Attached", systemImage: "doc.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button {
                            revealAttachedPDF()
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(ToolbarHoverButtonStyle(hoverOpacity: 0.10, pressedOpacity: 0.16))
                        .help("Reveal in Finder")

                        Button {
                            removeAttachedPDF()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(SLDestructiveButtonStyle())
                        .controlSize(.mini)
                        .disabled(activePDFOperation != nil)
                        .help("Remove PDF")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            if let url = OpenPanelPicker.pickPDFFile() {
                                attachPDF(from: url)
                            }
                        } label: {
                            if isPDFAttachmentActive {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Attaching PDF…")
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            } else {
                                Label("Attach PDF...", systemImage: "plus")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(ToolbarHoverButtonStyle(hoverOpacity: 0.10, pressedOpacity: 0.16))
                        .disabled(activePDFOperation != nil)

                        if case .failed(let message) = pdfAttachmentState {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                }
            }

            // + Add property button
            Divider().padding(.leading, 100)
            Button {
                showPropertyManager = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                    Text("Add a property")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.tertiary)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPropertyManager) {
                PropertyManagerPopover(
                    propertyDefs: $propertyDefs,
                    onToggleVisibility: { propId, visible in
                        try? db.togglePropertyVisibility(id: propId, visible: visible)
                    },
                    onDelete: { propId in
                        try? db.deletePropertyDefinition(id: propId)
                    },
                    onReorder: { orderedIds in
                        try? db.reorderProperties(orderedIds)
                    },
                    onCreateProperty: { name, type in
                        let maxOrder = propertyDefs.map(\.sortOrder).max() ?? 0
                        var newProp = PropertyDefinition(
                            name: name, type: type, sortOrder: maxOrder + 1, isDefault: false, isVisible: true
                        )
                        try? db.savePropertyDefinition(&newProp)
                    },
                    onRenameProperty: { propId, newName in
                        if var prop = propertyDefs.first(where: { $0.id == propId }) {
                            prop.name = newName
                            try? db.savePropertyDefinition(&prop)
                        }
                    }
                )
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Property Row Dispatcher

    @ViewBuilder
    private func propertyRow(for prop: PropertyDefinition) -> some View {
        if prop.isDefault {
            defaultPropertyRow(for: prop)
        } else {
            customPropertyRow(for: prop)
        }
    }

    @ViewBuilder
    private func defaultPropertyRow(for prop: PropertyDefinition) -> some View {
        switch prop.defaultFieldKey {
        case "referenceType":
            // Type drives BibTeX/RIS export buckets — its option set is fixed.
            // The picker hides the inline "create" affordance and shows a
            // footer hint pointing users at Tags or custom properties for
            // free-form organization.
            InlineSingleSelectRow(
                label: prop.name,
                value: editedRef.referenceType.rawValue,
                options: prop.options,
                onSelect: { value in
                    if let type = ReferenceType(rawValue: value) {
                        editedRef.referenceType = type
                        commitDefaultSave()
                    }
                },
                onCreateOption: nil,
                lockedHint: "Type is fixed (drives BibTeX/RIS export). Use Tags or a custom property for organization."
            )
        case "readingStatus":
            InlineSingleSelectRow(
                label: prop.name,
                value: editedRef.readingStatus,
                options: prop.options,
                onSelect: { value in
                    // Post-Phase-2: the option's `value` is the canonical
                    // string identity for the status — assign it directly.
                    // User-added options also flow through this path.
                    editedRef.readingStatus = value
                    commitDefaultSave()
                },
                onCreateOption: { newOption in
                    // Append the new option to the seeded Status PropertyDefinition
                    // and persist; the Reference's status is set by `onSelect`
                    // (which fires after this with the same value).
                    if var statusDef = propertyDefs.first(forFieldKey: PropertyDefinition.readingStatusFieldKey) {
                        _ = statusDef.addOptionIfMissing(newOption)
                        try? db.savePropertyDefinition(&statusDef)
                    }
                },
                onDeleteOption: { option in
                    // Try clean delete first; on .optionInUse, auto-reassign
                    // to the first remaining option. Mirrors the table-cell
                    // behavior — finer-grained replacement is via the CLI's
                    // --replace-with flag.
                    guard let statusDef = propertyDefs.first(forFieldKey: PropertyDefinition.readingStatusFieldKey),
                          let propId = statusDef.id else { return }
                    do {
                        try db.deletePropertyOption(propertyId: propId, value: option, replaceWith: nil)
                    } catch PropertyOptionError.optionInUse {
                        let fallback = statusDef.options
                            .first(where: { $0.value != option })?
                            .value
                        guard let replacement = fallback else { return }
                        try? db.deletePropertyOption(propertyId: propId, value: option, replaceWith: replacement)
                    } catch {
                        // .optionNotFound / .unsupportedPropertyType / etc.
                        // shouldn't happen for Status; swallow.
                    }
                }
            )
        case "tags":
            InlineTagsRow(
                label: prop.name,
                tags: referenceTags,
                allTags: allTags,
                onUpdateTags: { tagIds in
                    guard let refId = reference.id else { return }
                    onUpdateTags?(refId, tagIds)
                },
                onCreateTag: { name in onCreateTag?(name) ?? nil },
                onDeleteTag: { tagId in
                    onDeleteTag?(tagId)
                },
                deleteTagUnlessInUse: { tagId in deleteTagUnlessInUse?(tagId) ?? nil }
            )
        case "year":
            InlineNumberRow(
                label: prop.name,
                value: editedRef.year,
                placeholder: "Empty",
                isEditing: editingField == "year",
                onBeginEditing: { beginEdit("year") },
                onCommit: { val in
                    editedRef.year = val
                    commitFieldAndSave("year")
                },
                onCancel: { cancelEdit() }
            )
        case "doi":
            InlineURLRow(
                label: prop.name,
                value: editedRef.doi ?? "",
                isEditing: editingField == "doi",
                onBeginEditing: { beginEdit("doi") },
                onCommit: { val in
                    editedRef.doi = val.isEmpty ? nil : val
                    commitFieldAndSave("doi")
                },
                onCancel: { cancelEdit() }
            )
        case "url":
            InlineURLRow(
                label: prop.name,
                value: editedRef.url ?? "",
                isEditing: editingField == "url",
                onBeginEditing: { beginEdit("url") },
                onCommit: { val in
                    editedRef.url = val.isEmpty ? nil : val
                    commitFieldAndSave("url")
                },
                onCancel: { cancelEdit() }
            )
        case "journal":
            InlineStringRow(
                label: prop.name,
                value: editedRef.journal ?? "",
                isEditing: editingField == "journal",
                onBeginEditing: { beginEdit("journal") },
                onCommit: { val in
                    editedRef.journal = val.isEmpty ? nil : val
                    commitFieldAndSave("journal")
                },
                onCancel: { cancelEdit() }
            )
        case "volume":
            InlineStringRow(
                label: prop.name,
                value: editedRef.volume ?? "",
                isEditing: editingField == "volume",
                onBeginEditing: { beginEdit("volume") },
                onCommit: { val in
                    editedRef.volume = val.isEmpty ? nil : val
                    commitFieldAndSave("volume")
                },
                onCancel: { cancelEdit() }
            )
        case "issue":
            InlineStringRow(
                label: prop.name,
                value: editedRef.issue ?? "",
                isEditing: editingField == "issue",
                onBeginEditing: { beginEdit("issue") },
                onCommit: { val in
                    editedRef.issue = val.isEmpty ? nil : val
                    commitFieldAndSave("issue")
                },
                onCancel: { cancelEdit() }
            )
        case "pages":
            InlineStringRow(
                label: prop.name,
                value: editedRef.pages ?? "",
                isEditing: editingField == "pages",
                onBeginEditing: { beginEdit("pages") },
                onCommit: { val in
                    editedRef.pages = val.isEmpty ? nil : val
                    commitFieldAndSave("pages")
                },
                onCancel: { cancelEdit() }
            )
        case "publisher":
            InlineStringRow(
                label: prop.name,
                value: editedRef.publisher ?? "",
                isEditing: editingField == "publisher",
                onBeginEditing: { beginEdit("publisher") },
                onCommit: { val in
                    editedRef.publisher = val.isEmpty ? nil : val
                    commitFieldAndSave("publisher")
                },
                onCancel: { cancelEdit() }
            )
        case "publisherPlace":
            InlineStringRow(
                label: prop.name,
                value: editedRef.publisherPlace ?? "",
                isEditing: editingField == "publisherPlace",
                onBeginEditing: { beginEdit("publisherPlace") },
                onCommit: { val in
                    editedRef.publisherPlace = val.isEmpty ? nil : val
                    commitFieldAndSave("publisherPlace")
                },
                onCancel: { cancelEdit() }
            )
        case "edition":
            InlineStringRow(
                label: prop.name,
                value: editedRef.edition ?? "",
                isEditing: editingField == "edition",
                onBeginEditing: { beginEdit("edition") },
                onCommit: { val in
                    editedRef.edition = val.isEmpty ? nil : val
                    commitFieldAndSave("edition")
                },
                onCancel: { cancelEdit() }
            )
        case "isbn":
            InlineStringRow(
                label: prop.name,
                value: editedRef.isbn ?? "",
                isEditing: editingField == "isbn",
                onBeginEditing: { beginEdit("isbn") },
                onCommit: { val in
                    editedRef.isbn = val.isEmpty ? nil : val
                    commitFieldAndSave("isbn")
                },
                onCancel: { cancelEdit() }
            )
        case "issn":
            InlineStringRow(
                label: prop.name,
                value: editedRef.issn ?? "",
                isEditing: editingField == "issn",
                onBeginEditing: { beginEdit("issn") },
                onCommit: { val in
                    editedRef.issn = val.isEmpty ? nil : val
                    commitFieldAndSave("issn")
                },
                onCancel: { cancelEdit() }
            )
        case "editors":
            InlineStringRow(
                label: prop.name,
                value: editedRef.parsedEditors.displayString,
                isEditing: editingField == "editors",
                onBeginEditing: { beginEdit("editors") },
                onCommit: { val in
                    editedRef.editors = val.isEmpty ? nil : Reference.encodeNames(AuthorName.parseList(val))
                    commitFieldAndSave("editors")
                },
                onCancel: { cancelEdit() }
            )
        case "translators":
            InlineStringRow(
                label: prop.name,
                value: editedRef.parsedTranslators.displayString,
                isEditing: editingField == "translators",
                onBeginEditing: { beginEdit("translators") },
                onCommit: { val in
                    editedRef.translators = val.isEmpty ? nil : Reference.encodeNames(AuthorName.parseList(val))
                    commitFieldAndSave("translators")
                },
                onCancel: { cancelEdit() }
            )
        case "accessedDate":
            InlineStringRow(
                label: prop.name,
                value: editedRef.accessedDate ?? "",
                isEditing: editingField == "accessedDate",
                onBeginEditing: { beginEdit("accessedDate") },
                onCommit: { val in
                    editedRef.accessedDate = val.isEmpty ? nil : val
                    commitFieldAndSave("accessedDate")
                },
                onCancel: { cancelEdit() }
            )
        case "eventTitle":
            InlineStringRow(
                label: prop.name,
                value: editedRef.eventTitle ?? "",
                isEditing: editingField == "eventTitle",
                onBeginEditing: { beginEdit("eventTitle") },
                onCommit: { val in
                    editedRef.eventTitle = val.isEmpty ? nil : val
                    commitFieldAndSave("eventTitle")
                },
                onCancel: { cancelEdit() }
            )
        case "eventPlace":
            InlineStringRow(
                label: prop.name,
                value: editedRef.eventPlace ?? "",
                isEditing: editingField == "eventPlace",
                onBeginEditing: { beginEdit("eventPlace") },
                onCommit: { val in
                    editedRef.eventPlace = val.isEmpty ? nil : val
                    commitFieldAndSave("eventPlace")
                },
                onCancel: { cancelEdit() }
            )
        case "genre":
            InlineStringRow(
                label: prop.name,
                value: editedRef.genre ?? "",
                isEditing: editingField == "genre",
                onBeginEditing: { beginEdit("genre") },
                onCommit: { val in
                    editedRef.genre = val.isEmpty ? nil : val
                    commitFieldAndSave("genre")
                },
                onCancel: { cancelEdit() }
            )
        case "institution":
            InlineStringRow(
                label: prop.name,
                value: editedRef.institution ?? "",
                isEditing: editingField == "institution",
                onBeginEditing: { beginEdit("institution") },
                onCommit: { val in
                    editedRef.institution = val.isEmpty ? nil : val
                    commitFieldAndSave("institution")
                },
                onCancel: { cancelEdit() }
            )
        case "number":
            InlineStringRow(
                label: prop.name,
                value: editedRef.number ?? "",
                isEditing: editingField == "number",
                onBeginEditing: { beginEdit("number") },
                onCommit: { val in
                    editedRef.number = val.isEmpty ? nil : val
                    commitFieldAndSave("number")
                },
                onCancel: { cancelEdit() }
            )
        case "collectionTitle":
            InlineStringRow(
                label: prop.name,
                value: editedRef.collectionTitle ?? "",
                isEditing: editingField == "collectionTitle",
                onBeginEditing: { beginEdit("collectionTitle") },
                onCommit: { val in
                    editedRef.collectionTitle = val.isEmpty ? nil : val
                    commitFieldAndSave("collectionTitle")
                },
                onCancel: { cancelEdit() }
            )
        case "numberOfPages":
            InlineStringRow(
                label: prop.name,
                value: editedRef.numberOfPages ?? "",
                isEditing: editingField == "numberOfPages",
                onBeginEditing: { beginEdit("numberOfPages") },
                onCommit: { val in
                    editedRef.numberOfPages = val.isEmpty ? nil : val
                    commitFieldAndSave("numberOfPages")
                },
                onCancel: { cancelEdit() }
            )
        case "language":
            InlineStringRow(
                label: prop.name,
                value: editedRef.language ?? "",
                isEditing: editingField == "language",
                onBeginEditing: { beginEdit("language") },
                onCommit: { val in
                    editedRef.language = val.isEmpty ? nil : val
                    commitFieldAndSave("language")
                },
                onCancel: { cancelEdit() }
            )
        case "pmid":
            InlineStringRow(
                label: prop.name,
                value: editedRef.pmid ?? "",
                isEditing: editingField == "pmid",
                onBeginEditing: { beginEdit("pmid") },
                onCommit: { val in
                    editedRef.pmid = val.isEmpty ? nil : val
                    commitFieldAndSave("pmid")
                },
                onCancel: { cancelEdit() }
            )
        case "pmcid":
            InlineStringRow(
                label: prop.name,
                value: editedRef.pmcid ?? "",
                isEditing: editingField == "pmcid",
                onBeginEditing: { beginEdit("pmcid") },
                onCommit: { val in
                    editedRef.pmcid = val.isEmpty ? nil : val
                    commitFieldAndSave("pmcid")
                },
                onCancel: { cancelEdit() }
            )
        case "lastReadAt":
            // Auto-stamped by `AppDatabase.markReferenceRead` on reader open;
            // not user-editable.
            PropertyRowLayout(label: prop.name) {
                if let date = editedRef.lastReadAt {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                } else {
                    Text("Never opened")
                        .font(.system(size: 13))
                        .foregroundStyle(.quaternary)
                }
            }
        case "readCount":
            PropertyRowLayout(label: prop.name) {
                Text(editedRef.readCount, format: .number)
                    .font(.system(size: 13))
                    .foregroundStyle(editedRef.readCount == 0 ? .quaternary : .primary)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func customPropertyRow(for prop: PropertyDefinition) -> some View {
        let propId = prop.id ?? 0
        let currentValue = customValues[propId] ?? ""
        let fieldKey = "custom_\(propId)"

        switch prop.type {
        case .string:
            InlineStringRow(
                label: prop.name,
                value: currentValue,
                isEditing: editingField == fieldKey,
                onBeginEditing: { beginEdit(fieldKey) },
                onCommit: { val in
                    saveCustomValue(propId: propId, value: val.isEmpty ? nil : val)
                    editingField = nil
                },
                onCancel: { cancelEdit() }
            )
        case .url:
            InlineURLRow(
                label: prop.name,
                value: currentValue,
                isEditing: editingField == fieldKey,
                onBeginEditing: { beginEdit(fieldKey) },
                onCommit: { val in
                    saveCustomValue(propId: propId, value: val.isEmpty ? nil : val)
                    editingField = nil
                },
                onCancel: { cancelEdit() }
            )
        case .number:
            InlineNumberRow(
                label: prop.name,
                value: Int(currentValue),
                placeholder: "Empty",
                isEditing: editingField == fieldKey,
                onBeginEditing: { beginEdit(fieldKey) },
                onCommit: { val in
                    saveCustomValue(propId: propId, value: val.map(String.init))
                    editingField = nil
                },
                onCancel: { cancelEdit() }
            )
        case .singleSelect:
            InlineSingleSelectRow(
                label: prop.name,
                value: currentValue,
                options: prop.options,
                onSelect: { val in
                    saveCustomValue(propId: propId, value: val)
                },
                onCreateOption: { newOption in
                    addOptionToProperty(propId: propId, optionValue: newOption)
                },
                onDeleteOption: { optionValue in
                    try? db.deletePropertyOption(propertyId: propId, value: optionValue, clearInUse: true)
                },
                deleteUnlessInUse: { optionValue in
                    db.probeDeletePropertyOption(propertyId: propId, value: optionValue)
                }
            )
        case .multiSelect:
            let selected = PropertyValue.decodeMultiSelect(currentValue)
            InlineMultiSelectOptionRow(
                label: prop.name,
                selectedValues: selected,
                options: prop.options,
                onUpdate: { values in
                    let json = PropertyValue.encodeMultiSelect(values)
                    saveCustomValue(propId: propId, value: json.isEmpty ? nil : json)
                },
                onCreateOption: { newOption in
                    addOptionToProperty(propId: propId, optionValue: newOption)
                },
                onDeleteOption: { optionValue in
                    try? db.deletePropertyOption(propertyId: propId, value: optionValue, clearInUse: true)
                },
                deleteUnlessInUse: { optionValue in
                    db.probeDeletePropertyOption(propertyId: propId, value: optionValue)
                }
            )
        case .checkbox:
            InlineCheckboxRow(
                label: prop.name,
                isChecked: currentValue == "true",
                onToggle: { checked in
                    saveCustomValue(propId: propId, value: checked ? "true" : "false")
                }
            )
        case .date:
            let dateValue = cachedISO8601DateFormatter.date(from: currentValue)
            InlineDateRow(
                label: prop.name,
                value: dateValue,
                onCommit: { date in
                    let str = date.map { cachedISO8601DateFormatter.string(from: $0) }
                    saveCustomValue(propId: propId, value: str)
                }
            )
        }
    }

    // MARK: - Web Reader Card

    @ViewBuilder
    private var webReaderCard: some View {
        let hasClip = hasStoredWebContent
        HStack(spacing: 10) {
            Image(systemName: hasClip ? "doc.text.image" : "safari")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(hasClip
                     ? String(localized: "Clipped article ready", bundle: .module)
                     : String(localized: "Read source article online", bundle: .module))
                    .font(.callout)
                if webAnnotationCount > 0 {
                    Text(String(format: String(localized: "%d annotations", bundle: .module), webAnnotationCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task {
                    guard let prepared = await prepareReferenceForWebReader() else { return }
                    onOpenWebReader?(prepared)
                }
            } label: {
                Label(String(localized: "Read web", bundle: .module), systemImage: "text.book.closed")
            }
            .buttonStyle(SLPrimaryButtonStyle())
            .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - PDF Card

    @ViewBuilder
    private var pdfCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("PDF attached", bundle: .module)
                    .font(.callout)
                if pdfAnnotationCount > 0 {
                    Text(String(format: String(localized: "%d annotations", bundle: .module), pdfAnnotationCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                onOpenPDFReader?(reference)
            } label: {
                Label(String(localized: "Read & annotate", bundle: .module), systemImage: "book.pages")
            }
            .buttonStyle(SLPrimaryButtonStyle())
            .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Abstract Section

    @ViewBuilder
    private var abstractSection: some View {
        let hasAbstract = !(reference.abstract ?? "").isEmpty

        if editingField == "abstract" || hasAbstract {
            HoverRegion { isHovering in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Abstract", bundle: .module)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        if editingField != "abstract" && isHovering {
                            editPencil("abstract", help: String(localized: "Edit abstract", bundle: .module))
                        }
                    }

                    if editingField == "abstract" {
                        TextEditor(text: Binding(
                            get: { editedRef.abstract ?? "" },
                            set: { editedRef.abstract = $0.isEmpty ? nil : $0 }
                        ))
                        .font(.callout)
                        .frame(minHeight: 100)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                        .onExitCommand { commitFieldAndSave("abstract") }

                        HStack {
                            Spacer()
                            Button("Done") { commitFieldAndSave("abstract") }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    } else {
                        Text(reference.abstract ?? "")
                            .font(.callout)
                            .textSelection(.enabled)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Notes Section

    @ViewBuilder
    private var notesSection: some View {
        let hasNotes = !(reference.notes ?? "").isEmpty
        let sectionTitle = reference.referenceType == .webpage
            ? String(localized: "Highlights & notes", bundle: .module)
            : String(localized: "Notes", bundle: .module)

        if editingField == "notes" || hasNotes {
            HoverRegion { isHovering in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(sectionTitle)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        if editingField != "notes" && isHovering {
                            editPencil("notes", help: String(localized: "Edit notes", bundle: .module))
                        }
                    }

                    if editingField == "notes" {
                        TextEditor(text: Binding(
                            get: { editedRef.notes ?? "" },
                            set: { editedRef.notes = $0.isEmpty ? nil : $0 }
                        ))
                        .font(.callout)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                        .onExitCommand { commitFieldAndSave("notes") }

                        HStack {
                            Spacer()
                            Button("Done") { commitFieldAndSave("notes") }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    } else {
                        Text(reference.notes ?? "")
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerSection: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Text(String(format: String(localized: "Added %@", bundle: .module),
                            reference.dateAdded.formatted(date: .abbreviated, time: .shortened)))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    if reference.hasPDFInCache(in: db) {
                        showOverwriteConfirmation = true
                    } else {
                        performPDFDownload(replacingExisting: false)
                    }
                } label: {
                    if isPDFDownloadActive {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(String(localized: "Download PDF", bundle: .module),
                              systemImage: "arrow.down.doc")
                    }
                }
                .buttonStyle(SLPrimaryButtonStyle())
                .controlSize(.small)
                .disabled(
                    !canDownloadPDF
                    || activePDFOperation != nil
                )
                .help(canDownloadPDF ? "" : String(localized: "Needs a DOI or arXiv link", bundle: .module))
                .alert(String(localized: "Replace existing PDF?", bundle: .module),
                       isPresented: $showOverwriteConfirmation) {
                    Button(String(localized: "Replace", bundle: .module), role: .destructive) {
                        performPDFDownload(replacingExisting: true)
                    }
                    Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
                } message: {
                    Text("This will overwrite the current attachment.", bundle: .module)
                }

                Button(String(localized: "Delete reference", bundle: .module), role: .destructive) {
                    onDelete()
                }
                .buttonStyle(SLDestructiveButtonStyle())
            }
            if case .failed(let message) = pdfDownloadState {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .padding(.top, 6)
    }

    // MARK: - Edit Helpers

    private func beginEdit(_ field: String) {
        commitPendingEdit()
        editingField = field
    }

    private func cancelEdit() {
        editedRef = reference
        editingField = nil
    }

    private func commitPendingEdit() {
        guard editingField != nil else { return }
        if editedRef.title != reference.title ||
           editedRef.authors != reference.authors ||
           editedRef.year != reference.year ||
           editedRef.doi != reference.doi ||
           editedRef.url != reference.url ||
           editedRef.journal != reference.journal ||
           editedRef.volume != reference.volume ||
           editedRef.issue != reference.issue ||
           editedRef.pages != reference.pages ||
           editedRef.abstract != reference.abstract ||
           editedRef.notes != reference.notes ||
           editedRef.referenceType != reference.referenceType ||
           editedRef.readingStatus != reference.readingStatus ||
           editedRef.publisher != reference.publisher ||
           editedRef.publisherPlace != reference.publisherPlace ||
           editedRef.edition != reference.edition ||
           editedRef.isbn != reference.isbn ||
           editedRef.issn != reference.issn ||
           editedRef.editors != reference.editors ||
           editedRef.translators != reference.translators ||
           editedRef.accessedDate != reference.accessedDate ||
           editedRef.eventTitle != reference.eventTitle ||
           editedRef.eventPlace != reference.eventPlace ||
           editedRef.genre != reference.genre ||
           editedRef.institution != reference.institution ||
           editedRef.number != reference.number ||
           editedRef.collectionTitle != reference.collectionTitle ||
           editedRef.numberOfPages != reference.numberOfPages ||
           editedRef.language != reference.language ||
           editedRef.pmid != reference.pmid ||
           editedRef.pmcid != reference.pmcid {
            var updated = editedRef
            updated.dateModified = Date()
            onSave(updated)
        }
        editingField = nil
    }

    private func commitFieldAndSave(_ field: String) {
        var updated = editedRef
        updated.dateModified = Date()
        onSave(updated)
        editingField = nil
    }

    private func commitDefaultSave() {
        var updated = editedRef
        updated.dateModified = Date()
        onSave(updated)
    }

    /// The edit affordance for the four "prose" fields whose display text stays
    /// `.textSelection(.enabled)`. A bare `.onTapGesture` on selectable text never
    /// fires on macOS (the text layer swallows the click), so a `Button` gives a
    /// reliable target while the text stays selectable/copyable. Callers insert it
    /// only while the field is hovered (see `HoverRegion`), keeping it out of the
    /// view/accessibility tree otherwise. `EditPencilButton` carries the visuals.
    @ViewBuilder
    private func editPencil(_ field: String, help: String) -> some View {
        EditPencilButton(help: help) { beginEdit(field) }
    }

    // MARK: - Custom Property Helpers

    private func saveCustomValue(propId: Int64, value: String?) {
        guard let refId = reference.id else { return }
        do {
            try db.setPropertyValue(referenceId: refId, propertyId: propId, value: value)
            // Mirror into local state only after the write succeeds, so a failed
            // write doesn't leave the panel showing a value that wasn't persisted.
            if let value {
                customValues[propId] = value
            } else {
                customValues.removeValue(forKey: propId)
            }
        } catch {
            detailLog.error("setPropertyValue failed ref=\(refId, privacy: .public) prop=\(propId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func addOptionToProperty(propId: Int64, optionValue: String) {
        guard var prop = propertyDefs.first(where: { $0.id == propId }) else { return }
        if prop.addOptionIfMissing(optionValue) {
            try? db.savePropertyDefinition(&prop)
        }
    }

    // MARK: - PDF Download

    private var canDownloadPDF: Bool { reference.canDownloadPDF }

    private func performPDFDownload(replacingExisting: Bool) {
        guard let id = reference.id,
              pdfOperations.begin(.download, for: id) else { return }
        pdfDownloadState = .downloading

        let database = db
        let selectedReference = reference
        let coordinator = syncCoordinator
        Task { @MainActor in
            let outcome = await ReferenceDetailPDFAttachmentWorker.downloadAndAttach(
                reference: selectedReference,
                referenceId: id,
                database: database,
                replacingExisting: replacingExisting
            )
            pdfOperations.finish(.download, for: id)

            if outcome == .attached {
                Task { await coordinator?.kickPDFUploadDrainer() }
            }

            guard editedRef.id == id else { return }
            switch outcome {
            case .attached:
                pdfDownloadState = .idle
            case .alreadyAttached:
                pdfDownloadState = .failed(
                    String(localized: "Another PDF was attached while the download was running", bundle: .module)
                )
            case .failed(let message):
                pdfDownloadState = .failed(message)
            }
        }
    }

    /// Copy a user-picked PDF into storage and atomically register its cache /
    /// upload rows plus the reference modification stamp. File I/O and the
    /// SQLite writer wait both run detached so MCP activity cannot freeze the
    /// main run loop.
    private func attachPDF(from sourceURL: URL) {
        guard let id = editedRef.id,
              pdfOperations.begin(.attachment, for: id) else { return }
        pdfAttachmentState = .attaching

        let database = db
        let coordinator = syncCoordinator
        Task { @MainActor in
            let outcome = await ReferenceDetailPDFAttachmentWorker.attach(
                sourceURL: sourceURL,
                referenceId: id,
                database: database
            )
            pdfOperations.finish(.attachment, for: id)

            if outcome == .attached {
                Task { await coordinator?.kickPDFUploadDrainer() }
            }

            // Selection can change while a large or cloud-backed PDF copies.
            guard editedRef.id == id else { return }
            switch outcome {
            case .attached, .alreadyAttached:
                pdfAttachmentState = .idle
            case .failed(let message):
                detailLog.error("Manual PDF attachment failed for reference \(id, privacy: .public): \(message, privacy: .public)")
                pdfAttachmentState = .failed(message)
            }
        }
    }

    private func revealAttachedPDF() {
        guard let id = editedRef.id else { return }
        let cache = PDFAssetCache(db: db, storageRoot: AppDatabase.pdfStorageURL)

        Task {
            guard let url = try? await cache.pathFor(referenceId: id) else { return }
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// Detach the currently-cached PDF from this reference: removes the file
    /// from disk plus the `pdfCache` and `pdfUploadQueue` rows. Bumps
    /// `dateModified` like the attach path.
    private func removeAttachedPDF() {
        guard let id = editedRef.id,
              pdfOperations.operation(for: id) == nil else { return }
        if let filename = try? db.pdfFilename(for: id) {
            let url = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        }
        try? db.detachReferencePDF(id: id)
        cachedHasPDFInCache = false
        var updated = editedRef
        updated.dateModified = Date()
        onSave(updated)
    }

    // MARK: - Web Reader

    private var canOpenWebReader: Bool {
        hasStoredWebContent
            || (reference.referenceType == .webpage && resolvedWebReaderURLString != nil)
    }

    private var resolvedWebReaderURLString: String? {
        let value = reference.resolvedWebReaderURLString()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func prepareReferenceForWebReader() async -> Reference? {
        guard let referenceID = reference.id else { return nil }
        if !hasStoredWebContent { return reference }

        let webContent = await Task.detached(priority: .userInitiated) { [db] in
            try? db.fetchWebContent(id: referenceID)
        }.value

        guard !Task.isCancelled, reference.id == referenceID else { return nil }
        var prepared = reference
        prepared.webContent = webContent
        return prepared
    }

    // MARK: - Quick Preview (Space key)

    private var quickPreviewShortcut: some View {
        Button {
            openQuickPreviewWindow()
        } label: {
            EmptyView()
        }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(!isActive)
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func openQuickPreviewWindow() {
        guard let id = reference.id,
              let filename = try? db.pdfFilename(for: id) else { return }
        let url = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
        let minimumSize = NSSize(width: 760, height: 900)
        let preferredSize = preferredQuickPreviewWindowSize(minimumSize: minimumSize)
        let autosaveName = "RubienPDFQuickPreview"

        if let previewWindow {
            if previewWindow.isVisible && !previewWindow.isMiniaturized {
                closeQuickPreviewWindow()
                return
            }
            previewWindow.deminiaturize(nil)
            enforceQuickPreviewWindowSizeIfNeeded(previewWindow, minimumSize: minimumSize, preferredSize: preferredSize)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: preferredSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = reference.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? url.lastPathComponent : reference.title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = minimumSize
        window.titleVisibility = {
            if #available(macOS 26.0, *) { return .hidden }
            return .visible
        }()
        window.setFrameAutosaveName(autosaveName)
        let restoredFrame = window.setFrameUsingName(autosaveName)
        enforceQuickPreviewWindowSizeIfNeeded(window, minimumSize: minimumSize, preferredSize: preferredSize)

        window.contentViewController = makeRubienHostingController(
            rootView: PDFPreviewView(url: url) { window.close() }
        )
        if !restoredFrame { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        previewWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            previewWindow = nil
            if let observer = previewWindowCloseObserver {
                NotificationCenter.default.removeObserver(observer)
                previewWindowCloseObserver = nil
            }
        }
        previewWindow = window
    }

    private func preferredQuickPreviewWindowSize(minimumSize: NSSize) -> NSSize {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 960)
        let width = min(max(minimumSize.width, 920), max(minimumSize.width, visibleFrame.width - 120))
        let height = min(max(minimumSize.height, 1100), max(minimumSize.height, visibleFrame.height - 120))
        return NSSize(width: width, height: height)
    }

    private func enforceQuickPreviewWindowSizeIfNeeded(_ window: NSWindow, minimumSize: NSSize, preferredSize: NSSize) {
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 960)
        let currentFrame = window.frame
        guard currentFrame.width < minimumSize.width || currentFrame.height < minimumSize.height else { return }
        let safeWidth = min(max(preferredSize.width, minimumSize.width), visibleFrame.width - 40)
        let safeHeight = min(max(preferredSize.height, minimumSize.height), visibleFrame.height - 40)
        let origin = NSPoint(x: visibleFrame.midX - safeWidth / 2, y: visibleFrame.midY - safeHeight / 2)
        window.setFrame(NSRect(origin: origin, size: NSSize(width: safeWidth, height: safeHeight)), display: false)
    }

    private func closeQuickPreviewWindow() {
        previewWindow?.close()
        previewWindow = nil
        if let observer = previewWindowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            previewWindowCloseObserver = nil
        }
    }

    // MARK: - Data Loading

    private func loadSupplementaryData(for referenceID: Int64?) async {
        guard let referenceID else {
            referenceTags = []
            pdfAnnotationCount = 0
            webAnnotationCount = 0
            hasStoredWebContent = false
            return
        }

        struct Payload: Sendable {
            var tags: [Tag]
            var pdfAnnotationCount: Int
            var webAnnotationCount: Int
            var hasStoredWebContent: Bool
        }

        let payload = await Task.detached(priority: .userInitiated) { [db] in
            Payload(
                tags: (try? db.fetchTags(forReference: referenceID)) ?? [],
                pdfAnnotationCount: (try? db.annotationCount(referenceId: referenceID)) ?? 0,
                webAnnotationCount: (try? db.webAnnotationCount(referenceId: referenceID)) ?? 0,
                hasStoredWebContent: (try? db.hasWebContent(id: referenceID)) ?? false
            )
        }.value

        guard !Task.isCancelled, reference.id == referenceID else { return }
        referenceTags = payload.tags
        pdfAnnotationCount = payload.pdfAnnotationCount
        webAnnotationCount = payload.webAnnotationCount
        hasStoredWebContent = payload.hasStoredWebContent
    }

    private func loadCustomPropertyValues(for referenceID: Int64?) async {
        guard let referenceID else {
            customValues = [:]
            return
        }
        let values = await Task.detached(priority: .userInitiated) { [db] in
            (try? db.fetchPropertyValues(forReference: referenceID)) ?? []
        }.value
        guard !Task.isCancelled, reference.id == referenceID else { return }
        var map: [Int64: String] = [:]
        for pv in values {
            if let val = pv.value { map[pv.propertyId] = val }
        }
        customValues = map
    }
}

// MARK: - Inline Title Editor

/// Hosts hover state locally for one inline-editable region and passes the
/// current hover flag into its content (used to reveal an `editPencil`). Keeping
/// the flag in this small subview — rather than a shared `@State` on
/// `ReferenceDetailView` — means a mouse enter/leave only re-evaluates this
/// region, not the whole detail panel. Mirrors the local-`Bool` `.onHover`
/// pattern used across the app.
///
/// `.contentShape(Rectangle())` makes the *entire* frame hoverable, including the
/// empty gap between a leading, full-width `Text` and a trailing pencil. Without
/// it, that gap isn't hit-tested, so moving the pointer toward the revealed pencil
/// drops the hover and the pencil vanishes before it can be clicked.
private struct HoverRegion<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var isHovering = false

    var body: some View {
        content(isHovering)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// The hover-revealed pencil for an inline-editable prose field. Owns its own
/// hover state so it can read as a real, clickable button: a subtle rounded chip
/// that brightens, an accent-tinted glyph, and a link (pointing-hand) cursor when
/// the pointer is on target — so it's easy to spot and gives a clear on-hover cue.
private struct EditPencilButton: View {
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovered ? Color.accentColor : Color.secondary)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.10 : 0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .linkPointerStyle()
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct InlineTitleEditor: View {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Title", text: $text)
            .font(.title2.bold())
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit { onCommit() }
            .onExitCommand { onCancel() }
            .onAppear { isFocused = true }
            .onChange(of: isFocused) { _, focused in
                if !focused { onCommit() }
            }
    }
}

// MARK: - Inline Authors Editor

private struct InlineAuthorsEditor: View {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Authors (e.g. John Smith; Jane Doe)", text: $text)
            .font(.body)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit { onCommit() }
            .onExitCommand { onCancel() }
            .onAppear { isFocused = true }
            .onChange(of: isFocused) { _, focused in
                if !focused { onCommit() }
            }
    }
}
#endif
