import SwiftUI
import RubienCore

struct ViewChromeBar: View {
    let viewName: String?
    @Binding var filters: [ViewFilter]
    @Binding var sorts: [ViewSort]
    @Binding var groupBy: GroupConfig?
    @Binding var columnWraps: Set<String>
    /// Resolves the table's current visibility for a column by `customizationID`.
    /// Passed as a closure rather than a `TableColumnCustomization` binding so
    /// chrome-bar code doesn't depend on the Table's implementation type.
    let isColumnVisible: (String) -> Bool
    let tags: [Tag]
    let propertyDefs: [PropertyDefinition]
    let currentBuckets: [GroupBucket]
    let isDirty: Bool
    let onSave: () -> Void
    let onDiscard: () -> Void

    @State private var showSortEditor = false
    @State private var showGroupEditor = false
    @State private var showDisplayMenu = false

    var body: some View {
        VStack(spacing: 0) {
            row1
            Divider()
            row2
            Divider()
        }
        .background(.bar)
    }

    private var row1: some View {
        HStack(spacing: 8) {
            if let viewName {
                Text(viewName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }

            if isDirty {
                HStack(spacing: 4) {
                    Text("Unsaved")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Button("Save", action: onSave)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    Button("Discard", action: onDiscard)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var row2: some View {
        HStack(spacing: 8) {
            FilterChromeBar(
                filters: $filters,
                tags: tags,
                propertyDefs: propertyDefs
            )
            sortButton
            groupButton
            displayButton
                .padding(.trailing, 12)
        }
    }

    private var sortButton: some View {
        Button {
            showSortEditor = true
        } label: {
            ChromeBarPill(iconName: "arrow.up.arrow.down", label: sortButtonLabel)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSortEditor) {
            SortEditorPopover(
                sorts: $sorts,
                propertyDefs: propertyDefs
            )
        }
    }

    private var sortButtonLabel: String {
        switch sorts.count {
        case 0: return "Sort"
        case 1: return "Sorted by \(sorts[0].target.displayLabel(propertyDefs: propertyDefs))"
        default: return "Sorted by \(sorts.count) fields"
        }
    }

    private var groupButton: some View {
        Button {
            showGroupEditor = true
        } label: {
            ChromeBarPill(iconName: "rectangle.3.group", label: groupButtonLabel)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showGroupEditor) {
            GroupEditorPopover(
                groupBy: $groupBy,
                propertyDefs: propertyDefs,
                currentBuckets: currentBuckets
            )
        }
    }

    private var groupButtonLabel: String {
        guard let groupBy else { return "Group" }
        return "Grouped by \(groupBy.target.displayLabel(propertyDefs: propertyDefs))"
    }

    private var displayButton: some View {
        Button {
            showDisplayMenu = true
        } label: {
            ChromeBarPill(iconName: "text.alignleft", label: displayButtonLabel)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDisplayMenu) {
            DisplayMenuPopover(
                columnWraps: $columnWraps,
                isColumnVisible: isColumnVisible,
                propertyDefs: propertyDefs
            )
        }
    }

    private var displayButtonLabel: String {
        columnWraps.isEmpty ? "Wrap" : "Wrapping \(columnWraps.count)"
    }
}

/// Lists columns that are (a) currently visible in the table and (b) whose
/// cell renderer honors the `wrap` flag, with a toggle each.
private struct DisplayMenuPopover: View {
    @Binding var columnWraps: Set<String>
    let isColumnVisible: (String) -> Bool
    let propertyDefs: [PropertyDefinition]

    private struct Entry: Identifiable {
        let id: String  // customizationID
        let label: String
    }

    private var entries: [Entry] {
        var result: [Entry] = []

        for builtin in [ColumnIdentifier.title, .authors] where isColumnVisible(builtin.rawValue) {
            result.append(Entry(id: builtin.rawValue, label: builtin.header))
        }

        for prop in propertyDefs.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard prop.isVisible, isColumnVisible(prop.customizationID) else { continue }
            // Pill/date/checkbox cells ignore the `wrap` flag — skip them so
            // the menu doesn't offer no-op toggles. Built-in "tags" and
            // "readingStatus" are `.multiSelect`/`.singleSelect`, already
            // excluded by this guard.
            guard prop.type == .string || prop.type == .url || prop.type == .number else { continue }
            result.append(Entry(id: prop.customizationID, label: prop.name))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Wrap Text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if entries.isEmpty {
                Text("No wrappable columns visible")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                ForEach(entries) { entry in
                    Toggle(isOn: Binding(
                        get: { columnWraps.contains(entry.id) },
                        set: { isOn in
                            if isOn { columnWraps.insert(entry.id) }
                            else { columnWraps.remove(entry.id) }
                        }
                    )) {
                        Text(entry.label)
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .padding(.bottom, 6)
            }
        }
        .frame(minWidth: 220)
    }
}

/// Used inside a `Button { }` body so the pill itself is the hit target.
struct ChromeBarPill: View {
    let iconName: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .medium))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.secondary.opacity(0.2))
        )
    }
}
