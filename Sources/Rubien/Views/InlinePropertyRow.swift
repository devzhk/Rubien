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
    /// Pass non-nil to expose a trash affordance on each option row (revealed
    /// on hover). The caller handles persistence + the in-use reassignment
    /// path. See `SelectOptionPicker.onDeleteOption`.
    var onDeleteOption: ((String) -> Void)? = nil
    /// Optional explanatory message rendered at the bottom of the picker when
    /// `onCreateOption` is nil. See `SelectOptionPicker.lockedHint`.
    var lockedHint: String? = nil

    @State private var showPicker = false

    var body: some View {
        PropertyRowLayout(label: label) {
            if let current = options.first(where: { $0.value == value }) {
                Text(current.value)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .chipBackground(Color(hex: current.color))
            } else {
                Text(value.isEmpty ? "Select..." : value)
                    .font(.system(size: 12))
                    .foregroundStyle(value.isEmpty ? .quaternary : .primary)
            }
        }
        .onTapGesture { showPicker = true }
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
                onDeleteOption: onDeleteOption,
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
    let onDeleteTag: (Int64) -> Void

    @State private var showPicker = false

    var body: some View {
        PropertyRowLayout(label: label) {
            HStack(spacing: 4) {
                if tags.isEmpty {
                    Text("Empty")
                        .font(.system(size: 12))
                        .foregroundStyle(.quaternary)
                } else {
                    ForEach(tags) { tag in
                        Text(tag.name)
                            .font(.system(size: 11))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .chipBackground(Color(hex: tag.color))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { showPicker = true }
            .popover(isPresented: $showPicker) {
                TagPickerPopover(
                    assignedTags: tags,
                    allTags: allTags,
                    onCommit: onUpdateTags,
                    onCreateTag: onCreateTag,
                    onDeleteTag: onDeleteTag
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

    @State private var showPicker = false

    var body: some View {
        PropertyRowLayout(label: label) {
            HStack(spacing: 4) {
                if selectedValues.isEmpty {
                    Text("Empty")
                        .font(.system(size: 12))
                        .foregroundStyle(.quaternary)
                } else {
                    ForEach(selectedValues, id: \.self) { value in
                        if let option = options.first(where: { $0.value == value }) {
                            Text(option.value)
                                .font(.system(size: 11))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .chipBackground(Color(hex: option.color))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { showPicker = true }
            .popover(isPresented: $showPicker) {
                SelectOptionPicker(
                    selectedValues: selectedValues,
                    options: options,
                    onCommit: onUpdate,
                    onCreateOption: onCreateOption
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
            }
        }
    }
}

// MARK: - Select Option Picker (for custom single/multi-select)

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
    /// When non-nil, each option row shows a small trash button on hover that
    /// invokes this callback with the option value. Caller is responsible for
    /// the actual mutation (calling `db.deletePropertyOption`) and any in-use
    /// reassignment. Nil hides the affordance entirely (Type / read-only paths).
    var onDeleteOption: ((String) -> Void)? = nil
    /// Optional explanatory message shown at the bottom of the picker when
    /// `onCreateOption` is nil. Lets us tell the user *why* creation is locked.
    var lockedHint: String? = nil

    @State private var search = ""
    @State private var localSelected: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    private var filteredOptions: [SelectOption] {
        if search.isEmpty { return options }
        return options.filter { $0.value.localizedCaseInsensitiveContains(search) }
    }

    private var canCreate: Bool { onCreateOption != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField(canCreate ? "Search or create…" : "Search…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        guard let onCreateOption else { return }
                        let trimmed = search.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty && !options.contains(where: { $0.value.lowercased() == trimmed.lowercased() }) {
                            onCreateOption(trimmed)
                            if isSingleSelect {
                                localSelected = [trimmed]
                                onCommit([trimmed])
                                dismiss()
                            } else {
                                localSelected.insert(trimmed)
                                onCommit(Array(localSelected))
                            }
                            search = ""
                        }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredOptions, id: \.value) { option in
                        SelectOptionPickerRow(
                            option: option,
                            isSelected: localSelected.contains(option.value),
                            onTap: {
                                if isSingleSelect {
                                    localSelected = [option.value]
                                    onCommit([option.value])
                                    dismiss()
                                } else if localSelected.contains(option.value) {
                                    localSelected.remove(option.value)
                                } else {
                                    localSelected.insert(option.value)
                                }
                            },
                            onDelete: onDeleteOption.map { handler in
                                { handler(option.value) }
                            }
                        )
                    }

                    if let onCreateOption,
                       !search.isEmpty,
                       !options.contains(where: { $0.value.lowercased() == search.trimmingCharacters(in: .whitespaces).lowercased() }) {
                        Button {
                            let trimmed = search.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                onCreateOption(trimmed)
                                if isSingleSelect {
                                    localSelected = [trimmed]
                                    onCommit([trimmed])
                                    dismiss()
                                } else {
                                    localSelected.insert(trimmed)
                                    onCommit(Array(localSelected))
                                }
                                search = ""
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.accentColor)
                                Text("Create \"\(search.trimmingCharacters(in: .whitespaces))\"")
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
            }
            .frame(maxHeight: 200)

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
        .frame(width: 220)
        .onAppear {
            localSelected = Set(selectedValues)
        }
        .onDisappear {
            guard !isSingleSelect else { return }
            onCommit(Array(localSelected))
        }
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
            if let onDelete, isHovering {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete option")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { isHovering = $0 }
    }
}
