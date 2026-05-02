import SwiftUI
import PDFKit
import RubienCore

struct ReferenceDetailView: View {
    let reference: Reference
    let allTags: [Tag]
    let db: AppDatabase
    let onSave: (Reference) -> Void
    let onDelete: () -> Void
    var onOpenPDFReader: ((Reference) -> Void)?
    var onOpenWebReader: ((Reference) -> Void)?
    var onUpdateTags: ((Int64, [Int64]) -> Void)?
    var onCreateTag: ((String) -> Int64?)?
    var onDeleteTag: ((Int64) -> Void)?

    @State private var editedRef: Reference
    @State private var editingField: String?
    @State private var previewWindow: NSWindow?
    @State private var previewWindowCloseObserver: NSObjectProtocol?
    @State private var referenceTags: [Tag] = []
    @State private var pdfAnnotationCount: Int = 0
    @State private var webAnnotationCount: Int = 0
    @State private var hasStoredWebContent = false
    @State private var pdfDownloadState: PDFDownloadState = .idle
    @State private var showOverwriteConfirmation = false
    @Binding var propertyDefs: [PropertyDefinition]
    @State private var customValues: [Int64: String] = [:]
    @State private var showPropertyManager = false

    @EnvironmentObject private var syncCoordinator: SyncCoordinator

    private enum PDFDownloadState {
        case idle, downloading, failed(String)
        var isDownloading: Bool { if case .downloading = self { return true } else { return false } }
    }

    let liveTags: [Tag]

