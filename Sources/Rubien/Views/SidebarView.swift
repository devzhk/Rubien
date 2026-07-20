#if os(macOS)
import SwiftUI
import RubienCore

struct SidebarView: View {
    let databaseViews: [DatabaseView]
    let titleKeywords: [(word: String, count: Int)]
    @Binding var selection: SidebarItem
    let isHomeSelected: Bool
    let homeIsResponding: Bool
    let homeNeedsApproval: Bool
    let homeUnreadOutcome: AssistantTurnOutcome.Phase?
    let onSelectHome: () -> Void
    let referenceCount: Int
    let onCreateView: (_ name: String, _ icon: String) -> Void
    let onDeleteView: (Int64) -> Void
    let onUpdateView: (_ id: Int64, _ name: String, _ icon: String) -> Void
    let onReorderViews: (_ orderedIds: [Int64]) -> Void

    @State private var editorMode: ViewEditorMode?
    /// The view being dragged. Non-nil only while a reorder drag is in flight.
    @State private var draggedViewId: Int64?
    /// Gap index in `userViews` (0...count) where the dragged row will land. Drives the
    /// insertion bar; `nil` shows no bar. The rows themselves never move during the drag.
    @State private var dropInsertionIndex: Int?
    /// Monotonic token identifying the current drag session; bumped by every `.onDrag`.
    /// The cancel watchdog is keyed on it (NOT on `draggedViewId` — re-dragging the same
    /// row would reuse the id and fail to restart the task) and compares it before
    /// clearing, so a stale watchdog can never cancel a newer drag.
    @State private var dragSession = 0

    private var defaultView: DatabaseView? {
        databaseViews.first(where: \.isDefault)
    }

    private var userViews: [DatabaseView] {
        databaseViews.filter { !$0.isDefault }
    }

    /// Move the insertion bar as the drag hovers the row at `rowIndex`. The bar lands on
    /// the side of the hovered row facing the dragged row's origin; hovering the dragged
    /// row itself shows no bar (a drop there wouldn't move anything).
    private func updateDropTarget(rowIndex i: Int) {
        guard let dragged = draggedViewId,
              let source = userViews.firstIndex(where: { $0.id == dragged }) else { return }
        dropInsertionIndex = i == source ? nil : (i < source ? i : i + 1)
    }

    /// Commit the drop: move the dragged row to the insertion gap, computed against the
    /// LIVE `userViews` so a concurrent sync change can't desync it, then persist. Skips
    /// the write when nothing actually moved.
    private func commitDrop() {
        defer { draggedViewId = nil; dropInsertionIndex = nil }
        guard let dragged = draggedViewId, let gap = dropInsertionIndex else { return }
        let current = userViews.compactMap(\.id)
        guard let from = current.firstIndex(of: dragged) else { return }
        // `gap` was computed during hover against the then-current list; a concurrent
        // sync may have shrunk the list since, so clamp to the live bounds — otherwise
        // `move(toOffset:)` traps when the stale gap exceeds the current end index.
        let gapClamped = min(max(gap, 0), current.count)
        var reordered = current
        reordered.move(fromOffsets: IndexSet(integer: from), toOffset: gapClamped)
        guard reordered != current else { return }
        onReorderViews(reordered)
    }

