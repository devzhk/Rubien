#if os(macOS)
import SwiftUI
import RubienCore
import RubienSync

struct ViewChromeBar: View {
    let viewName: String?
    @Binding var filters: [ViewFilter]
    @Binding var sorts: [ViewSort]
    @Binding var groupBy: GroupConfig?
    @Binding var columnWraps: Set<String>
    @Binding var density: ReferenceTableDensity
    /// Resolves the table's current visibility for a column by `customizationID`.
    /// Passed as a closure rather than a `TableColumnCustomization` binding so
    /// chrome-bar code doesn't depend on the Table's implementation type.
    let isColumnVisible: (String) -> Bool
    let tags: [Tag]
    @Binding var propertyDefs: [PropertyDefinition]
    let db: AppDatabase
    let currentBuckets: [GroupBucket]
    let isDirty: Bool
    let onSave: () -> Void
    let onDiscard: () -> Void

    @EnvironmentObject private var syncCoordinator: SyncCoordinator

    @State private var showFilterEditor = false
    @State private var showColumns = false
    @State private var showSortEditor = false
    @State private var showGroupEditor = false
    @State private var showDisplayMenu = false

    var body: some View {
        VStack(spacing: 0) {
            row1
            Divider()
            row2
            if !filters.isEmpty {
                FilterChromeBar(filters: $filters, tags: tags, propertyDefs: propertyDefs)
            }
            Divider()
        }
        .liquidGlassSurface(in: Rectangle(), fallback: .bar)
    }

    private var row1: some View {
        HStack(spacing: 8) {
            SyncStatusIcon(status: syncCoordinator.status)
                .font(.system(size: 11))

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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                organizationControls
                Spacer(minLength: 12)
                Divider().frame(height: 16)
                appearanceControls
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { organizationControls }
                HStack(spacing: 6) { appearanceControls }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var organizationControls: some View {
        Button {
            showFilterEditor = true
        } label: {
            ChromeBarPill(iconName: "line.3.horizontal.decrease", label: filters.isEmpty ? "Filter" : "Filter \(filters.count)")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showFilterEditor) {
            FilterEditorPopover(
                tags: tags,
                propertyDefs: propertyDefs,
                onCommit: { filters.append($0); showFilterEditor = false },
                onCancel: { showFilterEditor = false }
            )
        }
        sortButton
        groupButton
    }

    @ViewBuilder
    private var appearanceControls: some View {
        displayButton
        Button {
            showColumns = true
        } label: {
            ChromeBarPill(iconName: "rectangle.split.3x1", label: "Manage Columns")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showColumns) {
            PropertyManagerPopover(
                propertyDefs: $propertyDefs,
                onToggleVisibility: { id, visible in
                    try? db.togglePropertyVisibility(id: id, visible: visible)
                },
                onDelete: { try? db.deletePropertyDefinition(id: $0) },
                onReorder: { try? db.reorderProperties($0) },
                onCreateProperty: { name, type in
                    var property = PropertyDefinition(
                        name: name, type: type,
                        sortOrder: (propertyDefs.map(\.sortOrder).max() ?? 0) + 1,
                        isDefault: false, isVisible: true
                    )
                    try? db.savePropertyDefinition(&property)
                },
                onRenameProperty: { id, name in
                    guard var property = propertyDefs.first(where: { $0.id == id }) else { return }
                    property.name = name
                    try? db.savePropertyDefinition(&property)
                }
            )
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
            .activatePopoverHover()
        }
    }

    private var sortButtonLabel: String {
        switch sorts.count {
        case 0: return "Sort"
        case 1: return "Sort: \(sorts[0].target.displayLabel(propertyDefs: propertyDefs)) \(sorts[0].ascending ? "↑" : "↓")"
        default: return "Sort: \(sorts.count) fields"
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
            .activatePopoverHover()
        }
    }

    private var groupButtonLabel: String {
        guard let groupBy else { return "Group" }
        return "Group: \(groupBy.target.displayLabel(propertyDefs: propertyDefs))"
    }

    private var displayButton: some View {
        Button {
            showDisplayMenu = true
        } label: {
            ChromeBarPill(iconName: "slider.horizontal.3", label: "Layout: \(density.label)")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDisplayMenu) {
            DisplayMenuPopover(
                columnWraps: $columnWraps,
                density: $density,
                isColumnVisible: isColumnVisible,
                propertyDefs: propertyDefs
            )
        }
    }


}

/// Lists columns that are (a) currently visible in the table and (b) whose
/// cell renderer honors the `wrap` flag, with a toggle each.
private struct DisplayMenuPopover: View {
    @Binding var columnWraps: Set<String>
    @Binding var density: ReferenceTableDensity
    let isColumnVisible: (String) -> Bool
    let propertyDefs: [PropertyDefinition]

    private var entries: [ReferenceTableWrappableColumn] {
        visibleReferenceTableWrappableColumns(
            propertyDefs: propertyDefs,
            isColumnVisible: isColumnVisible
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            densityPicker
            .padding(12)
            Text("Comfortable shows up to two title lines with authors and year. Compact shows one title line.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            Divider()
            Text("Wrapping")
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
                        Text(entry.label).font(.system(size: 12))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .padding(.bottom, 6)
            }
        }
        .frame(width: 290)
        .activatePopoverHover()
    }

    private var densityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("View density")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(ReferenceTableDensity.allCases, id: \.self) { option in
                    Button {
                        density = option
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .semibold))
                                .opacity(density == option ? 1 : 0)
                                .accessibilityHidden(true)
                            Text(option.label)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ToolbarHoverButtonStyle(hoverOpacity: 0.07, pressedOpacity: 0.12))
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AccentColorManager.shared.effectiveColor.opacity(density == option ? 0.12 : 0))
                    }
                    .accessibilityAddTraits(density == option ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("View density")
        }
    }
}

/// Used inside a `Button { }` body so the pill itself is the hit target.
/// Tracks hover locally to give the same subtle highlight as the main toolbar's
/// `ToolbarHoverButtonStyle`, so the chrome-bar controls read as interactive.
struct ChromeBarPill: View {
    let iconName: String
    let label: String

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .medium))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(isHovered ? .primary : .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(shape.fill(isHovered ? Color.primary.opacity(0.08) : Color.clear))
        .overlay(shape.stroke(Color.secondary.opacity(0.2)))
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
#endif
