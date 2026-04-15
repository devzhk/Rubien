import SwiftUI
import RubienCore

// MARK: - Editing Cell ID

struct EditingCellID: Equatable {
    let referenceId: Int64
    let fieldKey: String
}

// Inline-edit cells (string/number/url) carry no tap gesture — Return on the
// selected row enters edit mode (in ReferenceTableView). Picker cells keep
// double-click because their popover doesn't race with Table row selection
// the way an inline TextField's focus does.
//
// Esc inside an editing TextField is swallowed by `.onExitCommand`; the outer
// `.onKeyPress(.escape)` in ReferenceTableView only fires when no cell is
// mid-edit. Don't change without testing both Esc paths.

private extension View {
    // Tab / Shift+Tab inside an editing TextField: commit the current value
    // and advance (or retreat) to the next inline-editable column.
    func onTabCommit(
        _ onTab: ((_ backwards: Bool) -> Void)?,
        commit: @escaping () -> Void
    ) -> some View {
        onKeyPress(.tab, phases: .down) { press in
            commit()
            onTab?(press.modifiers.contains(.shift))
            return .handled
        }
    }
}

// MARK: - Editable String Cell

struct EditableStringCell: View {
    let value: String
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    var placeholder: String = "—"
    var onTab: ((_ backwards: Bool) -> Void)? = nil

