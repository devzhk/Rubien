#if os(macOS)
import AppKit
import os
import SwiftUI
import RubienCore

private let tableLog = Logger(subsystem: "Rubien", category: "reference-table")

struct ReferenceTableView: View {
    /// `defaultFieldKey` values for properties that already have their own
    /// hardcoded `TableColumn` in `ReferenceTableContent.body`. The
    /// `customProperties` filter excludes these so they don't render twice
    /// when the user toggles them visible in the Property Manager.
    private static let hardcodedDefaultFieldKeys: Set<String> = [
        "tags", "readingStatus", "lastReadAt", "readCount",
    ]

    let references: [Reference]
    let tagMap: [Int64: [Tag]]
    let allTags: [Tag]
    let selectedId: Int64?
    let onSelect: (Int64) -> Void
    let onDelete: ([Reference]) -> Void
    let onRefreshMetadata: ([Reference]) -> Void
    let onUpdateReference: (Reference) -> Void
    let onUpdateTags: (Int64, [Int64]) -> Void
    let onCreateTag: (String) -> Int64?
    let onDeleteTag: (Int64) -> Void
    let deleteTagUnlessInUse: (Int64) -> Int?
    let onCreateOption: (Int64, String) -> Void
    let onDeleteOption: (Int64, String) -> Void
    let deleteUnlessInUse: (Int64, String) -> Int?
    var isRefreshingMetadata = false
    var onDoubleClick: ((Int64) -> Void)? = nil

    @Binding var columnConfigs: [ColumnConfig]
    @Binding var sorts: [ViewSort]
    @Binding var filters: [ViewFilter]
    @Binding var propertyDefs: [PropertyDefinition]
    let db: AppDatabase
    let customPropertyValueMap: [Int64: [Int64: String]]
    @Binding var groupBy: GroupConfig?
    @Binding var viewColumnWraps: Set<String>
    var viewName: String? = nil
    var isDirty: Bool = false
    var onSaveView: () -> Void = {}
    var onDiscardView: () -> Void = {}
    var scrollRequest: Int = 0

    @State private var selection = Set<Reference.ID>()
    @State private var showDeleteConfirm = false
    // Owned here (not in `ReferenceTableContent`) so the Display menu in
    // `ViewChromeBar` can see the same live state — a second UserDefaults
    // read would be stale right after the user hides a column.
    @State private var columnCustomization: TableColumnCustomization<Reference> =
        RubienPreferences.loadTableColumnCustomization()

