#if os(macOS)
import SwiftUI

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