    @State private var editText = ""
    @State private var didCancel = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField(placeholder, text: $editText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)
                .onSubmit { onCommit(editText) }
                .onExitCommand {
                    didCancel = true
                    onCancel()
                }
                .onTabCommit(onTab) { onCommit(editText) }
                .onAppear {
                    editText = value
                    didCancel = false
                    DispatchQueue.main.async { isFocused = true }
                }
                .onChange(of: isFocused) { _, focused in
                    guard !focused else { return }
                    if didCancel {
                        didCancel = false
                    } else {
                        onCommit(editText)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
        } else {
            Text(value.isEmpty ? placeholder : value)
                .font(.callout)
                .foregroundStyle(value.isEmpty ? .quaternary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Editable Number Cell

struct EditableNumberCell: View {
    let value: Int?
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCommit: (Int?) -> Void
    let onCancel: () -> Void
    var placeholder: String = "—"
    var onTab: ((_ backwards: Bool) -> Void)? = nil

    @State private var editText = ""
    @State private var didCancel = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField(placeholder, text: $editText)
                .textFieldStyle(.plain)
                .font(.callout)
                .monospacedDigit()
                .focused($isFocused)
                .onSubmit { onCommit(Int(editText)) }
                .onExitCommand {
                    didCancel = true
                    onCancel()
                }
                .onTabCommit(onTab) { onCommit(Int(editText)) }
                .onAppear {
                    editText = value.map(String.init) ?? ""
                    didCancel = false
                    DispatchQueue.main.async { isFocused = true }
                }
                .onChange(of: isFocused) { _, focused in
                    guard !focused else { return }
                    if didCancel {
                        didCancel = false
                    } else {
                        onCommit(Int(editText))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
        } else {
            let display = value.map(String.init) ?? ""
            Text(display.isEmpty ? placeholder : display)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(display.isEmpty ? .quaternary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Editable URL Cell

struct EditableURLCell: View {
    let value: String
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    var onTab: ((_ backwards: Bool) -> Void)? = nil

    @State private var editText = ""
    @State private var didCancel = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("https://…", text: $editText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)
                .onSubmit { onCommit(editText) }
                .onExitCommand {
                    didCancel = true
                    onCancel()
                }
                .onTabCommit(onTab) { onCommit(editText) }
                .onAppear {
                    editText = value
                    didCancel = false
                    DispatchQueue.main.async { isFocused = true }
                }
                .onChange(of: isFocused) { _, focused in
                    guard !focused else { return }
                    if didCancel {
                        didCancel = false
                    } else {
                        onCommit(editText)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
        } else {
            Text(value.isEmpty ? "—" : value)
                .font(.callout)
                .foregroundStyle(value.isEmpty ? .quaternary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Editable Single-Select Cell

struct EditableSingleSelectCell: View {
    let value: String
    let options: [SelectOption]
    let onSelect: (String) -> Void
    var onCreateOption: ((String) -> Void)? = nil

    @State private var showPicker = false

    var body: some View {
        Group {
            if let current = options.first(where: { $0.value == value }) {
                Text(current.value)
                    .font(.callout)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .chipBackground(Color(hex: current.color))
            } else if value.isEmpty {
                Text("—")
                    .font(.callout)
                    .foregroundStyle(.quaternary)
            } else {
                Text(value)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { showPicker = true })
        .popover(isPresented: $showPicker) {
            SelectOptionPicker(
                selectedValues: value.isEmpty ? [] : [value],
                options: options,
                isSingleSelect: true,
                onCommit: { values in
                    if let selected = values.first { onSelect(selected) }
                },
                onCreateOption: onCreateOption ?? { _ in }
            )
        }
    }
}

// MARK: - Editable Multi-Select Cell

struct EditableMultiSelectCell: View {
    let selectedValues: [String]
    let options: [SelectOption]
    let onUpdate: ([String]) -> Void
    var onCreateOption: ((String) -> Void)? = nil

    @State private var showPicker = false

    var body: some View {
        Group {
            if selectedValues.isEmpty {
                Text("—")
                    .font(.callout)
                    .foregroundStyle(.quaternary)
            } else {
                HStack(spacing: 2) {
                    ForEach(selectedValues.prefix(2), id: \.self) { val in
                        if let option = options.first(where: { $0.value == val }) {
                            Text(option.value)
                                .font(.callout)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .chipBackground(Color(hex: option.color))
                        } else {
                            Text(val)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if selectedValues.count > 2 {
                        Text("+\(selectedValues.count - 2)")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { showPicker = true })
        .popover(isPresented: $showPicker) {
            SelectOptionPicker(
                selectedValues: selectedValues,
                options: options,
                onCommit: onUpdate,
                onCreateOption: onCreateOption ?? { _ in }
            )
        }
    }
}

// MARK: - Editable Checkbox Cell

struct EditableCheckboxCell: View {
    let isChecked: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        Toggle("", isOn: Binding(
            get: { isChecked },
            set: { onToggle($0) }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Editable Date Cell

struct EditableDateCell: View {
    let value: Date?
    let onCommit: (Date?) -> Void

    @State private var showPicker = false
    @State private var editDate = Date()

    var body: some View {
        Group {
            if let date = value {
                Text(date, style: .date)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.callout)
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { showPicker = true })
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

// MARK: - Default Property Dispatcher Cell

struct EditableDefaultPropertyCell: View {
    let reference: Reference
    let fieldKey: String
    let property: PropertyDefinition
    let isEditing: (String) -> Bool
    let onBeginEdit: (String) -> Void
    let onCancel: () -> Void
    let commitRef: (Reference) -> Void
    var onTab: ((_ backwards: Bool) -> Void)? = nil

    var body: some View {
        switch fieldKey {
        case "referenceType":
            EditableSingleSelectCell(
                value: reference.referenceType.rawValue,
                options: property.options,
                onSelect: { val in
                    if let type = ReferenceType(rawValue: val) {
                        var u = reference
                        u.referenceType = type
                        commitRef(u)
                    }
                }
            )
        case "year":
            EditableNumberCell(
                value: reference.year,
                isEditing: isEditing("year"),
                onBeginEdit: { onBeginEdit("year") },
                onCommit: { val in
                    var u = reference
                    u.year = val
                    commitRef(u)
                },
                onCancel: onCancel,
                onTab: onTab
            )
        case "doi":
            EditableURLCell(
                value: reference.doi ?? "",
                isEditing: isEditing("doi"),
                onBeginEdit: { onBeginEdit("doi") },
                onCommit: { val in
                    var u = reference
                    u.doi = val.isEmpty ? nil : val
                    commitRef(u)
                },
                onCancel: onCancel,
                onTab: onTab
            )
        case "url":
            EditableURLCell(
                value: reference.url ?? "",
                isEditing: isEditing("url"),
                onBeginEdit: { onBeginEdit("url") },
                onCommit: { val in
                    var u = reference
                    u.url = val.isEmpty ? nil : val
                    commitRef(u)
                },
                onCancel: onCancel,
                onTab: onTab
            )
        case "editors":
            EditableStringCell(
                value: reference.parsedEditors.displayString,
                isEditing: isEditing("editors"),
                onBeginEdit: { onBeginEdit("editors") },
                onCommit: { val in
                    var u = reference
                    u.editors = val.isEmpty ? nil : Reference.encodeNames(AuthorName.parseList(val))
                    commitRef(u)
                },
                onCancel: onCancel,
                onTab: onTab
            )
        case "translators":
            EditableStringCell(
                value: reference.parsedTranslators.displayString,
                isEditing: isEditing("translators"),
                onBeginEdit: { onBeginEdit("translators") },
                onCommit: { val in
                    var u = reference
                    u.translators = val.isEmpty ? nil : Reference.encodeNames(AuthorName.parseList(val))
                    commitRef(u)
                },
                onCancel: onCancel,
                onTab: onTab
            )
        default:
            defaultStringCell
        }
    }

    @ViewBuilder
    private var defaultStringCell: some View {
        let getter: () -> String = {
            switch fieldKey {
            case "journal": return reference.journal ?? ""
            case "volume": return reference.volume ?? ""
            case "issue": return reference.issue ?? ""
            case "pages": return reference.pages ?? ""
            case "publisher": return reference.publisher ?? ""
            case "publisherPlace": return reference.publisherPlace ?? ""
            case "edition": return reference.edition ?? ""
            case "isbn": return reference.isbn ?? ""
            case "issn": return reference.issn ?? ""
            case "accessedDate": return reference.accessedDate ?? ""
            case "eventTitle": return reference.eventTitle ?? ""
            case "eventPlace": return reference.eventPlace ?? ""
            case "genre": return reference.genre ?? ""
            case "institution": return reference.institution ?? ""
            case "number": return reference.number ?? ""
            case "collectionTitle": return reference.collectionTitle ?? ""
            case "numberOfPages": return reference.numberOfPages ?? ""
            case "language": return reference.language ?? ""
            case "pmid": return reference.pmid ?? ""
            case "pmcid": return reference.pmcid ?? ""
            default: return ""
            }
        }

        EditableStringCell(
            value: getter(),
            isEditing: isEditing(fieldKey),
            onBeginEdit: { onBeginEdit(fieldKey) },
            onCommit: { val in
                var u = reference
                let v: String? = val.isEmpty ? nil : val
                switch fieldKey {
                case "journal": u.journal = v
                case "volume": u.volume = v
                case "issue": u.issue = v
                case "pages": u.pages = v
                case "publisher": u.publisher = v
                case "publisherPlace": u.publisherPlace = v
                case "edition": u.edition = v
                case "isbn": u.isbn = v
                case "issn": u.issn = v
                case "accessedDate": u.accessedDate = v
                case "eventTitle": u.eventTitle = v
                case "eventPlace": u.eventPlace = v
                case "genre": u.genre = v
                case "institution": u.institution = v
                case "number": u.number = v
                case "collectionTitle": u.collectionTitle = v
                case "numberOfPages": u.numberOfPages = v
                case "language": u.language = v
                case "pmid": u.pmid = v
                case "pmcid": u.pmcid = v
                default: return
                }
                commitRef(u)
            },
            onCancel: onCancel,
            onTab: onTab
        )
    }
}

// MARK: - Custom Property Dispatcher Cell

struct EditableCustomPropertyCell: View {
    let referenceId: Int64
    let property: PropertyDefinition
    let rawValue: String?
    let isEditing: (String) -> Bool
    let onBeginEdit: (String) -> Void
    let onCancel: () -> Void
    let commitCustom: (Int64, Int64, String?) -> Void
    let onCreateOption: (Int64, String) -> Void
    var onTab: ((_ backwards: Bool) -> Void)? = nil

    private var propId: Int64 { property.id ?? 0 }
    private var fieldKey: String { property.customizationID }
    private var currentValue: String { rawValue ?? "" }

    var body: some View {
        switch property.type {
        case .string:
            EditableStringCell(
                value: currentValue,
                isEditing: isEditing(fieldKey),
                onBeginEdit: { onBeginEdit(fieldKey) },
                onCommit: { val in
                    commitCustom(referenceId, propId, val.isEmpty ? nil : val)
                },
                onCancel: onCancel,
                onTab: onTab
            )
        case .url:
            EditableURLCell(
                value: currentValue,
                isEditing: isEditing(fieldKey),
                onBeginEdit: { onBeginEdit(fieldKey) },
                onCommit: { val in
                    commitCustom(referenceId, propId, val.isEmpty ? nil : val)
                },
                onCancel: onCancel,
                onTab: onTab
            )
        case .number:
            EditableNumberCell(
                value: Int(currentValue),
                isEditing: isEditing(fieldKey),
                onBeginEdit: { onBeginEdit(fieldKey) },
                onCommit: { val in
                    commitCustom(referenceId, propId, val.map(String.init))
                },
                onCancel: onCancel,
                onTab: onTab
            )
        case .singleSelect:
            EditableSingleSelectCell(
                value: currentValue,
                options: property.options,
                onSelect: { val in
                    commitCustom(referenceId, propId, val)
                },
                onCreateOption: { newName in
                    onCreateOption(propId, newName)
                }
            )
        case .multiSelect:
            let selected = parseMultiSelectValues(currentValue)
            EditableMultiSelectCell(
                selectedValues: selected,
                options: property.options,
                onUpdate: { values in
                    let json = encodeMultiSelectValues(values)
                    commitCustom(referenceId, propId, json.isEmpty ? nil : json)
                },
                onCreateOption: { newName in
                    onCreateOption(propId, newName)
                }
            )
        case .checkbox:
            EditableCheckboxCell(
                isChecked: currentValue == "true",
                onToggle: { checked in
                    commitCustom(referenceId, propId, checked ? "true" : "false")
                }
            )
        case .date:
            let dateValue = ISO8601DateFormatter().date(from: currentValue)
            EditableDateCell(
                value: dateValue,
                onCommit: { date in
                    let str = date.map { ISO8601DateFormatter().string(from: $0) }
                    commitCustom(referenceId, propId, str)
                }
            )
        }
    }

    private func parseMultiSelectValues(_ raw: String) -> [String] {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    private func encodeMultiSelectValues(_ values: [String]) -> String {
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }
}
