#if os(macOS)
import SwiftUI
import RubienCore

// MARK: - Property Row Layout

struct PropertyRowLayout<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .trailing)
                .lineLimit(1)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 28)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Inline String Row

struct InlineStringRow: View {
    let label: String
    let value: String
    let placeholder: String
    let isEditing: Bool
    let onBeginEditing: () -> Void
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var editText = ""
    @FocusState private var isFocused: Bool

    init(label: String, value: String, placeholder: String = "Empty",
         isEditing: Bool, onBeginEditing: @escaping () -> Void,
         onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.isEditing = isEditing
        self.onBeginEditing = onBeginEditing
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        PropertyRowLayout(label: label) {
            if isEditing {
                TextField(placeholder, text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFocused)
                    .onSubmit { onCommit(editText) }
                    .onExitCommand { onCancel() }
                    .onAppear {
                        editText = value
                        DispatchQueue.main.async { isFocused = true }
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { onCommit(editText) }
                    }
            } else {
                Text(value.isEmpty ? placeholder : value)
                    .font(.system(size: 13))
                    .foregroundStyle(value.isEmpty ? .quaternary : .primary)
            }
        }
        .onTapGesture {
            if !isEditing { onBeginEditing() }
        }
    }
}

// MARK: - Inline Number Row

struct InlineNumberRow: View {
    let label: String
    let value: Int?
    let placeholder: String
    let isEditing: Bool
    let onBeginEditing: () -> Void
    let onCommit: (Int?) -> Void
    let onCancel: () -> Void

    @State private var editText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        PropertyRowLayout(label: label) {
            if isEditing {
                TextField(placeholder, text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFocused)
                    .onSubmit { onCommit(Int(editText)) }
                    .onExitCommand { onCancel() }
                    .onAppear {
                        editText = value.map(String.init) ?? ""
                        DispatchQueue.main.async { isFocused = true }
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { onCommit(Int(editText)) }
                    }
            } else {
                let display = value.map(String.init) ?? ""
                Text(display.isEmpty ? placeholder : display)
                    .font(.system(size: 13))
                    .foregroundStyle(display.isEmpty ? .quaternary : .primary)
            }
        }
        .onTapGesture {
            if !isEditing { onBeginEditing() }
        }
    }
}

// MARK: - Inline Single Select Row

struct InlineSingleSelectRow: View {
    let label: String
    let value: String
    let options: [SelectOption]
    let onSelect: (String) -> Void
    /// Pass non-nil to expose inline option creation. Nil locks the picker to
    /// the current options list (used for Type, whose options drive BibTeX
    /// buckets and cannot be user-extended).
    var onCreateOption: ((String) -> Void)? = nil
    /// Pass non-nil to expose inline option renaming. The shared picker owns
    /// validation and surfaces any persistence error without dismissing.
    var onRenameOption: ((String, String) throws -> Void)? = nil
    /// Pass non-nil to expose a trash affordance on each option row (revealed
    /// on hover). The caller handles persistence + the in-use reassignment
    /// path. See `SelectOptionPicker.onDeleteOption`.
    var onDeleteOption: ((String) -> Void)? = nil
    /// Opts deletion into the confirm-when-in-use flow. See
    /// `SelectOptionPicker.deleteUnlessInUse`.
    var deleteUnlessInUse: ((String) -> Int?)? = nil
    /// Optional explanatory message rendered at the bottom of the picker when
    /// `onCreateOption` is nil. See `SelectOptionPicker.lockedHint`.
    var lockedHint: String? = nil

    @State private var showPicker = false

