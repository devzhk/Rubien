import SwiftUI
import RubienCore

struct ReferenceTableView: View {
    let references: [Reference]
    let collections: [Collection]
    let tagMap: [Int64: [Tag]]
    let allTags: [Tag]
    let selectedId: Int64?
    let onSelect: (Int64) -> Void
    let onDelete: ([Reference]) -> Void
    let onMove: ([Reference], Int64?) -> Void
    let onRefreshMetadata: ([Reference]) -> Void
    let onUpdateReference: (Reference) -> Void
    let onUpdateTags: (Int64, [Int64]) -> Void
    let onCreateTag: (Int64, String) -> Void
    let onDeleteTag: (Int64) -> Void
    var isRefreshingMetadata = false
    var onDoubleClick: ((Int64) -> Void)? = nil

    @Binding var columnConfigs: [ColumnConfig]
    @Binding var sorts: [ViewSort]
    @Binding var filters: [ViewFilter]

    @State private var selection = Set<Reference.ID>()
    @State private var showDeleteConfirm = false
    @State private var showColumnConfig = false

    var body: some View {
        VStack(spacing: 0) {
            if references.isEmpty {
                emptyState
            } else {
                ViewFilterBar(filters: $filters)
                tableContent
                if !selection.isEmpty {
                    batchToolbar
                }
            }
        }
        .navigationTitle(String(localized: "References", bundle: .module))
        .navigationSubtitle(subtitleText)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showColumnConfig.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                }
                .help("Configure columns")
                .popover(isPresented: $showColumnConfig) {
                    ColumnConfigPopover(columns: $columnConfigs)
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
            references: sortedReferences,
            tagMap: tagMap,
            allTags: allTags,
            selection: $selection,
            tableSortOrder: $tableSortOrder,
            onUpdateReference: onUpdateReference,
            onUpdateTags: onUpdateTags,
            onCreateTag: onCreateTag,
            onDeleteTag: onDeleteTag
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
            if let first = newOrder.first {
                let field = sortKeyToColumn(first)
                let ascending = first.order == .forward
                sorts = [ViewSort(field: field, ascending: ascending)]
            }
        }
    }

    @State private var tableSortOrder: [KeyPathComparator<Reference>] = [
        .init(\.dateAdded, order: .reverse)
    ]

    // MARK: - Sort

    private var sortedReferences: [Reference] {
        if sorts.isEmpty { return references }
        let sort = sorts[0]
        return references.sorted { a, b in
            let result: Bool
            switch sort.field {
            case .title:
                result = a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .year:
                result = (a.year ?? 0) < (b.year ?? 0)
            case .dateAdded:
                result = a.dateAdded < b.dateAdded
            case .dateModified:
                result = a.dateModified < b.dateModified
            case .authors:
                result = (a.authors.first?.family ?? "") < (b.authors.first?.family ?? "")
            case .journal:
                result = (a.journal ?? "") < (b.journal ?? "")
            case .readingStatus:
                result = a.readingStatus.rawValue < b.readingStatus.rawValue
            case .priority:
                result = a.priority.rawValue < b.priority.rawValue
            default:
                result = a.dateAdded < b.dateAdded
            }
            return sort.ascending ? result : !result
        }
    }

    private func sortKeyToColumn(_ comparator: KeyPathComparator<Reference>) -> ColumnIdentifier {
        switch comparator.keyPath {
        case \Reference.title: return .title
        case \Reference.dateAdded: return .dateAdded
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
            moveToCollectionMenu(forBatch: true)
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
            moveToCollectionMenu(forRef: ref)
            Divider()
            Button(String(localized: "common.delete", bundle: .module), role: .destructive) {
                onDelete([ref])
            }
        }
    }

    // MARK: - Move-to-collection

    @ViewBuilder
    private func moveToCollectionMenu(forBatch: Bool) -> some View {
        Menu(String(localized: "Move to…", bundle: .module)) {
            Button(String(localized: "Remove from collection", bundle: .module)) {
                batchMove(toCollectionId: nil)
            }
            if !collections.isEmpty { Divider() }
            ForEach(collections) { col in
                Button(col.name) { batchMove(toCollectionId: col.id) }
            }
        }
    }

    @ViewBuilder
    private func moveToCollectionMenu(forRef ref: Reference) -> some View {
        Menu(String(localized: "Move to…", bundle: .module)) {
            Button(String(localized: "Remove from collection", bundle: .module)) {
                onMove([ref], nil)
            }
            if !collections.isEmpty { Divider() }
            ForEach(collections) { col in
                Button(col.name) { onMove([ref], col.id) }
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

    private func batchMove(toCollectionId: Int64?) {
        let toMove = references.filter { selection.contains($0.id) }
        selection.removeAll()
        onMove(toMove, toCollectionId)
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

    @SceneStorage("referenceTableColumnCustomization")
    private var columnCustomization: TableColumnCustomization<Reference>

    var body: some View {
        Table(references, selection: $selection, sortOrder: $tableSortOrder, columnCustomization: $columnCustomization) {
            TableColumn(ColumnIdentifier.title.header, value: \.title) { ref in
                TitleCellView(reference: ref)
            }
            .width(min: 150, ideal: 250)
            .customizationID(ColumnIdentifier.title.rawValue)
            .disabledCustomizationBehavior(.visibility)

            TableColumn(ColumnIdentifier.authors.header, value: \.authorsNormalized) { ref in
                AuthorsCellView(reference: ref)
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

            TableColumn(ColumnIdentifier.priority.header, value: \.priority.rawValue) { ref in
                PriorityCell(reference: ref, onUpdate: onUpdateReference)
            }
            .width(min: 60, ideal: 80)
            .customizationID(ColumnIdentifier.priority.rawValue)

            TableColumn(ColumnIdentifier.dateAdded.header, value: \.dateAdded) { ref in
                Text(ref.dateAdded, style: .date)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            .customizationID(ColumnIdentifier.dateAdded.rawValue)
        }
    }
}

// MARK: - Simple Cell Views

private struct TitleCellView: View {
    let reference: Reference
    var body: some View {
        Text(reference.title)
            .font(.system(.callout, weight: .medium))
            .lineLimit(2)
    }
}

private struct AuthorsCellView: View {
    let reference: Reference
    var body: some View {
        let display: String = {
            guard let first = reference.authors.first else { return "" }
            return reference.authors.count > 1 ? "\(first.family) et al." : first.family
        }()
        Text(display)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct YearCellView: View {
    let year: Int?
    var body: some View {
        Text(year.map(String.init) ?? "—")
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(year != nil ? .primary : .quaternary)
    }
}

private struct JournalCellView: View {
    let journal: String?
    var body: some View {
        Text(journal ?? "")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// MARK: - Inline Editing Cells

struct ReadingStatusCell: View {
    let reference: Reference
    let onUpdate: (Reference) -> Void

    var body: some View {
        Menu {
            ForEach(ReadingStatus.allCases, id: \.self) { status in
                Button {
                    var updated = reference
                    updated.readingStatus = status
                    onUpdate(updated)
                } label: {
                    Label(status.label, systemImage: status.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(reference.readingStatus.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var statusColor: Color {
        switch reference.readingStatus {
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

    var body: some View {
        Menu {
            ForEach(Priority.allCases, id: \.self) { p in
                Button {
                    var updated = reference
                    updated.priority = p
                    onUpdate(updated)
                } label: {
                    Label(p.label, systemImage: p.icon)
                }
            }
        } label: {
            HStack(spacing: 3) {
                if reference.priority != .none {
                    Image(systemName: reference.priority.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(priorityColor)
                }
                Text(reference.priority.label)
                    .font(.callout)
                    .foregroundStyle(reference.priority == .none ? .quaternary : .secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var priorityColor: Color {
        switch reference.priority {
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
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                } else {
                    ForEach(tags.prefix(3)) { tag in
                        Text(tag.name)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(hex: tag.color).opacity(0.15))
                            .foregroundStyle(Color(hex: tag.color))
                            .clipShape(Capsule())
                    }
                    if tags.count > 3 {
                        Text("+\(tags.count - 3)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .medium))
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

private struct TagPickerPopover: View {
    let assignedTags: [Tag]
    let allTags: [Tag]
    let onCommit: ([Int64]) -> Void
    let onCreateTag: (String) -> Void
    let onDeleteTag: (Int64) -> Void
    @Binding var newTagName: String
    @State private var search = ""
    @State private var localIds: Set<Int64> = []

    private var filteredTags: [Tag] {
        if search.isEmpty { return allTags }
        return allTags.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func isAssigned(_ tag: Tag) -> Bool {
        guard let id = tag.id else { return false }
        return localIds.contains(id)
    }

    private func handleCreate(_ name: String) {
        onCommit(Array(localIds))
        onCreateTag(name)
        search = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search or create tag…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        let trimmed = search.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty && !allTags.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
                            handleCreate(trimmed)
                        }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredTags) { tag in
                        let assigned = isAssigned(tag)
                        HStack(spacing: 0) {
                            Button {
                                if let id = tag.id {
                                    if localIds.contains(id) { localIds.remove(id) } else { localIds.insert(id) }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: assigned ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(assigned ? Color.accentColor : .secondary)
                                    Circle()
                                        .fill(Color(hex: tag.color))
                                        .frame(width: 8, height: 8)
                                    Text(tag.name)
                                        .font(.system(size: 12))
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                if let id = tag.id {
                                    localIds.remove(id)
                                    onDeleteTag(id)
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete tag")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                    }

                    if !search.isEmpty && !allTags.contains(where: { $0.name.lowercased() == search.trimmingCharacters(in: .whitespaces).lowercased() }) {
                        Button {
                            let trimmed = search.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                handleCreate(trimmed)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.accentColor)
                                Text("Create \"\(search.trimmingCharacters(in: .whitespaces))\"")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.accentColor)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 200)
        }
        .frame(width: 220)
        .onAppear {
            localIds = Set(assignedTags.compactMap(\.id))
        }
        .onDisappear {
            onCommit(Array(localIds))
        }
    }
}

