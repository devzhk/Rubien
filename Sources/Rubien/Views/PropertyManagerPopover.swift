#if os(macOS)
import SwiftUI
import AppKit
import RubienCore

struct PropertyManagerPopover: View {
    @Binding var propertyDefs: [PropertyDefinition]
    let onToggleVisibility: (Int64, Bool) -> Void
    let onDelete: (Int64) -> Void
    let onReorder: ([Int64]) -> Void
    let onCreateProperty: (String, PropertyType) -> Void
    let onRenameProperty: (Int64, String) -> Void

    @State private var showNewProperty = false
    @State private var newPropName = ""
    @State private var newPropType: PropertyType = .string
    @State private var draggedId: Int64?

    private var visibleProps: [PropertyDefinition] {
        propertyDefs.filter(\.isVisible).sorted { $0.sortOrder < $1.sortOrder }
    }

    private var hiddenProps: [PropertyDefinition] {
        propertyDefs.filter { !$0.isVisible }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Properties")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    showNewProperty = true
                } label: {
                    Label("Create", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(ToolbarHoverButtonStyle(hoverOpacity: 0.12, pressedOpacity: 0.18))
                .focusEffectDisabled()
                .help("Add new property")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Visible properties
                    if !visibleProps.isEmpty {
                        Text("VISIBLE")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 4)

                        ForEach(visibleProps) { prop in
                            PropertyManagerRow(
                                prop: prop,
                                onToggleVisibility: { onToggleVisibility(prop.id!, false) },
                                onDelete: prop.isDefault ? nil : { onDelete(prop.id!) },
                                onRename: prop.isDefault ? nil : { newName in onRenameProperty(prop.id!, newName) }
                            )
                            .onDrag {
                                draggedId = prop.id
                                return NSItemProvider(object: "\(prop.id ?? 0)" as NSString)
                            }
                            .onDrop(of: [.text], delegate: PropertyDropDelegate(
                                targetId: prop.id!,
                                allVisible: visibleProps,
                                draggedId: $draggedId,
                                onReorder: onReorder
                            ))
                        }
                    }

                    // Hidden properties
                    if !hiddenProps.isEmpty {
                        Text("HIDDEN")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 4)

                        ForEach(hiddenProps) { prop in
                            HiddenPropertyRow(
                                prop: prop,
                                onShow: { onToggleVisibility(prop.id!, true) },
                                onDelete: prop.isDefault ? nil : { onDelete(prop.id!) }
                            )
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 300)

            // New property form
            if showNewProperty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Property name", text: $newPropName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    Picker("Type", selection: $newPropType) {
                        ForEach(PropertyType.allCases, id: \.self) { type in
                            Label(type.label, systemImage: type.icon).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 12))

                    HStack {
                        Button("Cancel") {
                            newPropName = ""
                            showNewProperty = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                        Spacer()

                        Button("Add") {
                            let trimmed = newPropName.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                onCreateProperty(trimmed, newPropType)
                                newPropName = ""
                                showNewProperty = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newPropName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 260)
        .background(PopoverKeyActivator())
    }
}

// MARK: - Popover key-window activator
//
// SwiftUI's `.onHover` installs its NSTrackingArea with key-window scope, so hover
// highlights only fire while the hosting window is key. A `.popover` does not become
// key on its own: its rows never highlight, and — worse — mouse-moved events keep
// activating the *main* window's tracking areas instead, leaking hover onto the table
// rows behind the popover. Making the popover window key on appear activates the
// popover's own tracking (and deactivates the table's), fixing both the dead hover
// and the leak-through.
private struct PopoverKeyActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ActivatorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ActivatorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            // The popover window may not be ready to take key synchronously on the
            // same runloop turn it's added, so defer the activation.
            DispatchQueue.main.async { [weak window] in
                window?.makeKey()
            }
        }
    }
}

// MARK: - Property Manager Row

private struct PropertyManagerRow: View {
    let prop: PropertyDefinition
    let onToggleVisibility: () -> Void
    let onDelete: (() -> Void)?
    let onRename: ((String) -> Void)?

    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)

            Image(systemName: prop.type.icon)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 16)

            if isRenaming, let onRename {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { onRename(trimmed) }
                        isRenaming = false
                    }
                    .onExitCommand { isRenaming = false }
            } else {
                Text(prop.name)
                    .font(.system(size: 12))
                    .onTapGesture {
                        if onRename != nil {
                            renameText = prop.name
                            isRenaming = true
                        }
                    }
            }

            Spacer()

            Button {
                onToggleVisibility()
            } label: {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Hide property")

            if let onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete property")
            }
        }
        .propertyRowHover()
    }
}

// MARK: - Hidden Property Row

private struct HiddenPropertyRow: View {
    let prop: PropertyDefinition
    let onShow: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: prop.type.icon)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            Text(prop.name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                onShow()
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Show property")

            if let onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete property")
            }
        }
        .propertyRowHover()
    }
}

// MARK: - Row hover highlight

/// Standard row padding plus a subtle hover background, shared by the property
/// rows. Owns its own hover state so each row highlights on pointer-over.
private struct PropertyRowHover: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private extension View {
    func propertyRowHover() -> some View { modifier(PropertyRowHover()) }
}

// MARK: - Drop Delegate for Reordering

private struct PropertyDropDelegate: DropDelegate {
    let targetId: Int64
    let allVisible: [PropertyDefinition]
    @Binding var draggedId: Int64?
    let onReorder: ([Int64]) -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggedId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedId,
              draggedId != targetId,
              let fromIndex = allVisible.firstIndex(where: { $0.id == draggedId }),
              let toIndex = allVisible.firstIndex(where: { $0.id == targetId }) else {
            return
        }
        var ids = allVisible.compactMap(\.id)
        ids.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        onReorder(ids)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
#endif