    var body: some View {
        PropertyRowLayout(label: label) {
            Button {
                showPicker = true
            } label: {
                if let current = options.first(where: { $0.value == value }) {
                    Text(current.value)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .chipBackground(Color(hex: current.color))
                } else if !value.isEmpty {
                    Text(value)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Text("Select…")
                        .font(.system(size: 12))
                        .foregroundStyle(.quaternary)
                }
            }
            .buttonStyle(PickerSingleSelectionButtonStyle(isEmpty: value.isEmpty))
            .help("Select option")
            .accessibilityLabel("Select \(label)")
        }
        .popover(isPresented: $showPicker) {
            SelectOptionPicker(
                selectedValues: value.isEmpty ? [] : [value],
                options: options,
                isSingleSelect: true,
                onCommit: { values in
                    if let selected = values.first {
                        onSelect(selected)
                    }
                },
                onCreateOption: onCreateOption,
                onRenameOption: onRenameOption,
                onDeleteOption: onDeleteOption,
                deleteUnlessInUse: deleteUnlessInUse,
                lockedHint: lockedHint
            )
        }
    }
}

// MARK: - Inline Multi-Select Row (for Tags)

struct InlineTagsRow: View {
    let label: String
    let tags: [Tag]
    let allTags: [Tag]
    let onUpdateTags: ([Int64]) -> Void
    let onCreateTag: (String) -> Int64?
    var onRenameTag: ((Int64, String) throws -> Void)? = nil
    let onDeleteTag: (Int64) -> Void
    let deleteTagUnlessInUse: (Int64) -> Int?

    @State private var showPicker = false