    var body: some View {
        // Hoist pipeline computations once per body render. `processedReferences`
        // and `groupedBuckets` are computed vars, so reading them multiple times
        // re-runs FilterEngine/SortEngine/GroupEngine across the whole set.
        let processed = processedReferences
        let buckets: [GroupBucket]? = {
            guard let config = groupBy else { return nil }
            return GroupEngine.apply(processed, config: config, context: pipelineContext)
        }()
        return VStack(spacing: 0) {
            ViewChromeBar(
                viewName: viewName,
                filters: $filters,
                sorts: $sorts,
                groupBy: $groupBy,
                columnWraps: $viewColumnWraps,
                isColumnVisible: { id in columnCustomization[visibility: id] != .hidden },
                tags: allTags,
                propertyDefs: propertyDefs,
                currentBuckets: buckets ?? [],
                isDirty: isDirty,
                onSave: onSaveView,
                onDiscard: onDiscardView
            )
            subtitleRow
            if references.isEmpty {
                emptyState
            } else if processed.isEmpty {
                filteredEmptyState
            } else {
                tableContentView(processed: processed, buckets: buckets)
                if !selection.isEmpty {
                    batchToolbar
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
        .onAppear {
            syncSelectionFromSelectedId()
        }
        .onChange(of: selectedId) { _, _ in
            syncSelectionFromSelectedId()
        }
        .onChange(of: scrollRequest) { _, _ in
            syncSelectionFromSelectedId()
        }
    }

    // MARK: - Table

    private var visibleColumns: [ColumnConfig] {
        columnConfigs
            .filter(\.isVisible)
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    private func tableContentView(processed: [Reference], buckets: [GroupBucket]?) -> some View {
        ReferenceTableContent(
            references: processed,
            buckets: buckets,
            collapsedGroups: Binding(
                get: { groupBy?.collapsed ?? [] },
                set: { newValue in groupBy?.collapsed = newValue }
            ),
            tagMap: tagMap,
            allTags: allTags,
            selection: $selection,
            tableSortOrder: $tableSortOrder,
            onUpdateReference: onUpdateReference,
            onUpdateTags: onUpdateTags,
            onCreateTag: onCreateTag,
            onDeleteTag: onDeleteTag,
            deleteTagUnlessInUse: deleteTagUnlessInUse,
            onCreateOption: onCreateOption,
            onDeleteOption: onDeleteOption,
            deleteUnlessInUse: deleteUnlessInUse,
            customProperties: propertyDefs.filter { prop in
                guard prop.isVisible else { return false }
                if !prop.isDefault { return true }
                // Skip defaults that have a dedicated TableColumn below.
                guard let key = prop.defaultFieldKey else { return false }
                return !Self.hardcodedDefaultFieldKeys.contains(key)
            },
            statusDef: propertyDefs.first(forFieldKey: PropertyDefinition.readingStatusFieldKey),
            customPropertyValueMap: customPropertyValueMap,
            db: db,
            wrapForColumn: { id in viewColumnWraps.contains(id) },
            columnCustomization: $columnCustomization
        )
        .background(
            ReferenceTableSelectionScroller(
                selectedId: selectedId,
                scrollRequest: scrollRequest,
                rowIDs: visibleTableRowIDs(processed: processed, buckets: buckets)
            )
        )
        .background(ReferenceTableRowHover())
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

    private func syncSelectionFromSelectedId() {
        guard let selectedId else {
            if !selection.isEmpty {
                selection.removeAll()
            }
            return
        }

        expandCollapsedGroup(containing: selectedId)
        let target: Set<Reference.ID> = [Optional(selectedId)]
        if selection != target {
            selection = target
        }
    }

    private func expandCollapsedGroup(containing selectedId: Int64) {
        guard groupBy?.collapsed.isEmpty == false,
              let config = groupBy else { return }
        let buckets = GroupEngine.apply(processedReferences, config: config, context: pipelineContext)
        guard let bucket = buckets.first(where: { bucket in
            bucket.references.contains { $0.id == selectedId }
        }) else { return }
        groupBy?.collapsed.remove(bucket.key)
    }

    private func visibleTableRowIDs(processed: [Reference], buckets: [GroupBucket]?) -> [Int64?] {
        guard let buckets else {
            return processed.map(\.id)
        }
        return buckets.flatMap { bucket -> [Int64?] in
            var ids: [Int64?] = [nil]
            if groupBy?.collapsed.contains(bucket.key) != true {
                ids.append(contentsOf: bucket.references.map(\.id))
            }
            return ids
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
        case .readingStatus:   return KeyPathComparator(\.readingStatus, order: order)
        default:               return nil
        }
    }

    @State private var tableSortOrder: [KeyPathComparator<Reference>] = [
        .init(\.dateAdded, order: .reverse)
    ]

    // MARK: - Pipeline

    private var pipelineContext: PipelineContext {
        let pdfAttachedIds = (try? db.pdfAttachedReferenceIDs()) ?? []
        return PipelineContext(
            tagMap: tagMap,
            propertyValueMap: customPropertyValueMap,
            propertyDefs: propertyDefs,
            pdfAttachedRefIds: pdfAttachedIds,
            now: Date()
        )
    }

    private var processedReferences: [Reference] {
        let context = pipelineContext
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
        case \Reference.readingStatus: return .readingStatus
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
        .liquidGlassSurface(in: Rectangle(), fallback: .bar)
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

    private var filteredEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No references match", bundle: .module)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Adjust or clear the filters above to see more.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var subtitleRow: some View {
        HStack(spacing: 0) {
            Text(subtitleText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

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
    let buckets: [GroupBucket]?
    @Binding var collapsedGroups: Set<String>
    let tagMap: [Int64: [Tag]]
    let allTags: [Tag]
    @Binding var selection: Set<Reference.ID>
    @Binding var tableSortOrder: [KeyPathComparator<Reference>]
    let onUpdateReference: (Reference) -> Void
    let onUpdateTags: (Int64, [Int64]) -> Void
    let onCreateTag: (String) -> Int64?
    let onDeleteTag: (Int64) -> Void
    let deleteTagUnlessInUse: (Int64) -> Int?
    let onCreateOption: (Int64, String) -> Void
    let onDeleteOption: (Int64, String) -> Void
    let deleteUnlessInUse: (Int64, String) -> Int?
    let customProperties: [PropertyDefinition]
    /// Status PropertyDefinition. Passed separately because `customProperties`
    /// filters Status out (the table renders a hardcoded Status column).
    let statusDef: PropertyDefinition?
    let customPropertyValueMap: [Int64: [Int64: String]]
    let db: AppDatabase
    let wrapForColumn: (String) -> Bool
    @Binding var columnCustomization: TableColumnCustomization<Reference>

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
        // Surface failures instead of swallowing with `try?`: a dropped write
        // here is invisible data loss. A transient SQLITE_BUSY silently lost
        // custom-property edits on freshly-added references until the DB busy
        // timeout was added (see AppDatabase's Configuration); logging keeps any
        // future regression visible rather than mysterious.
        do {
            try db.setPropertyValue(referenceId: refId, propertyId: propId, value: value)
        } catch {
            tableLog.error("setPropertyValue failed ref=\(refId, privacy: .public) prop=\(propId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        editingCell = nil
    }

    // Tab skips columns hidden via `TableColumnCustomization` — landing on an
    // invisible editor would strand `editingCell` with no way to commit or
    // cancel, since the off-screen cell's focus chain is detached.
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

    // Split out: inlining these tips the Table DSL past the type-checker's
    // threshold.

    @ViewBuilder
    private func titleCell(for ref: Reference) -> some View {
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
            },
            wrap: wrapForColumn(ColumnIdentifier.title.rawValue)
        )
        .equatable()
    }

    @ViewBuilder
    private func authorsCell(for ref: Reference) -> some View {
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
            },
            wrap: wrapForColumn(ColumnIdentifier.authors.rawValue)
        )
        .equatable()
    }

    @ViewBuilder
    private func propertyCell(for ref: Reference, prop: PropertyDefinition) -> some View {
        if prop.isDefault, let key = prop.defaultFieldKey {
            // Resolve `isEditing` once at construction so the cell can compare
            // it via `==` — see EditableDefaultPropertyCell's Equatable conformance.
            EditableDefaultPropertyCell(
                reference: ref,
                fieldKey: key,
                property: prop,
                isEditing: isEditing(ref.id, key),
                onBeginEdit: { beginEdit(ref.id, key) },
                onCancel: cancel,
                commitRef: commitRef,
                onTab: { back in
                    if let id = ref.id {
                        advanceEdit(from: id, fieldKey: key, backwards: back)
                    }
                },
                wrap: wrapForColumn(prop.customizationID)
            )
            .equatable()
        } else if let refId = ref.id {
            let customKey = "custom_\(prop.id ?? 0)"
            EditableCustomPropertyCell(
                referenceId: refId,
                property: prop,
                rawValue: customPropertyValueMap[refId]?[prop.id ?? 0],
                isEditing: isEditing(refId, prop.customizationID),
                onBeginEdit: { beginEdit(refId, prop.customizationID) },
                onCancel: cancel,
                commitCustom: commitCustom,
                onCreateOption: onCreateOption,
                onDeleteOption: onDeleteOption,
                deleteUnlessInUse: deleteUnlessInUse,
                onTab: { back in
                    advanceEdit(from: refId, fieldKey: customKey, backwards: back)
                },
                wrap: wrapForColumn(prop.customizationID)
            )
            .equatable()
        } else {
            Text("—")
                .font(.callout)
                .foregroundStyle(.quaternary)
        }
    }

    var body: some View {
        Table(
            of: Reference.self,
            selection: $selection,
            sortOrder: $tableSortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn(ColumnIdentifier.title.header, value: \.title) { ref in
                titleCell(for: ref)
            }
            .width(min: 150, ideal: 250)
            .customizationID(ColumnIdentifier.title.rawValue)
            .disabledCustomizationBehavior(.visibility)

            TableColumn(ColumnIdentifier.authors.header, value: \.authorsNormalized) { ref in
                authorsCell(for: ref)
            }
            .width(min: 80, ideal: 140)
            .customizationID(ColumnIdentifier.authors.rawValue)

            TableColumn(ColumnIdentifier.tags.header, value: \.title) { ref in
                TagsCellView(
                    tags: tagMap[ref.id ?? -1] ?? [],
                    allTags: allTags,
                    referenceId: ref.id ?? -1,
                    onUpdateTags: { tagIds in onUpdateTags(ref.id ?? -1, tagIds) },
                    onCreateTag: onCreateTag,
                    onDeleteTag: onDeleteTag,
                    deleteTagUnlessInUse: deleteTagUnlessInUse
                )
                .equatable()
            }
            .width(min: 60, ideal: 120)
            .customizationID(ColumnIdentifier.tags.rawValue)

            TableColumn(ColumnIdentifier.readingStatus.header, value: \.readingStatus) { ref in
                ReadingStatusCell(
                    reference: ref,
                    statusDef: statusDef,
                    onUpdate: onUpdateReference,
                    onCreateStatusOption: { newOption in
                        // Append to the seeded Status PropertyDefinition and
                        // persist. The picker also commits the new option as
                        // the selected value via `onCommit`.
                        guard var def = statusDef else { return }
                        _ = def.addOptionIfMissing(newOption)
                        try? db.savePropertyDefinition(&def)
                    },
                    onDeleteStatusOption: { option in
                        guard let def = statusDef, let propId = def.id else { return }
                        // Try a clean delete first; if the option is in use,
                        // auto-reassign affected rows to the first remaining
                        // option (deterministic, doesn't prompt). Power users
                        // can reach for `rubien-cli properties --delete-option`
                        // with `--replace-with` for finer control.
                        do {
                            try db.deletePropertyOption(
                                propertyId: propId,
                                value: option,
                                replaceWith: nil
                            )
                        } catch PropertyOptionError.optionInUse {
                            let fallback = def.options
                                .first(where: { $0.value != option })?
                                .value
                            guard let replacement = fallback else { return }
                            try? db.deletePropertyOption(
                                propertyId: propId,
                                value: option,
                                replaceWith: replacement
                            )
                        } catch {
                            // Other errors (.optionNotFound,
                            // .unsupportedPropertyType) shouldn't happen for
                            // Status — silently swallow rather than crash.
                        }
                    }
                )
                .equatable()
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

            TableColumn(ColumnIdentifier.lastReadAt.header) { ref in
                if let date = ref.lastReadAt {
                    Text(date, style: .date)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.callout)
                        .foregroundStyle(.quaternary)
                }
            }
            .width(min: 70, ideal: 90)
            .customizationID(ColumnIdentifier.lastReadAt.rawValue)

            TableColumn(ColumnIdentifier.readCount.header, value: \.readCount) { ref in
                Text(ref.readCount, format: .number)
                    .font(.callout)
                    .foregroundStyle(ref.readCount == 0 ? .quaternary : .secondary)
            }
            .width(min: 50, ideal: 70)
            .customizationID(ColumnIdentifier.readCount.rawValue)

            TableColumnForEach(customProperties) { prop in
                TableColumn(prop.name) { ref in
                    propertyCell(for: ref, prop: prop)
                }
                .width(min: 60, ideal: 100)
                .customizationID(prop.customizationID)
            }
        } rows: {
            if let buckets {
                ForEach(buckets, id: \.key) { bucket in
                    Section {
                        if !collapsedGroups.contains(bucket.key) {
                            ForEach(bucket.references) { ref in
                                TableRow(ref)
                            }
                        }
                    } header: {
                        groupHeader(for: bucket)
                    }
                }
            } else {
                ForEach(references) { ref in
                    TableRow(ref)
                }
            }
        }
        .onChange(of: columnCustomization) { _, newValue in
            persistColumnCustomization(newValue)
        }
        .onChange(of: collapsedGroups) { _, _ in
            pruneHiddenSelection()
        }
    }

    /// When a group collapses, drop any selected rows that now live in a
    /// collapsed section — otherwise batch actions could silently act on
    /// rows the user can no longer see.
    private func pruneHiddenSelection() {
        guard let buckets, !selection.isEmpty else { return }
        let visibleIds: Set<Int64> = Set(
            buckets
                .filter { !collapsedGroups.contains($0.key) }
                .flatMap { $0.references.compactMap(\.id) }
        )
        let pruned = selection.filter { selectedId in
            guard let id = selectedId else { return false }
            return visibleIds.contains(id)
        }
        if pruned != selection {
            selection = pruned
        }
    }

    @ViewBuilder
    private func groupHeader(for bucket: GroupBucket) -> some View {
        let isCollapsed = collapsedGroups.contains(bucket.key)
        HStack(spacing: 6) {
            Button {
                if isCollapsed {
                    collapsedGroups.remove(bucket.key)
                } else {
                    collapsedGroups.insert(bucket.key)
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand \(bucket.label)" : "Collapse \(bucket.label)")
            Text(bucket.label)
                .font(.system(size: 12, weight: .semibold))
            Text("(\(bucket.references.count))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func persistColumnCustomization(_ value: TableColumnCustomization<Reference>) {
        RubienPreferences.saveTableColumnCustomization(value)
    }
}

private struct ReferenceTableSelectionScroller: NSViewRepresentable {
    let selectedId: Int64?
    let scrollRequest: Int
    let rowIDs: [Int64?]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.selectedId = selectedId
        context.coordinator.scrollRequest = scrollRequest
        context.coordinator.rowIDs = rowIDs
        context.coordinator.scheduleScroll(from: nsView)
    }

    final class Coordinator {
        private struct ScrollKey: Equatable {
            var selectedId: Int64
            var scrollRequest: Int
            var rowIDs: [Int64?]
        }

        var selectedId: Int64?
        var scrollRequest = 0
        var rowIDs: [Int64?] = []
        private var lastScrollKey: ScrollKey?

        func scheduleScroll(from view: NSView) {
            guard let selectedId else {
                lastScrollKey = nil
                return
            }

            let key = ScrollKey(selectedId: selectedId, scrollRequest: scrollRequest, rowIDs: rowIDs)
            guard key != lastScrollKey else { return }

            DispatchQueue.main.async { [weak view, weak self] in
                guard let view else { return }
                self?.scrollIfNeeded(from: view)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak view, weak self] in
                guard let view else { return }
                self?.scrollIfNeeded(from: view, force: true)
            }
        }

        private func scrollIfNeeded(from view: NSView, attempt: Int = 0, force: Bool = false) {
            guard let selectedId else {
                lastScrollKey = nil
                return
            }

            let key = ScrollKey(selectedId: selectedId, scrollRequest: scrollRequest, rowIDs: rowIDs)
            guard force || key != lastScrollKey else { return }
            guard let tableView = view.nearestTableView() else {
                retry(from: view, attempt: attempt, force: force)
                return
            }

            guard let selectedRow = rowIDs.firstIndex(of: selectedId),
                  selectedRow < tableView.numberOfRows else {
                retry(from: view, attempt: attempt, force: force)
                return
            }

            if !tableView.selectedRowIndexes.contains(selectedRow) {
                tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            }
            reveal(row: selectedRow, in: tableView)
            lastScrollKey = key
        }

        private func reveal(row: Int, in tableView: NSTableView) {
            tableView.layoutSubtreeIfNeeded()
            tableView.scrollRowToVisible(row)

            guard let scrollView = tableView.enclosingScrollView else { return }
            let rowRect = tableView.rect(ofRow: row)
            guard !rowRect.isEmpty else { return }

            let clipView = scrollView.contentView
            var targetBounds = clipView.bounds
            targetBounds.origin.y = rowRect.midY - (targetBounds.height / 2)

            let constrained = clipView.constrainBoundsRect(targetBounds)
            clipView.scroll(to: constrained.origin)
            scrollView.reflectScrolledClipView(clipView)
        }

        private func retry(from view: NSView, attempt: Int, force: Bool) {
            guard attempt < 6 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view, weak self] in
                guard let view else { return }
                self?.scrollIfNeeded(from: view, attempt: attempt + 1, force: force)
            }
        }

    }
}

// MARK: - Row hover highlight

/// Draws a subtle hover highlight on the row under the pointer. SwiftUI's
/// `Table` exposes no row-hover hook, so this bridges to the backing
/// `NSTableView` (the same view the selection scroller reaches): a local
/// mouse-moved monitor maps the pointer to a row and a lightweight,
/// click-through overlay is positioned over it. Selected rows keep their own
/// selection highlight, so no hover is drawn on them.
private struct ReferenceTableRowHover: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView(frame: .zero)
        context.coordinator.start(from: anchor)
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The NSTableView may not be in the hierarchy yet at make time.
        context.coordinator.start(from: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private weak var anchor: NSView?
        private weak var tableView: NSTableView?
        private var monitor: Any?
        private var hoverView: HoverHighlightView?
        private var hoveredRow = -1

        func start(from view: NSView) {
            anchor = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            hoverView?.removeFromSuperview()
            hoverView = nil
            tableView = nil
        }

        deinit { stop() }

        private func resolveTableView() -> NSTableView? {
            if let tableView, tableView.window != nil { return tableView }
            guard let found = anchor?.nearestTableView() else {
                return nil
            }
            // Required so the window posts the .mouseMoved events the monitor needs.
            found.window?.acceptsMouseMovedEvents = true
            tableView = found
            return found
        }

        private func handle(_ event: NSEvent) {
            guard let tableView = resolveTableView(),
                  let window = tableView.window,
                  event.window === window else {
                clearHover()
                return
            }
            let point = tableView.convert(event.locationInWindow, from: nil)
            guard tableView.bounds.contains(point) else { clearHover(); return }
            updateHover(to: tableView.row(at: point), in: tableView)
        }

        private func updateHover(to row: Int, in tableView: NSTableView) {
            let valid = row >= 0
                && row < tableView.numberOfRows
                && !tableView.selectedRowIndexes.contains(row)
            guard valid else { clearHover(); return }
            // Skip if we're already highlighting this row.
            if row == hoveredRow, hoverView?.isHidden == false { return }
            hoveredRow = row

            let hv = hoverView ?? makeHoverView()
            // Keep it above any row views recycled in since the last move, but
            // only re-front when it isn't already on top.
            if tableView.subviews.last !== hv {
                tableView.addSubview(hv, positioned: .above, relativeTo: nil)
            }
            hv.frame = tableView.rect(ofRow: row).insetBy(dx: 4, dy: 0)
            hv.isHidden = false
        }

        private func clearHover() {
            hoveredRow = -1
            hoverView?.isHidden = true
        }

        private func makeHoverView() -> HoverHighlightView {
            let hv = HoverHighlightView()
            hv.wantsLayer = true
            hoverView = hv
            return hv
        }
    }
}

/// Subtle, click-through row hover overlay that tracks the system appearance.
private final class HoverHighlightView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T {
                return match
            }
            if let match = subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }

    /// Finds the `NSTableView` nearest this view: walk up the ancestry checking
    /// each ancestor's subtree, then fall back to the window's content view.
    /// Walking up (rather than searching the whole window) matters because the
    /// `NavigationSplitView` sidebar is itself a `List`/`NSTableView` — a plain
    /// window-wide search could return it instead of the reference table.
    func nearestTableView() -> NSTableView? {
        var candidate: NSView? = self
        while let current = candidate {
            if let tableView = current as? NSTableView {
                return tableView
            }
            if let tableView = current.firstDescendant(of: NSTableView.self) {
                return tableView
            }
            candidate = current.superview
        }
        return window?.contentView?.firstDescendant(of: NSTableView.self)
    }
}

// MARK: - Inline Editing Cells

struct ReadingStatusCell: View, Equatable {
    let reference: Reference
    /// Seeded in v1; nil only if the seed was bypassed (defensive fallback below).
    let statusDef: PropertyDefinition?
    let onUpdate: (Reference) -> Void
    /// Wired by the parent table view to `db.savePropertyDefinition` after
    /// `addOptionIfMissing`. Lets users add a new Status option inline by
    /// typing in the picker's search field.
    let onCreateStatusOption: (String) -> Void
    /// Wired by the parent to `db.deletePropertyOption` (with auto-reassign
    /// on `.optionInUse`). Lets users delete a Status option via the trash
    /// affordance on each option row.
    let onDeleteStatusOption: (String) -> Void

    @State private var showPicker = false

    // Body reads only `reference.id`, `reference.readingStatus`, and the
    // status options (via `statusOptions` computed from `statusDef`). Whole-
    // Reference equality would invalidate this cell on every edit because
    // `Reference.dateModified` is stamped on every save.
    static func == (lhs: ReadingStatusCell, rhs: ReadingStatusCell) -> Bool {
        guard lhs.reference.id == rhs.reference.id,
              lhs.reference.readingStatus == rhs.reference.readingStatus
        else { return false }
        switch (lhs.statusDef, rhs.statusDef) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return l.id == r.id && l.options == r.options
        default:
            return false
        }
    }

    /// Live Status options driven by the seeded PropertyDefinition (post-Phase-2
    /// users can add/rename/delete options). Falls back to the 4 built-ins.
    private var statusOptions: [SelectOption] {
        if let def = statusDef {
            return def.options
        }
        // Defensive fallback only — `statusDef` is seeded by v1 and should
        // always be present in practice. Mirrors `AppDatabase.swift` seed.
        return [
            SelectOption(value: ReadingStatus.unread,  color: "#8E8E93"),
            SelectOption(value: ReadingStatus.skimmed, color: "#FF9500"),
            SelectOption(value: ReadingStatus.read,    color: "#34C759"),
        ]
    }

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Text(reference.readingStatus)
                .font(.callout)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .chipBackground(color(forStatus: reference.readingStatus))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker) {
            // Use the shared SelectOptionPicker so the Status cell gets
            // search-or-create + the per-row trash affordance for free
            // (matches the detail-panel picker behavior).
            SelectOptionPicker(
                selectedValues: reference.readingStatus.isEmpty ? [] : [reference.readingStatus],
                options: statusOptions,
                isSingleSelect: true,
                onCommit: { values in
                    guard let selected = values.first else { return }
                    var updated = reference
                    updated.readingStatus = selected
                    onUpdate(updated)
                },
                onCreateOption: { newOption in
                    onCreateStatusOption(newOption)
                    // Picker also commits the new option as the selected
                    // value via onCommit above; we just need to make sure
                    // the option exists in the live def first.
                },
                onDeleteOption: { option in
                    onDeleteStatusOption(option)
                }
            )
        }
    }

    /// Resolve a status value to a chip color via the SelectOption.color field.
    /// Unknown values (e.g. a custom status that was deleted) get a neutral gray.
    private func color(forStatus value: String) -> Color {
        if let opt = statusOptions.first(where: { $0.value == value }) {
            return Color(hex: opt.color)
        }
        return .gray
    }
}

struct TagsCellView: View, Equatable {
    let tags: [Tag]
    let allTags: [Tag]
    let referenceId: Int64
    let onUpdateTags: ([Int64]) -> Void
    let onCreateTag: (String) -> Int64?
    let onDeleteTag: (Int64) -> Void
    let deleteTagUnlessInUse: (Int64) -> Int?

    @State private var showPopover = false

    // Use the file-private helper (declared in ReferenceTableCells.swift) so
    // `Tag.dateModified` churn doesn't invalidate every visible tag cell on a
    // tag-timestamp-only save.
    static func == (lhs: TagsCellView, rhs: TagsCellView) -> Bool {
        lhs.referenceId == rhs.referenceId
            && tagListVisuallyEqual(lhs.tags, rhs.tags)
            && tagListVisuallyEqual(lhs.allTags, rhs.allTags)
    }

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
                deleteTagUnlessInUse: deleteTagUnlessInUse
            )
        }
    }
}

// TagPickerPopover is in TagPickerPopover.swift

#endif
