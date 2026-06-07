#if os(macOS)
import SwiftUI
import RubienCore

struct SidebarView: View {
    let databaseViews: [DatabaseView]
    let titleKeywords: [(word: String, count: Int)]
    @Binding var selection: SidebarItem
    let referenceCount: Int
    let onCreateView: (_ name: String, _ icon: String) -> Void
    let onDeleteView: (Int64) -> Void
    let onUpdateView: (_ id: Int64, _ name: String, _ icon: String) -> Void

    @State private var editorMode: ViewEditorMode?

    private var defaultView: DatabaseView? {
        databaseViews.first(where: \.isDefault)
    }

    private var userViews: [DatabaseView] {
        databaseViews.filter { !$0.isDefault }
    }

    var body: some View {
        VStack(spacing: 0) {
        OverlayScrollView {
            VStack(spacing: 20) {
                // Default "All References" view
                if let defaultView {
                    sidebarSection {
                        SidebarRow(
                            icon: defaultView.icon,
                            label: defaultView.name,
                            isSelected: selection == .view(defaultView.id!),
                            trailing: { countBadge(referenceCount) }
                        ) {
                            selection = .view(defaultView.id!)
                        }
                    }
                }

                // User-created views
                sidebarSection {
                    HStack {
                        Text("Views")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { editorMode = .create } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Create a new view")
                    }
                } content: {
                    if userViews.isEmpty {
                        Text("No views yet")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 10)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(userViews) { view in
                            SidebarRow(
                                icon: view.icon,
                                label: view.name,
                                isSelected: selection == .view(view.id!)
                            ) {
                                selection = .view(view.id!)
                            }
                            .contextMenu {
                                Button("Edit View…") {
                                    editorMode = .edit(view)
                                }
                                Button("Duplicate") {
                                    onCreateView(view.name + " Copy", view.icon)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    if let id = view.id { onDeleteView(id) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }

        }
        .legacyBackground(Color(nsColor: .controlBackgroundColor))
        .navigationTitle("Rubien")
        .sheet(item: $editorMode) { mode in
            ViewEditorSheet(mode: mode) { name, icon in
                switch mode {
                case .create:
                    onCreateView(name, icon)
                case .edit(let view):
                    if let id = view.id { onUpdateView(id, name, icon) }
                }
                editorMode = nil
            }
        }
    }

    // MARK: - Building Blocks

    @ViewBuilder
    private func sidebarSection<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
        }
    }

    @ViewBuilder
    private func sidebarSection<Header: View, Content: View>(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            header()
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.none)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            content()
        }
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

// MARK: - Sidebar Row

private struct SidebarRow<Trailing: View>: View {
    let icon: String?
    let iconView: AnyView?
    let label: String
    let isSelected: Bool
    let trailing: (() -> Trailing)?
    let action: () -> Void

    @State private var isHovered = false

    init(
        icon: String,
        label: String,
        isSelected: Bool,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.iconView = nil
        self.label = label
        self.isSelected = isSelected
        self.trailing = trailing
        self.action = action
    }

    init(
        iconView: AnyView,
        label: String,
        isSelected: Bool,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        action: @escaping () -> Void
    ) {
        self.icon = nil
        self.iconView = iconView
        self.label = label
        self.isSelected = isSelected
        self.trailing = trailing
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let iconView {
                    iconView
                        .frame(width: 16, alignment: .center)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 16, alignment: .center)
                }

                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary.opacity(isSelected ? 1.0 : 0.82))
                    .lineLimit(1)

                Spacer(minLength: 0)

                trailing?()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected
                        ? Color.accentColor.opacity(0.10)
                        : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}

// Per-cell chips (tags, status, select options) hit `Color(hex:)` hundreds of
// times per body re-eval. The Scanner-based parse allocates each call, which
// is measurable in aggregate across the visible row set. The set of distinct
// hex strings in a library is small (tag/option palette), so memoizing yields
// straight cache hits after warmup. Cache is keyed on the *trimmed* hex string
// so `"#FF0000"` and `"FF0000"` share an entry. All call sites are SwiftUI
// view bodies (MainActor-isolated), so the cache and the initializer are both
// @MainActor — no synchronization needed.
@MainActor private var colorHexCache: [String: Color] = [:]

extension Color {
    @MainActor
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if let cached = colorHexCache[trimmed] {
            self = cached
            return
        }
        var int: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        let color = Color(red: r, green: g, blue: b)
        colorHexCache[trimmed] = color
        self = color
    }
}

// MARK: - View Editor

/// Distinguishes "create a new view" from "edit this existing view". A bare
/// optional `DatabaseView?` can't express this — `nil` would be ambiguous
/// between "creating" and "sheet closed" — so the mode is explicit.
private enum ViewEditorMode: Identifiable {
    case create
    case edit(DatabaseView)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let view): return "edit-\(view.id.map(String.init) ?? "new")"
        }
    }
}

private struct ViewEditorSheet: View {
    let mode: ViewEditorMode
    let onSave: (_ name: String, _ icon: String) -> Void

    @State private var name: String
    @State private var icon: String
    @Environment(\.dismiss) private var dismiss

    init(mode: ViewEditorMode, onSave: @escaping (String, String) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _icon = State(initialValue: ViewIconCatalog.defaultIcon)
        case .edit(let view):
            _name = State(initialValue: view.name)
            _icon = State(initialValue: view.icon)
        }
    }

    private var title: String {
        switch mode {
        case .create: return "New View"
        case .edit: return "Edit View"
        }
    }

    private var saveLabel: String {
        switch mode {
        case .create: return "Create"
        case .edit: return "Save"
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            TextField("View name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(save)
            ViewIconGrid(selection: $icon)
                .frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveLabel, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName, icon)
    }
}
#endif