    var body: some View {
        let items = pickerSelectionItems(tags: tags)
        PropertyRowLayout(label: label) {
            FlowLayout(spacing: 2) {
                ForEach(items.prefix(pickerSelectionVisibleLimit)) { item in
                    PickerSelectionChip(
                        item: item,
                        font: .system(size: 11),
                        verticalPadding: 2,
                        wraps: true,
                        editLabel: "Edit tags",
                        onEdit: { showPicker = true }
                    )
                }
                PickerSelectionOverflowLabel(
                    itemCount: items.count,
                    accessibilityLabel: "more selected tags"
                )
                PickerSelectionAddButton(title: "tag", accessibilityLabel: "Add tag") {
                    showPicker = true
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .popover(isPresented: $showPicker) {
                TagPickerPopover(
                    assignedTags: tags,
                    allTags: allTags,
                    onCommit: onUpdateTags,
                    onCreateTag: onCreateTag,
                    onRenameTag: onRenameTag,
                    onDeleteTag: onDeleteTag,
                    deleteTagUnlessInUse: deleteTagUnlessInUse
                )
            }
        }
    }
}

// MARK: - Inline Multi-Select Row (for custom select options)

struct InlineMultiSelectOptionRow: View {
    let label: String
    let selectedValues: [String]
    let options: [SelectOption]
    let onUpdate: ([String]) -> Void
    let onCreateOption: (String) -> Void
    /// Pass non-nil to expose inline option renaming.
    var onRenameOption: ((String, String) throws -> Void)? = nil
    /// Pass non-nil to expose a trash affordance per option (see
    /// `SelectOptionPicker.onDeleteOption` / `deleteUnlessInUse`).
    var onDeleteOption: ((String) -> Void)? = nil
    var deleteUnlessInUse: ((String) -> Int?)? = nil

    @State private var showPicker = false

    var body: some View {
        let items = pickerSelectionItems(values: selectedValues, options: options)
        PropertyRowLayout(label: label) {
            FlowLayout(spacing: 2) {
                ForEach(items.prefix(pickerSelectionVisibleLimit)) { item in
                    PickerSelectionChip(
                        item: item,
                        font: .system(size: 11),
                        verticalPadding: 2,
                        wraps: true,
                        editLabel: "Edit options",
                        onEdit: { showPicker = true }
                    )
                }
                PickerSelectionOverflowLabel(
                    itemCount: items.count,
                    accessibilityLabel: "more selected options"
                )
                PickerSelectionAddButton(title: "option", accessibilityLabel: "Add option") {
                    showPicker = true
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .popover(isPresented: $showPicker) {
                SelectOptionPicker(
                    selectedValues: selectedValues,
                    options: options,
                    onCommit: onUpdate,
                    onCreateOption: onCreateOption,
                    onRenameOption: onRenameOption,
                    onDeleteOption: onDeleteOption,
                    deleteUnlessInUse: deleteUnlessInUse
                )
            }
        }
    }
}

// MARK: - Inline URL Row

struct InlineURLRow: View {
    let label: String
    let value: String
    let isEditing: Bool
    let onBeginEditing: () -> Void
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var editText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        PropertyRowLayout(label: label) {
            if isEditing {
                TextField("https://...", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFocused)
                    .onSubmit { onCommit(editText) }
                    .onExitCommand { onCancel() }
                    .onAppear {
                        editText = value
                        DispatchQueue.main.async { isFocused = true }
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { onCommit(editText) }
                    }
            } else if !value.isEmpty {
                HStack(spacing: 6) {
                    if let url = resolvedURL {
                        Link(destination: url) {
                            Text(value)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(value)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button {
                        onBeginEditing()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Empty")
                    .font(.system(size: 13))
                    .foregroundStyle(.quaternary)
            }
        }
        .onTapGesture {
            if !isEditing && value.isEmpty { onBeginEditing() }
        }
    }

    private var resolvedURL: URL? {
        if label == "DOI" && !value.isEmpty {
            return URL(string: "https://doi.org/\(value)")
        }
        return URL(string: value)
    }
}

// MARK: - Inline Checkbox Row

struct InlineCheckboxRow: View {
    let label: String
    let isChecked: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        PropertyRowLayout(label: label) {
            Toggle("", isOn: Binding(
                get: { isChecked },
                set: { onToggle($0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
        }
    }
}

// MARK: - Inline Date Row

struct InlineDateRow: View {
    let label: String
    let value: Date?
    let onCommit: (Date?) -> Void

    @State private var showPicker = false
    @State private var editDate = Date()

    var body: some View {
        PropertyRowLayout(label: label) {
            HStack(spacing: 6) {
                if let date = value {
                    Text(date, style: .date)
                        .font(.system(size: 13))
                } else {
                    Text("Empty")
                        .font(.system(size: 13))
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { showPicker = true }
            .popover(isPresented: $showPicker) {
                VStack(spacing: 8) {
                    DatePicker("", selection: $editDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                    HStack {
                        Button("Clear") {
                            onCommit(nil)
                            showPicker = false
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("Done") {
                            onCommit(editDate)
                            showPicker = false
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .frame(width: 280)
                .onAppear {
                    editDate = value ?? Date()
                }
                .activatePopoverHover()
            }
        }
    }
}

// MARK: - Select Option Picker (for custom single/multi-select)

typealias SelectOptionRenameValidation = PickerItemRenameValidation

/// Validates the user-entered label before the database-backed rename runs.
/// Keep this separate from the view so trimming and duplicate handling remain
/// deterministic and directly testable.
func validateSelectOptionRename(
    draft: String,
    originalValue: String,
    options: [SelectOption]
) -> SelectOptionRenameValidation {
    validatePickerItemRename(
        draft: draft,
        originalValue: originalValue,
        otherValues: options
            .filter { $0.value != originalValue }
            .map(\.value),
        duplicateMessage: "An option with this name already exists."
    )
}

struct SelectOptionPicker: View {
    let selectedValues: [String]
    let options: [SelectOption]
    var isSingleSelect: Bool = false
    let onCommit: ([String]) -> Void
    /// When non-nil, the picker exposes an inline "create new option" affordance
    /// (typing in the search field + pressing Enter, plus a "create X" row when
    /// the search has no exact match). Nil for properties whose options are
    /// fixed (currently only Type post-Phase-3); the picker hides the create
    /// path entirely so users aren't led to expect mutability that doesn't apply.
    let onCreateOption: ((String) -> Void)?
    /// When non-nil, each option row shows a pencil button on hover. The
    /// callback performs the atomic database rename, including migration of
    /// values already assigned to references.
    var onRenameOption: ((String, String) throws -> Void)? = nil
    /// When non-nil, each option row shows a small trash button on hover that
    /// invokes this callback with the option value. Caller is responsible for
    /// the actual mutation (calling `db.deletePropertyOption`) and any in-use
    /// reassignment. Nil hides the affordance entirely (Type / read-only paths).
    var onDeleteOption: ((String) -> Void)? = nil
    /// Opts deletion into a confirm-when-in-use flow. Attempts to delete the
    /// option and returns: `nil` if it was deleted outright (unused) **or**
    /// could not be deleted (a no-op — fails closed, nothing destructive
    /// happened), or the number of references using it (deletion was blocked;
    /// the picker shows an inline confirmation and only then calls
    /// `onDeleteOption` to perform the destructive clear). When nil, `onDeleteOption`
    /// fires immediately on trash tap — the no-confirm reassign path used by Status.
    var deleteUnlessInUse: ((String) -> Int?)? = nil
    /// Optional explanatory message shown at the bottom of the picker when
    /// `onCreateOption` is nil. Lets us tell the user *why* creation is locked.
    var lockedHint: String? = nil

    @State private var search = ""
    @State private var localSelected: Set<String> = []
    @State private var renamingValue: String?
    @State private var renameText = ""
    @State private var renameError: String?
    /// Set while an in-use option awaits delete confirmation; renders the
    /// inline confirm prompt in place of the option list.
    @State private var confirming: (value: String, count: Int)?
    /// Measured natural height of the option list. Once measured, we floor the
    /// scroll area at `min(content, 200)` so the popover can't get stuck shorter
    /// after the (shorter) confirm view swaps back to the list: NSPopover
    /// re-proposes its stale, smaller content size and a *greedy* ScrollView
    /// would absorb it, leaving the picker squished. A definite floor forces the
    /// popover to restore. Stays `nil`-constrained until measured, so first
    /// appearance is unchanged.
    @State private var listContentHeight: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    private var normalizedOptions: [SelectOption] {
        PropertyDefinition.normalizedOptions(options)
    }

    private var filteredOptions: [SelectOption] {
        if search.isEmpty { return normalizedOptions }
        return normalizedOptions.filter { $0.value.localizedCaseInsensitiveContains(search) }
    }

    private var canCreate: Bool { onCreateOption != nil }

    private func creatableOptionName(from draft: String) -> String? {
        let candidate = normalizedPickerItemName(draft)
        guard !candidate.isEmpty,
              !normalizedOptions.contains(where: {
                  pickerItemNamesMatch($0.value, candidate)
              })
        else { return nil }
        return candidate
    }

    private func handleCreate(_ candidate: String) {
        onCreateOption?(candidate)
        if isSingleSelect {
            localSelected = [candidate]
            onCommit([candidate])
            dismiss()
        } else {
            localSelected.insert(candidate)
            onCommit(Array(localSelected))
        }
        search = ""
    }

    var body: some View {
        Group {
            if let pending = confirming {
                confirmView(pending)
            } else {
                pickerBody
            }
        }
        .frame(width: 220)
        .onAppear {
            localSelected = Set(selectedValues)
        }
        .activatePopoverHover()
        // No `onDisappear { onCommit(...) }` — both branches commit eagerly
        // now (single-select on tap, multi-select on each toggle). Deferring
        // to disappear would wait for NSPopover's ~500–800ms dismiss
        // animation before the cell update.
    }

    private var pickerBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField(canCreate ? "Search or create…" : "Search…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        guard onCreateOption != nil,
                              let candidate = creatableOptionName(from: search)
                        else { return }
                        handleCreate(candidate)
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredOptions, id: \.value) { option in
                        if renamingValue == option.value {
                            PickerItemRenameRow(
                                color: option.color,
                                placeholder: "Option name",
                                text: $renameText,
                                errorMessage: renameError,
                                onCommit: { commitRename(option.value) },
                                onCancel: cancelRename
                            )
                        } else {
                            SelectOptionPickerRow(
                                option: option,
                                isSelected: localSelected.contains(option.value),
                                onTap: {
                                    if isSingleSelect {
                                        localSelected = [option.value]
                                        onCommit([option.value])
                                        dismiss()
                                    } else {
                                        if localSelected.contains(option.value) {
                                            localSelected.remove(option.value)
                                        } else {
                                            localSelected.insert(option.value)
                                        }
                                        // Eager commit so the cell behind the popover
                                        // updates without waiting for NSPopover's
                                        // dismiss animation. Matches the existing
                                        // eager-commit pattern in the create paths.
                                        onCommit(Array(localSelected))
                                    }
                                },
                                onRename: onRenameOption == nil ? nil : {
                                    beginRename(option.value)
                                },
                                onDelete: onDeleteOption == nil ? nil : {
                                    requestDelete(option.value)
                                }
                            )
                        }
                    }

                    if onCreateOption != nil,
                       let candidate = creatableOptionName(from: search) {
                        Button {
                            handleCreate(candidate)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.accentColor)
                                Text("Create \"\(candidate)\"")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.accentColor)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    listContentHeight = height
                }
            }
            .frame(
                minHeight: listContentHeight > 0 ? min(listContentHeight, 200) : nil,
                maxHeight: 200
            )

            // Footer hint for properties whose options are intentionally fixed
            // (Type drives BibTeX export buckets — see PropertyManagerPopover /
            // CLAUDE.md). Helps users find the right tool when their reach for
            // "add a Type option" is really an organization need.
            if !canCreate, let lockedHint {
                Divider()
                Text(lockedHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Trash tapped on `value`. With no `deleteUnlessInUse` gate, delete
    /// immediately (Status's reassign path). With a gate, attempt the delete:
    /// if the option is still in use the gate returns a count and we surface an
    /// inline confirmation before performing the destructive clear.
    private func requestDelete(_ value: String) {
        // The row only wires this up when `onDeleteOption != nil`, so the
        // optional-chained call below always fires.
        guard let probe = deleteUnlessInUse else {
            onDeleteOption?(value)
            return
        }
        if let count = probe(value) {
            confirming = (value, count)
        }
        // nil → already deleted (unused) or a safe no-op; nothing to confirm.
    }

    private func beginRename(_ value: String) {
        renamingValue = value
        renameText = value
        renameError = nil
    }

    private func cancelRename() {
        renamingValue = nil
        renameText = ""
        renameError = nil
    }

    private func commitRename(_ originalValue: String) {
        switch validateSelectOptionRename(
            draft: renameText,
            originalValue: originalValue,
            options: normalizedOptions
        ) {
        case .unchanged:
            cancelRename()
        case .invalid(let message):
            renameError = message
        case .valid(let newValue):
            do {
                try onRenameOption?(originalValue, newValue)
                if localSelected.remove(originalValue) != nil {
                    localSelected.insert(newValue)
                }
                cancelRename()
            } catch PropertyOptionError.duplicateValue {
                renameError = "An option with this name already exists."
            } catch PropertyOptionError.optionNotFound {
                renameError = "This option no longer exists."
            } catch {
                renameError = "Couldn’t rename this option."
            }
        }
    }

    @ViewBuilder
    private func confirmView(_ pending: (value: String, count: Int)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remove \u{201C}\(pending.value)\u{201D}?")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("This clears it from \(pending.count) reference\(pending.count == 1 ? "" : "s").")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirming = nil }
                    .buttonStyle(.bordered)
                Button("Remove") {
                    onDeleteOption?(pending.value)
                    confirming = nil
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(12)
    }
}

// MARK: - Single option row inside the picker

/// One row in `SelectOptionPicker`. Local `@State` keeps hover updates row-scoped.
/// Row uses `.onTapGesture` instead of a wrapping `Button` so the inner trash
/// `Button` actually receives its taps (nested `.plain` Buttons on macOS route
/// inner taps to the outer one, dismissing the popover before delete fires —
/// same sibling-target pattern as `TagPickerPopover`).
private struct SelectOptionPickerRow: View {
    let option: SelectOption
    let isSelected: Bool
    let onTap: () -> Void
    /// When non-nil, a small pencil button appears on hover.
    let onRename: (() -> Void)?
    /// When non-nil, a small trash button appears on hover.
    let onDelete: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(option.value)
                .font(.system(size: 12))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .chipBackground(Color(hex: option.color))
            Spacer()
            PickerRowActions(
                isRowHovering: isHovering,
                itemName: option.value,
                renameHelp: "Rename option",
                deleteHelp: "Delete option",
                onRename: onRename,
                onDelete: onDelete
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { isHovering = $0 }
    }
}

#endif
