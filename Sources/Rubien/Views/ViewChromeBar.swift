import SwiftUI
import RubienCore

struct ViewChromeBar: View {
    let viewName: String?
    @Binding var filters: [ViewFilter]
    @Binding var sorts: [ViewSort]
    @Binding var groupBy: GroupConfig?
    let tags: [Tag]
    let propertyDefs: [PropertyDefinition]
    let currentBuckets: [GroupBucket]
    let isDirty: Bool
    let onSave: () -> Void
    let onDiscard: () -> Void

    @State private var showSortEditor = false
    @State private var showGroupEditor = false

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
                .padding(.trailing, 12)
        }
    }

    private var sortButton: some View {
        Button {
            showSortEditor = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .medium))
                Text(sortButtonLabel)
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
            HStack(spacing: 4) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 9, weight: .medium))
                Text(groupButtonLabel)
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
}