    /// Thin accent line marking where a dropped row will land.
    private var insertionBar: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 8)
    }

    var body: some View {
        VStack(spacing: 0) {
        OverlayScrollView {
            VStack(spacing: 20) {
                sidebarSection {
                    SidebarRow(
                        icon: "sparkles",
                        label: "Home",
                        isSelected: isHomeSelected,
                        trailing: {
                            Group {
                                if homeNeedsApproval {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                } else if homeIsResponding {
                                    ProgressView().controlSize(.small)
                                } else if homeUnreadOutcome == .failed {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                } else if homeUnreadOutcome == .succeeded {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 7, height: 7)
                                        .accessibilityLabel("New Assistant response")
                                }
                            }
                        },
                        action: onSelectHome)
                }

                // Default "All References" view
                if let defaultView {
                    sidebarSection {
                        SidebarRow(
                            icon: defaultView.icon,
                            label: defaultView.name,
                            isSelected: !isHomeSelected && selection == .view(defaultView.id!),
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
                        NewViewButton {
                            editorMode = .create
                        }
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
                        // Reorder uses a per-row `.onDrop` only — deliberately NO
                        // container-level drop target over the list. A parent `.onDrop`
                        // swallows the rows' `dropEntered` and silently breaks reordering.
                        // SwiftUI also gives no drag-cancel callback, so an abandoned drag
                        // (Esc, or released outside the list) is cleaned up by the
                        // mouse-button watchdog (see `.task(id: dragSession)` below).
                        ForEach(Array(userViews.enumerated()), id: \.element.id) { index, view in
                            SidebarRow(
                                icon: view.icon,
                                label: view.name,
                                isSelected: !isHomeSelected && selection == .view(view.id!)
                            ) {
                                selection = .view(view.id!)
                            }
                            // Dim the row being dragged; the others stay put — only the
                            // insertion bar moves, so there's no duplicate row on screen.
                            .opacity(draggedViewId == view.id ? 0.4 : 1)
                            .overlay(alignment: .top) {
                                if dropInsertionIndex == index { insertionBar.offset(y: -2.5) }
                            }
                            .overlay(alignment: .bottom) {
                                if dropInsertionIndex == userViews.count,
                                   index == userViews.count - 1 {
                                    insertionBar.offset(y: 2.5)
                                }
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
                            .onDrag {
                                dragSession += 1
                                draggedViewId = view.id
                                dropInsertionIndex = nil
                                return NSItemProvider(object: "\(view.id!)" as NSString)
                            }
                            .onDrop(of: [.text], delegate: ViewReorderDropDelegate(
                                rowIndex: index,
                                onHover: updateDropTarget,
                                onDrop: commitDrop
                            ))
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
        // Watchdog for drags that end without a drop (Esc, or released outside the
        // list): SwiftUI's `.onDrag` has no cancel callback, and a container-level drop
        // target can't catch it either — it swallows the rows' `dropEntered` and breaks
        // reordering (see the comment above the ForEach). The mouse button going up is
        // a reliable post-drag cleanup signal — every session is over by then (Esc may
        // end one earlier, while the button is still held) — so poll that.
        .task(id: dragSession) {
            guard draggedViewId != nil else { return }
            let session = dragSession
            while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(120))
            }
            // Button is up. A successful drop fires performDrop and clears the drag
            // state well within this grace period (heuristic, not a hard ordering
            // guarantee). After it, surviving state from THIS session means the drag
            // was cancelled; a newer session must be left alone — the token check also
            // covers the MainActor window where a new `.onDrag` has already mutated
            // state but SwiftUI hasn't yet cancelled this task.
            try? await Task.sleep(for: .milliseconds(300))
            if dragSession == session, draggedViewId != nil {
                draggedViewId = nil
                dropInsertionIndex = nil
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
    @State private var isPointerPressActive = false
    @State private var suppressReleaseAction = false
    @State private var pointerPressGeneration = 0

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
        Button {
            // Pointer activation already ran on mouse-down. Keep the Button's
            // release action for keyboard and accessibility activation only.
            if suppressReleaseAction {
                suppressReleaseAction = false
            } else {
                action()
            }
        } label: {
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
        // Native macOS sidebar selections respond on mouse-down. SwiftUI
        // Buttons normally wait for mouse-up, which made a deliberate click
        // add the full press duration to Home/library navigation latency.
        // Keep the Button itself so keyboard and accessibility actions retain
        // their standard behavior.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPointerPressActive else { return }
                    isPointerPressActive = true
                    suppressReleaseAction = true
                    pointerPressGeneration &+= 1
                    // Leave the current AppKit mouse-tracking callback before
                    // changing a retained SwiftUI Table's rows/visibility.
                    // Updating it reentrantly from the pointer event makes
                    // NSTableView warn today and becomes an assertion in a
                    // future macOS release. This still activates before the
                    // user's mouse-up, one main-loop turn after mouse-down.
                    DispatchQueue.main.async {
                        action()
                    }
                }
                .onEnded { _ in
                    isPointerPressActive = false
                }
        )
        // `.onDrag` can take over a row's zero-distance gesture and omit its
        // `onEnded`. Watch the physical button so a cancelled/outside drag
        // cannot leave future keyboard or accessibility actions suppressed.
        .task(id: pointerPressGeneration) {
            guard pointerPressGeneration > 0 else { return }
            let generation = pointerPressGeneration
            while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(25))
            }
            // Let normal Button release delivery consume the suppression first.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, pointerPressGeneration == generation else { return }
            isPointerPressActive = false
            suppressReleaseAction = false
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}

/// Compact but explicit affordance for creating a view. Unlike the old tertiary
/// plus glyph, the title remains discoverable while the pill appears only on hover.
private struct NewViewButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("New", systemImage: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(ToolbarHoverButtonStyle(hoverOpacity: 0.07, pressedOpacity: 0.12))
        .accessibilityLabel("Create a new view")
        .help("Create a new view")
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
                .frame(maxWidth: .infinity)
                .onSubmit(save)
            ViewIconGrid(selection: $icon)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveLabel, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .frame(width: ViewIconGrid.preferredWidth, alignment: .leading)
        .padding(20)
        .fittedPresentation()
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName, icon)
    }
}

// MARK: - Drag Reorder Drop Delegate

/// Per-row drop target for sidebar view reordering. It moves no rows itself — it only
/// reports which row the drag is hovering (`onHover`) so the parent can position the
/// insertion bar, and fires `onDrop` to commit the move. The single database write
/// happens once at drop, not on every hover.
private struct ViewReorderDropDelegate: DropDelegate {
    let rowIndex: Int
    let onHover: (Int) -> Void
    let onDrop: () -> Void

    func dropEntered(info: DropInfo) { onHover(rowIndex) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onHover(rowIndex)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        onDrop()
        return true
    }
}
#endif
