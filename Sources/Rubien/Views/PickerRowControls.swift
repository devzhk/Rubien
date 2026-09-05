#if os(macOS)
import SwiftUI
import RubienCore

struct PickerSelectionItem: Identifiable, Equatable {
    let id: String
    let name: String
    let color: String
}

let pickerSelectionVisibleLimit = 2

func pickerSelectionItems(
    values: [String],
    options: [SelectOption]
) -> [PickerSelectionItem] {
    values.map { value in
        let option = options.first(where: { $0.value == value })
        return PickerSelectionItem(
            id: value,
            name: value,
            color: option?.color ?? "#8E8E93"
        )
    }
}

func pickerSelectionItems(tags: [Tag]) -> [PickerSelectionItem] {
    tags.map { tag in
        PickerSelectionItem(
            id: tag.id.map(String.init) ?? tag.syncId,
            name: tag.name,
            color: tag.color
        )
    }
}

func pickerSelectionOverflowCount(
    itemCount: Int,
    visibleLimit: Int = pickerSelectionVisibleLimit
) -> Int {
    max(itemCount - visibleLimit, 0)
}

func pickerSelectionDisplayedItems(
    _ items: [PickerSelectionItem],
    wraps: Bool
) -> [PickerSelectionItem] {
    wraps ? items : Array(items.prefix(pickerSelectionVisibleLimit))
}

/// Passive count for selections omitted from the compact row. It deliberately
/// has no button, hover, tooltip, or popover behavior.
struct PickerSelectionOverflowLabel: View {
    let itemCount: Int
    let accessibilityLabel: String

    var body: some View {
        let overflowCount = pickerSelectionOverflowCount(itemCount: itemCount)
        if overflowCount > 0 {
            Text("+\(overflowCount)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .fixedSize()
                .accessibilityLabel("\(overflowCount) \(accessibilityLabel)")
        }
    }
}

/// Switches table selection cells between compact single-line and wrapping
/// layouts while preserving one shared rendering path for their contents.
struct PickerSelectionLayout<Content: View>: View {
    let wraps: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        let layout = wraps
            ? AnyLayout(FlowLayout(spacing: 2))
            : AnyLayout(HStackLayout(spacing: 2))
        layout {
            content()
        }
    }
}

struct PickerSelectionChip: View {
    let item: PickerSelectionItem
    let font: Font
    let verticalPadding: CGFloat
    let wraps: Bool
    let editLabel: String
    let onEdit: () -> Void

    var body: some View {
        Text(item.name)
            .font(font)
            .lineLimit(wraps ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, verticalPadding)
            .chipBackground(Color(hex: item.color))
            .simultaneousGesture(
                TapGesture(count: 2).onEnded(onEdit)
            )
            .help("\(item.name)\nDouble-click to \(editLabel.lowercased())")
            .accessibilityLabel(item.name)
            .accessibilityAction(named: Text(editLabel), onEdit)
    }
}

/// Gives an empty single-select target discoverable pointer feedback without
/// adding persistent button chrome or changing the appearance of value chips.
struct PickerSingleSelectionButtonStyle: ButtonStyle {
    let isEmpty: Bool

    func makeBody(configuration: Configuration) -> some View {
        PickerSingleSelectionButtonBody(
            configuration: configuration,
            isEmpty: isEmpty
        )
    }
}

private struct PickerSingleSelectionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isEmpty: Bool

    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(.horizontal, isEmpty ? 5 : 0)
            .padding(.vertical, isEmpty ? 3 : 0)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isEmpty && (isHovered || configuration.isPressed)
                            ? Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08)
                            : .clear
                    )
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// Contextual picker affordance for multi-select and Tags cells. Keep the
/// button mounted (as PickerRowActions does) so hiding it neither shifts the
/// chips nor removes keyboard and accessibility access.
struct PickerSelectionAddButton: View {
    let title: String
    let accessibilityLabel: String
    var isActive = true
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "plus")
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(CompactHoverButtonStyle())
        .opacity(isFocused ? 1 : (isActive ? (isHovered ? 1 : 0.8) : 0))
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .fixedSize()
        .layoutPriority(1)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.accentColor, lineWidth: isFocused ? 1.5 : 0)
        }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

enum PickerItemRenameValidation: Equatable {
    case unchanged
    case valid(String)
    case invalid(String)
}

func normalizedPickerItemName(_ draft: String) -> String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
}

func pickerItemNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
    lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
}

func validatePickerItemRename(
    draft: String,
    originalValue: String,
    otherValues: [String],
    duplicateMessage: String
) -> PickerItemRenameValidation {
    let trimmed = normalizedPickerItemName(draft)
    guard !trimmed.isEmpty else {
        return .invalid("Name can’t be empty.")
    }
    guard trimmed != originalValue else { return .unchanged }
    guard !otherValues.contains(where: { pickerItemNamesMatch($0, trimmed) }) else {
        return .invalid(duplicateMessage)
    }
    return .valid(trimmed)
}

/// Shared hover/focus controls for mutable rows in option and tag pickers.
/// Keeping the buttons mounted preserves keyboard and accessibility access;
/// pointer hover reveals them and each icon has its own hover background.
struct PickerRowActions: View {
    private enum FocusedAction: Hashable {
        case rename, delete
    }

    let isRowHovering: Bool
    let itemName: String
    let renameHelp: String
    let deleteHelp: String
    let onRename: (() -> Void)?
    let onDelete: (() -> Void)?

    @FocusState private var focusedAction: FocusedAction?

    var body: some View {
        HStack(spacing: 2) {
            if let onRename {
                Button(action: onRename) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(CompactHoverButtonStyle())
                .focused($focusedAction, equals: .rename)
                .help(renameHelp)
                .accessibilityLabel("\(renameHelp) \(itemName)")
            }
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(CompactHoverButtonStyle())
                .focused($focusedAction, equals: .delete)
                .help(deleteHelp)
                .accessibilityLabel("\(deleteHelp) \(itemName)")
            }
        }
        .opacity(isRowHovering || focusedAction != nil ? 1 : 0)
    }
}

/// Inline rename editor shared by select options and tags.
struct PickerItemRenameRow: View {
    let color: String
    let placeholder: String
    @Binding var text: String
    let errorMessage: String?
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: color))
                    .frame(width: 8, height: 8)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isFocused)
                    .onSubmit(onCommit)
                    .onExitCommand(perform: onCancel)
                    .accessibilityLabel(placeholder)
                    .accessibilityHint(errorMessage ?? "Press Return to save the new name.")
                Button(action: onCommit) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(CompactHoverButtonStyle())
                .help("Save rename")
                .accessibilityLabel("Save rename")
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                }
                .buttonStyle(CompactHoverButtonStyle())
                .help("Cancel rename")
                .accessibilityLabel("Cancel rename")
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Rename error: \(errorMessage)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .onAppear {
            DispatchQueue.main.async { isFocused = true }
        }
    }
}
#endif