    init(reference: Reference, allTags: [Tag], liveTags: [Tag] = [], db: AppDatabase,
         onSave: @escaping (Reference) -> Void, onDelete: @escaping () -> Void,
         onOpenPDFReader: ((Reference) -> Void)? = nil, onOpenWebReader: ((Reference) -> Void)? = nil,
         onUpdateTags: ((Int64, [Int64]) -> Void)? = nil,
         onCreateTag: ((String) -> Int64?)? = nil,
         onDeleteTag: ((Int64) -> Void)? = nil,
         propertyDefs: Binding<[PropertyDefinition]>) {
        self.reference = reference
        self.allTags = allTags
        self.liveTags = liveTags
        self.db = db
        self.onSave = onSave
        self.onDelete = onDelete
        self.onOpenPDFReader = onOpenPDFReader
        self.onOpenWebReader = onOpenWebReader
        self.onUpdateTags = onUpdateTags
        self.onCreateTag = onCreateTag
        self.onDeleteTag = onDeleteTag
        self._editedRef = State(initialValue: reference)
        self._propertyDefs = propertyDefs
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                propertiesCard
                if canOpenWebReader { webReaderCard }
                if reference.hasPDFInCache(in: db) { pdfCard }
                abstractSection
                notesSection
                footerSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            if editingField == nil, reference.hasPDFInCache(in: db) {
                quickPreviewShortcut
            }
        }
        .onChange(of: reference) { oldRef, newRef in
            commitPendingEdit()
            closeQuickPreviewWindow()
            editedRef = newRef
            editingField = nil
            guard oldRef.id != newRef.id else { return }
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
        .onChange(of: liveTags) { _, newTags in
            referenceTags = newTags
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
                Text(reference.title)
                    .font(.title2.bold())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { beginEdit("title") }
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
                Text(reference.authors.displayString)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
                    .onTapGesture { beginEdit("authors") }
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
                if editedRef.hasPDFInCache(in: db) {
                    HStack(spacing: 8) {
                        Label("Attached", systemImage: "doc.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("Remove") {
                            removeAttachedPDF()
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        if let url = OpenPanelPicker.pickPDFFile() {
                            attachPDF(from: url)
                        }
                    } label: {
                        Label("Attach PDF...", systemImage: "plus")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
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
                    if var statusDef = propertyDefs.first(where: { $0.defaultFieldKey == "readingStatus" }) {
                        _ = statusDef.addOptionIfMissing(newOption)
                        try? db.savePropertyDefinition(&statusDef)
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
                }
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
            let dateValue = ISO8601DateFormatter().date(from: currentValue)
            InlineDateRow(
                label: prop.name,
                value: dateValue,
                onCommit: { date in
                    let str = date.map { ISO8601DateFormatter().string(from: $0) }
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Abstract", bundle: .module)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

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
                        .contentShape(Rectangle())
                        .onTapGesture { beginEdit("abstract") }
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
            VStack(alignment: .leading, spacing: 6) {
                Text(sectionTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

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
                        .contentShape(Rectangle())
                        .onTapGesture { beginEdit("notes") }
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
                        performPDFDownload()
                    }
                } label: {
                    if pdfDownloadState.isDownloading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(String(localized: "Download PDF", bundle: .module),
                              systemImage: "arrow.down.doc")
                    }
                }
                .buttonStyle(SLPrimaryButtonStyle())
                .controlSize(.small)
                .disabled(!canDownloadPDF || pdfDownloadState.isDownloading)
                .help(canDownloadPDF ? "" : String(localized: "Needs a DOI or arXiv link", bundle: .module))
                .alert(String(localized: "Replace existing PDF?", bundle: .module),
                       isPresented: $showOverwriteConfirmation) {
                    Button(String(localized: "Replace", bundle: .module), role: .destructive) {
                        performPDFDownload()
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

    // MARK: - Custom Property Helpers

    private func saveCustomValue(propId: Int64, value: String?) {
        guard let refId = reference.id else { return }
        if let value {
            customValues[propId] = value
        } else {
            customValues.removeValue(forKey: propId)
        }
        try? db.setPropertyValue(referenceId: refId, propertyId: propId, value: value)
    }

    private func addOptionToProperty(propId: Int64, optionValue: String) {
        guard var prop = propertyDefs.first(where: { $0.id == propId }) else { return }
        if prop.addOptionIfMissing(optionValue) {
            try? db.savePropertyDefinition(&prop)
        }
    }

    // MARK: - PDF Download

    private var canDownloadPDF: Bool { reference.canDownloadPDF }

    private func performPDFDownload() {
        pdfDownloadState = .downloading
        Task {
            do {
                // Swap out any prior PDF: remove the on-disk file + cache row
                // first so the new download doesn't orphan the old asset.
                if let id = reference.id,
                   let oldFilename = try? db.pdfFilename(for: id) {
                    let oldURL = AppDatabase.pdfStorageURL.appendingPathComponent(oldFilename)
                    try? FileManager.default.removeItem(at: oldURL)
                    try? db.detachReferencePDF(id: id)
                }
                let newPath = try await PDFDownloadService.downloadPDF(for: reference)
                if let id = reference.id {
                    try db.attachImportedPDFs(rowIds: [id], filenames: [newPath])
                    Task { await syncCoordinator.kickPDFUploadDrainer() }
                }
                var updated = reference
                updated.dateModified = Date()
                onSave(updated)
                pdfDownloadState = .idle
            } catch {
                pdfDownloadState = .failed(error.localizedDescription)
            }
        }
    }

    /// Copy a user-picked PDF into storage and register a fresh cache row +
    /// upload-queue row for the reference. Bumps `dateModified` so the
    /// reference still reflects "recently changed" in the UI even though the
    /// reference row itself hasn't changed any fields.
    private func attachPDF(from sourceURL: URL) {
        guard let id = editedRef.id else { return }
        guard let filename = try? PDFService.importPDF(from: sourceURL) else { return }
        do {
            try db.attachImportedPDFs(rowIds: [id], filenames: [filename])
        } catch {
            // Roll back the on-disk copy so we don't orphan a file with no cache row.
            PDFService.deletePDF(at: filename)
            return
        }
        Task { await syncCoordinator.kickPDFUploadDrainer() }
        var updated = editedRef
        updated.dateModified = Date()
        onSave(updated)
    }

    /// Detach the currently-cached PDF from this reference: removes the file
    /// from disk plus the `pdfCache` and `pdfUploadQueue` rows. Bumps
    /// `dateModified` like the attach path.
    private func removeAttachedPDF() {
        guard let id = editedRef.id else { return }
        if let filename = try? db.pdfFilename(for: id) {
            let url = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        }
        try? db.detachReferencePDF(id: id)
        var updated = editedRef
        updated.dateModified = Date()
        onSave(updated)
    }

    // MARK: - Web Reader

    private var canOpenWebReader: Bool {
        reference.referenceType == .webpage && (hasStoredWebContent || resolvedWebReaderURLString != nil)
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

        window.contentViewController = NSHostingController(
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
