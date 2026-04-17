import SwiftUI
import RubienCore

struct ReferenceTableView: View {
    let references: [Reference]
    let tagMap: [Int64: [Tag]]
    let allTags: [Tag]
    let selectedId: Int64?
    let onSelect: (Int64) -> Void
    let onDelete: ([Reference]) -> Void
    let onRefreshMetadata: ([Reference]) -> Void
    let onUpdateReference: (Reference) -> Void
    let onUpdateTags: (Int64, [Int64]) -> Void
    let onCreateTag: (Int64, String) -> Void
    let onDeleteTag: (Int64) -> Void
    let onCreateOption: (Int64, String) -> Void
    var isRefreshingMetadata = false
    var onDoubleClick: ((Int64) -> Void)? = nil

    @Binding var columnConfigs: [ColumnConfig]
    @Binding var sorts: [ViewSort]
    @Binding var filters: [ViewFilter]
    @Binding var propertyDefs: [PropertyDefinition]
    let db: AppDatabase
    let customPropertyValueMap: [Int64: [Int64: String]]
    var viewName: String? = nil
    var isDirty: Bool = false
    var onSaveView: () -> Void = {}
    var onDiscardView: () -> Void = {}

    @State private var selection = Set<Reference.ID>()
    @State private var showDeleteConfirm = false
    @State private var showPropertyManager = false

