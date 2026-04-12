import SwiftUI
import RubienCore

struct SidebarView: View {
    let databaseViews: [DatabaseView]
    let titleKeywords: [(word: String, count: Int)]
    @Binding var selection: SidebarItem
    let referenceCount: Int
    let onCreateView: (String) -> Void
    let onDeleteView: (Int64) -> Void
    let onRenameView: (Int64, String) -> Void

    @State private var showNewViewSheet = false
    @State private var newViewName = ""
    @State private var renamingViewId: Int64?
    @State private var renamingViewName = ""

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
                        Button { showNewViewSheet = true } label: {
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
                                Button("Rename…") {
                                    renamingViewId = view.id
                                    renamingViewName = view.name
                                }
                                Button("Duplicate") {
                                    onCreateView(view.name + " Copy")
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

        if !titleKeywords.isEmpty {
            Divider()
                .padding(.horizontal, 10)
            sidebarSection {
                Text("Smart collections", bundle: .module)
            } content: {
                FlowLayout(spacing: 6) {
                    ForEach(titleKeywords, id: \.word) { item in
                        let isSelected = selection == .titleKeyword(item.word)
                        Button {
                            if isSelected {
                                if let dv = defaultView { selection = .view(dv.id!) }
                            } else {
                                selection = .titleKeyword(item.word)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(item.word)
                                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                Text("\(item.count)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.primary.opacity(0.05))
                            )
                            .foregroundStyle(isSelected ? Color.accentColor : .primary.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationTitle("Rubien")
        .sheet(isPresented: $showNewViewSheet) {
            NewViewSheet(name: $newViewName) {
                let name = newViewName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                onCreateView(name)
                newViewName = ""
                showNewViewSheet = false
            }
        }
        .alert("Rename View", isPresented: Binding(
            get: { renamingViewId != nil },
            set: { if !$0 { renamingViewId = nil } }
        )) {
            TextField("Name", text: $renamingViewName)
            Button("Rename") {
                if let id = renamingViewId {
                    onRenameView(id, renamingViewName)
                }
                renamingViewId = nil
            }
            Button("Cancel", role: .cancel) { renamingViewId = nil }
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

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 300  // finite fallback — sidebar is never unbounded
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - New View Sheet

private struct NewViewSheet: View {
    @Binding var name: String
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New View")
                .font(.headline)
            TextField("View name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .onSubmit { onCreate() }
            HStack {
                Button("Cancel", role: .cancel) { name = "" }
                Button("Create") { onCreate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}