    var body: some View {
        VStack(spacing: 0) {
            ViewChromeBar(
                viewName: viewName,
                filters: $filters,
                sorts: $sorts,
                tags: allTags,
                propertyDefs: propertyDefs,
                isDirty: isDirty,
                onSave: onSaveView,
                onDiscard: onDiscardView
            )
            if references.isEmpty {
                emptyState
            } else {
                tableContent
                if !selection.isEmpty {
                    batchToolbar
                }
            }
        }
        .navigationTitle(String(localized: "References", bundle: .module))
        .navigationSubtitle(subtitleText)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showPropertyManager.toggle()
                } label: {
                    Label("Properties", systemImage: "slider.horizontal.3")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12))
                }
                .help("Manage properties")
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
        }
        .onKeyPress(.init("a"), phases: .down) { event in
            if event.modifiers.contains(.command) {
                selection = Set(references.map(\.id))
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            if !selection.isEmpty {
                selection.removeAll()
                return .handled
            }
            return .ignored
        }
        .confirmationDialog(
            String(format: String(localized: "Delete %d references?", bundle: .module), selection.count),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "common.delete", bundle: .module), role: .destructive) { batchDelete() }
            Button(String(localized: "common.cancel", bundle: .module), role: .cancel) {}
        } message: {
            Text("This action cannot be undone.", bundle: .module)
        }
    }

    // MARK: - Table

    private var visibleColumns: [ColumnConfig] {
        columnConfigs
            .filter(\.isVisible)
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    private var tableContent: some View {
        ReferenceTableContent(
            references: processedReferences,
            tagMap: tagMap,
            allTags: allTags,
            selection: $selection,
            tableSortOrder: $tableSortOrder,
            onUpdateReference: onUpdateReference,
            onUpdateTags: onUpdateTags,
            onCreateTag: onCreateTag,
            onDeleteTag: onDeleteTag,
            onCreateOption: onCreateOption,
            customProperties: propertyDefs.filter { prop in
                guard prop.isVisible else { return false }
                if !prop.isDefault { return true }
                // Include visible defaults that don't have hardcoded columns
                let hardcodedKeys: Set<String> = ["tags", "readingStatus"]
                guard let key = prop.defaultFieldKey else { return false }
                return !hardcodedKeys.contains(key)
            },
            customPropertyValueMap: customPropertyValueMap,
            db: db
        )
        .contextMenu(forSelectionType: Reference.ID.self) { ids in
            if let id = ids.first, let ref = references.first(where: { $0.id == id }) {
                contextMenuContent(for: ref)
            }
        }
        .onChange(of: selection) { _, newValue in
            if newValue.count == 1, let optId = newValue.first, let id = optId {
                onSelect(id)
            }
        }
        .onChange(of: tableSortOrder) { _, newOrder in
            guard let first = newOrder.first else { return }
            let target = FieldTarget.builtin(sortKeyToColumn(first))
            let newPrimary = ViewSort(target: target, ascending: first.order == .forward)
            // Preserve popover-configured tiebreakers; drop any existing sort on
            // the new primary's target so it doesn't duplicate.
            let tiebreakers = sorts.filter { $0.target != target }
            let updated = [newPrimary] + tiebreakers
            if updated != sorts {
                sorts = updated
            }
        }
        .onChange(of: sorts) { _, newSorts in
            let mirrored = headerOrder(from: newSorts.first)
            if mirrored != tableSortOrder {
                tableSortOrder = mirrored
            }
        }
    }

    /// Bridges the primary `ViewSort` back into SwiftUI `Table`'s native
    /// `sortOrder` binding so the header arrow reflects popover edits. Returns
    /// `[]` for targets that don't map to a natively-sortable TableColumn
    /// (custom properties, or built-ins we don't expose as Table columns).
    private func headerOrder(from sort: ViewSort?) -> [KeyPathComparator<Reference>] {
        guard let sort, case .builtin(let column) = sort.target,
              let comparator = nativeComparator(for: column, ascending: sort.ascending) else {
            return []
        }
        return [comparator]
    }

    /// Only the columns actually rendered as sortable `TableColumn`s below.
    /// Other `ColumnIdentifier`s are sortable via the popover but have no
    /// header arrow to mirror.
    private func nativeComparator(for column: ColumnIdentifier, ascending: Bool) -> KeyPathComparator<Reference>? {
        let order: SortOrder = ascending ? .forward : .reverse
        switch column {
        case .title:           return KeyPathComparator(\.title, order: order)
        case .authors:         return KeyPathComparator(\.authorsNormalized, order: order)
        case .dateAdded:       return KeyPathComparator(\.dateAdded, order: order)
        case .readingStatus:   return KeyPathComparator(\.readingStatus.rawValue, order: order)
        default:               return nil
        }
    }

    @State private var tableSortOrder: [KeyPathComparator<Reference>] = [
        .init(\.dateAdded, order: .reverse)
    ]

    // MARK: - Pipeline

    private var processedReferences: [Reference] {
        let context = PipelineContext(
            tagMap: tagMap,
            propertyValueMap: customPropertyValueMap,
            propertyDefs: propertyDefs,
            now: Date()
        )
        let filtered = FilterEngine.apply(references, filters: filters, context: context)
        return SortEngine.apply(filtered, sorts: sorts, context: context)
    }

    private func sortKeyToColumn(_ comparator: KeyPathComparator<Reference>) -> ColumnIdentifier {
        switch comparator.keyPath {
        case \Reference.title:            return .title
        case \Reference.authorsNormalized: return .authors
        case \Reference.dateAdded:        return .dateAdded
        case \Reference.dateModified:     return .dateModified
        case \Reference.year:             return .year
        case \Reference.journal:          return .journal
        case \Reference.readingStatus.rawValue: return .readingStatus
        case \Reference.priority.rawValue:      return .priority
        default: return .dateAdded
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuContent(for ref: Reference) -> some View {
        if selection.count > 1 && selection.contains(ref.id) {
            Button(String(format: String(localized: "Refresh metadata for %d selected", bundle: .module), selection.count)) {
                batchRefreshMetadata()
            }
            .disabled(isRefreshingMetadata)
            Divider()
            Button(String(format: String(localized: "Delete %d selected", bundle: .module), selection.count), role: .destructive) {
                showDeleteConfirm = true
            }
            Divider()
            Button(String(localized: "Clear selection", bundle: .module)) { selection.removeAll() }
        } else {
            Button(String(localized: "Refresh metadata", bundle: .module)) {
                onRefreshMetadata([ref])
            }
            .disabled(isRefreshingMetadata)
            Divider()
            Button(String(localized: "common.delete", bundle: .module), role: .destructive) {
                onDelete([ref])
            }
        }
    }

    // MARK: - Batch Toolbar

    private var batchToolbar: some View {
        HStack(spacing: 10) {
            Text(String(format: String(localized: "%d selected", bundle: .module), selection.count))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label(String(localized: "common.delete", bundle: .module), systemImage: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            Divider().frame(height: 16)
            Button { batchRefreshMetadata() } label: {
                Label(String(localized: "Refresh metadata", bundle: .module), systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isRefreshingMetadata)
            Divider().frame(height: 16)
            Button { selection.removeAll() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No references yet", bundle: .module)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Use the + toolbar button to add references,\nor import a .bib / .ris file.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var subtitleText: String {
        if !selection.isEmpty {
            return String(format: String(localized: "%d / %d selected", bundle: .module), selection.count, references.count)
        }
        return String(format: String(localized: "%d references", bundle: .module), references.count)
    }

    private func batchDelete() {
        let toDelete = references.filter { selection.contains($0.id) }
        selection.removeAll()
        onDelete(toDelete)
    }

    private func batchRefreshMetadata() {
        let toRefresh = references.filter { selection.contains($0.id) }
        guard !toRefresh.isEmpty else { return }
        onRefreshMetadata(toRefresh)
    }
}

// MARK: - Table Content (split out to help type checker)

private struct ReferenceTableContent: View {
    let references: [Reference]
    let tagMap: [Int64: [Tag]]
    let allTags: [Tag]
    @Binding var selection: Set<Reference.ID>
    @Binding var tableSortOrder: [KeyPathComparator<Reference>]
    let onUpdateReference: (Reference) -> Void
    let onUpdateTags: (Int64, [Int64]) -> Void
    let onCreateTag: (Int64, String) -> Void
    let onDeleteTag: (Int64) -> Void
    let onCreateOption: (Int64, String) -> Void
    let customProperties: [PropertyDefinition]
    let customPropertyValueMap: [Int64: [Int64: String]]
    let db: AppDatabase

    @State private var columnCustomization: TableColumnCustomization<Reference> = {
        guard let data = UserDefaults.standard.data(forKey: RubienPreferences.tableColumnCustomizationKey),
              let decoded = try? JSONDecoder().decode(TableColumnCustomization<Reference>.self, from: data) else {
            return TableColumnCustomization<Reference>()
        }
        return decoded
    }()

    @State private var editingCell: EditingCellID? = nil

    private func isEditing(_ refId: Int64?, _ key: String) -> Bool {
        guard let refId else { return false }
        return editingCell == EditingCellID(referenceId: refId, fieldKey: key)
    }
    private func beginEdit(_ refId: Int64?, _ key: String) {
        guard let refId else { return }
        editingCell = EditingCellID(referenceId: refId, fieldKey: key)
    }
    private func cancel() { editingCell = nil }
    private func commitRef(_ updated: Reference) {
        var u = updated
        u.dateModified = Date()
        onUpdateReference(u)
        editingCell = nil
    }
    private func commitCustom(refId: Int64, propId: Int64, value: String?) {
        try? db.setPropertyValue(referenceId: refId, propertyId: propId, value: value)
        editingCell = nil
    }

    // Tab skips columns hidden via `TableColumnCustomization` — landing on an
    // invisible editor would strand `editingCell` and block Return-to-edit.
    private func editableColumnKeys() -> [String] {
        var keys: [String] = [ColumnIdentifier.title.rawValue]
        // Title has `.disabledCustomizationBehavior(.visibility)` — always visible.
        if columnCustomization[visibility: ColumnIdentifier.authors.rawValue] != .hidden {
            keys.append(ColumnIdentifier.authors.rawValue)
        }
        let alreadyHandled: Set<String> = Set(
            [ColumnIdentifier.title, .authors, .tags, .readingStatus, .dateAdded, .referenceType]
                .map(\.rawValue)
        )
        for prop in customProperties {
            guard columnCustomization[visibility: prop.customizationID] != .hidden else { continue }
            if prop.isDefault {
                guard let key = prop.defaultFieldKey, !alreadyHandled.contains(key) else { continue }
                keys.append(key)
            } else if prop.id != nil {
                switch prop.type {
                case .string, .url, .number:
                    keys.append(prop.customizationID)
                case .singleSelect, .multiSelect, .checkbox, .date:
                    continue
                }
            }
        }
        return keys
    }

    private func advanceEdit(from refId: Int64, fieldKey: String, backwards: Bool) {
        let keys = editableColumnKeys()
        guard let idx = keys.firstIndex(of: fieldKey) else { cancel(); return }
        let nextIdx = backwards ? idx - 1 : idx + 1
        guard keys.indices.contains(nextIdx) else { cancel(); return }
        beginEdit(refId, keys[nextIdx])
    }

    var body: some View {
        Table(references, selection: $selection, sortOrder: $tableSortOrder, columnCustomization: $columnCustomization) {
            TableColumn(ColumnIdentifier.title.header, value: \.title) { ref in
                EditableStringCell(
                    value: ref.title,
                    isEditing: isEditing(ref.id, "title"),
                    onBeginEdit: { beginEdit(ref.id, "title") },
                    onCommit: { val in
                        var u = ref
                        u.title = val
                        commitRef(u)
                    },
                    onCancel: cancel,
                    placeholder: "Untitled",
                    onTab: { back in
                        if let id = ref.id {
                            advanceEdit(from: id, fieldKey: ColumnIdentifier.title.rawValue, backwards: back)
                        }
                    }
                )
            }
            .width(min: 150, ideal: 250)
            .customizationID(ColumnIdentifier.title.rawValue)
            .disabledCustomizationBehavior(.visibility)

            TableColumn(ColumnIdentifier.authors.header, value: \.authorsNormalized) { ref in
                EditableStringCell(
                    value: ref.authors.displayString,
                    isEditing: isEditing(ref.id, "authors"),
                    onBeginEdit: { beginEdit(ref.id, "authors") },
                    onCommit: { val in
                        var u = ref
                        u.authors = AuthorName.parseList(val)
                        commitRef(u)
                    },
                    onCancel: cancel,
                    onTab: { back in
                        if let id = ref.id {
                            advanceEdit(from: id, fieldKey: ColumnIdentifier.authors.rawValue, backwards: back)
                        }
                    }
                )
            }
            .width(min: 80, ideal: 140)
            .customizationID(ColumnIdentifier.authors.rawValue)

            TableColumn(ColumnIdentifier.tags.header, value: \.title) { ref in
                TagsCellView(
                    tags: tagMap[ref.id ?? -1] ?? [],
                    allTags: allTags,
                    referenceId: ref.id ?? -1,
                    onUpdateTags: { tagIds in onUpdateTags(ref.id ?? -1, tagIds) },
                    onCreateTag: { name in onCreateTag(ref.id ?? -1, name) },
                    onDeleteTag: onDeleteTag
                )
            }
            .width(min: 60, ideal: 120)
            .customizationID(ColumnIdentifier.tags.rawValue)

            TableColumn(ColumnIdentifier.readingStatus.header, value: \.readingStatus.rawValue) { ref in
                ReadingStatusCell(reference: ref, onUpdate: onUpdateReference)
            }
            .width(min: 70, ideal: 90)
            .customizationID(ColumnIdentifier.readingStatus.rawValue)

            TableColumn(ColumnIdentifier.dateAdded.header, value: \.dateAdded) { ref in
                Text(ref.dateAdded, style: .date)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            .customizationID(ColumnIdentifier.dateAdded.rawValue)

            TableColumnForEach(customProperties) { prop in
                TableColumn(prop.name) { ref in
                    if prop.isDefault, let key = prop.defaultFieldKey {
                        EditableDefaultPropertyCell(
                            reference: ref,
                            fieldKey: key,
                            property: prop,
                            isEditing: { key in isEditing(ref.id, key) },
                            onBeginEdit: { key in beginEdit(ref.id, key) },
                            onCancel: cancel,
                            commitRef: commitRef,
                            onTab: { back in
                                if let id = ref.id {
                                    advanceEdit(from: id, fieldKey: key, backwards: back)
                                }
                            }
                        )
                    } else if let refId = ref.id {
                        let customKey = "custom_\(prop.id ?? 0)"
                        EditableCustomPropertyCell(
                            referenceId: refId,
                            property: prop,
                            rawValue: customPropertyValueMap[refId]?[prop.id ?? 0],
                            isEditing: { key in isEditing(refId, key) },
                            onBeginEdit: { key in beginEdit(refId, key) },
                            onCancel: cancel,
                            commitCustom: commitCustom,
                            onCreateOption: onCreateOption,
                            onTab: { back in
                                advanceEdit(from: refId, fieldKey: customKey, backwards: back)
                            }
                        )
                    } else {
                        Text("—")
                            .font(.callout)
                            .foregroundStyle(.quaternary)
                    }
                }
                .width(min: 60, ideal: 100)
                .customizationID(prop.customizationID)
            }
        }
        .onKeyPress(.return) {
            guard editingCell == nil,
                  selection.count == 1,
                  let id = selection.first ?? nil else {
                return .ignored
            }
            beginEdit(id, ColumnIdentifier.title.rawValue)
            return .handled
        }
        .onChange(of: columnCustomization) { _, newValue in
            persistColumnCustomization(newValue)
        }
    }

    private func persistColumnCustomization(_ value: TableColumnCustomization<Reference>) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(value) {
            UserDefaults.standard.set(data, forKey: RubienPreferences.tableColumnCustomizationKey)
        }
    }
}

// MARK: - Inline Editing Cells

struct ReadingStatusCell: View {
    let reference: Reference
    let onUpdate: (Reference) -> Void

    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Text(reference.readingStatus.label)
                .font(.callout)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .chipBackground(statusColor(for: reference.readingStatus))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ReadingStatus.allCases, id: \.self) { status in
                    let isSelected = status == reference.readingStatus
                    Button {
                        var updated = reference
                        updated.readingStatus = status
                        onUpdate(updated)
                        showPicker = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            Text(status.label)
                                .font(.callout)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .chipBackground(statusColor(for: status))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
            .padding(.vertical, 4)
            .frame(width: 180)
        }
    }

    private func statusColor(for status: ReadingStatus) -> Color {
        switch status {
        case .unread: return .gray
        case .reading: return .blue
        case .skimmed: return .orange
        case .read: return .green
        }
    }
}

struct PriorityCell: View {
    let reference: Reference
    let onUpdate: (Reference) -> Void

    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            if reference.priority == .none {
                Text(reference.priority.label)
                    .font(.callout)
                    .foregroundStyle(.quaternary)
            } else {
                Text(reference.priority.label)
                    .font(.callout)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .chipBackground(priorityColor(for: reference.priority))
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Priority.allCases, id: \.self) { p in
                    let isSelected = p == reference.priority
                    Button {
                        var updated = reference
                        updated.priority = p
                        onUpdate(updated)
                        showPicker = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            if p == .none {
                                Text(p.label)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(p.label)
                                    .font(.callout)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .chipBackground(priorityColor(for: p))
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
            .padding(.vertical, 4)
            .frame(width: 180)
        }
    }

    private func priorityColor(for priority: Priority) -> Color {
        switch priority {
        case .none: return .gray
        case .low: return .blue
        case .medium: return .orange
        case .high: return .red
        }
    }
}

struct TagsCellView: View {
    let tags: [Tag]
    let allTags: [Tag]
    let referenceId: Int64
    let onUpdateTags: ([Int64]) -> Void
    let onCreateTag: (String) -> Void
    let onDeleteTag: (Int64) -> Void

    @State private var showPopover = false
    @State private var newTagName = ""

    var body: some View {
        Button {
            showPopover = true
        } label: {
            HStack(spacing: 3) {
                if tags.isEmpty {
                    Text("+ tag")
                        .font(.callout)
                        .foregroundStyle(.quaternary)
                } else {
                    ForEach(tags.prefix(3)) { tag in
                        Text(tag.name)
                            .font(.callout)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .chipBackground(Color(hex: tag.color))
                    }
                    if tags.count > 3 {
                        Text("+\(tags.count - 3)")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover) {
            TagPickerPopover(
                assignedTags: tags,
                allTags: allTags,
                onCommit: { tagIds in onUpdateTags(tagIds) },
                onCreateTag: onCreateTag,
                onDeleteTag: onDeleteTag,
                newTagName: $newTagName
            )
        }
    }
}

// TagPickerPopover is in TagPickerPopover.swift

