#if os(macOS)
import SwiftUI
import RubienCore

// Apple's docs explicitly warn that `ISO8601DateFormatter` is expensive to
// create. Date-property cells are evaluated per row per body re-eval, so
// instantiating a fresh formatter inside the cell body costs tens of ms across
// the visible row set. One shared instance is fine — we only touch it from
// the main thread (SwiftUI view body, MainActor-isolated), so concurrent
// access is a non-concern for current usage. Module-internal so that
// `ReferenceDetailView`'s date-property row can reuse the same instance
// without duplicating the cache.
let cachedISO8601DateFormatter = ISO8601DateFormatter()

// MARK: - Field-specific equality helpers (cell Equatable optimization)
//
// The synthesized / manual `==` on `Reference`, `Tag`, and `PropertyDefinition`
// includes `dateModified`, which is stamped on every save. Delegating cell `==`
// to those would defeat the whole optimization — every edit invalidates every
// visible cell on that row, even cells that don't display the edited field.
//
// These helpers compare only the fields each cell body actually reads. They are
// `internal` (no access modifier) so `ReadingStatusCell` / `TagsCellView` in
// `ReferenceTableView.swift` can reuse them.

/// Compare a Reference for cell-body purposes: identity + the one field
/// indexed by `field`. Excludes `dateModified` / `verifiedAt` etc. The default
/// branch returns `false` so an unknown field forces re-render (perf miss)
/// rather than risking stale UI (correctness bug). Keep the case list synced
/// with `defaultStringCell` below and the explicit branches in
/// `EditableDefaultPropertyCell.body`.
@inline(__always)
func referenceFieldEqual(_ a: Reference, _ b: Reference, field: String) -> Bool {
    guard a.id == b.id else { return false }
    switch field {
    case "title":           return a.title == b.title
    case "authors":         return a.authorsNormalized == b.authorsNormalized
    case "year":            return a.year == b.year
    case "journal":         return a.journal == b.journal
    case "volume":          return a.volume == b.volume
    case "issue":           return a.issue == b.issue
    case "pages":           return a.pages == b.pages
    case "doi":             return a.doi == b.doi
    case "url":             return a.url == b.url
    case "abstract":        return a.abstract == b.abstract
    case "notes":           return a.notes == b.notes
    case "publisher":       return a.publisher == b.publisher
    case "publisherPlace":  return a.publisherPlace == b.publisherPlace
    case "edition":         return a.edition == b.edition
    case "editors":         return a.editors == b.editors
    case "translators":     return a.translators == b.translators
    case "isbn":            return a.isbn == b.isbn
    case "issn":            return a.issn == b.issn
    case "language":        return a.language == b.language
    case "pmid":            return a.pmid == b.pmid
    case "pmcid":           return a.pmcid == b.pmcid
    case "referenceType":   return a.referenceType == b.referenceType
    case "readingStatus":   return a.readingStatus == b.readingStatus
    case "dateAdded":       return a.dateAdded == b.dateAdded
    // Hidden-by-default reference properties that the user can reveal as
    // visible columns via `defaultStringCell` (~line 494). Without these
    // cases, the conservative `default: false` causes unnecessary re-renders
    // on those columns.
    case "accessedDate":    return a.accessedDate == b.accessedDate
    case "eventTitle":      return a.eventTitle == b.eventTitle
    case "eventPlace":      return a.eventPlace == b.eventPlace
    case "genre":           return a.genre == b.genre
    case "institution":     return a.institution == b.institution
    case "number":          return a.number == b.number
    case "collectionTitle": return a.collectionTitle == b.collectionTitle
    case "numberOfPages":   return a.numberOfPages == b.numberOfPages
    default:                return false
    }
}

/// Compare a PropertyDefinition for cell-body purposes: only the fields the
/// dispatcher cells read after the `isEditing` Bool refactor (`id`, `type`,
/// `options`). Excludes `dateModified`, `sortOrder`, `isDefault`, `isVisible`,
/// `name` (none of which affect cell rendering — `name` renders in table
/// headers, not in cell bodies). Pre-refactor, `customizationID` was read via
/// the computed `fieldKey` to dispatch closures; post-refactor that read is
/// gone (closures are pre-resolved by the parent).
@inline(__always)
func propertyDefVisuallyEqual(_ a: PropertyDefinition, _ b: PropertyDefinition) -> Bool {
    a.id == b.id && a.type == b.type && a.options == b.options
}

/// Compare a `[Tag]` list element-wise by `id`, `name`, `color`. `Tag` is
/// `Hashable` via synthesis and includes `dateModified`, which would
/// invalidate every visible tag cell on a tag-timestamp-only save. This
/// helper sidesteps that without touching the model's `==`.
@inline(__always)
func tagListVisuallyEqual(_ a: [Tag], _ b: [Tag]) -> Bool {
    guard a.count == b.count else { return false }
    for i in a.indices {
        if a[i].id != b[i].id || a[i].name != b[i].name || a[i].color != b[i].color {
            return false
        }
    }
    return true
}

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

struct EditableStringCell: View, Equatable {
    let value: String
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    var placeholder: String = "—"
    var onTab: ((_ backwards: Bool) -> Void)? = nil
    var wrap: Bool = false

    // Closures (onBeginEdit/onCommit/onCancel/onTab) are tap/commit handlers,
    // not read in body. Safe to exclude per the plan's safety invariant.
    static func == (lhs: EditableStringCell, rhs: EditableStringCell) -> Bool {
        lhs.value == rhs.value
            && lhs.isEditing == rhs.isEditing
            && lhs.placeholder == rhs.placeholder
            && lhs.wrap == rhs.wrap
    }

    @State private var editText = ""
    @State private var didCancel = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField(placeholder, text: $editText, axis: wrap ? .vertical : .horizontal)
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
                .lineLimit(wrap ? nil : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: wrap)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Editable Number Cell

struct EditableNumberCell: View, Equatable {
    let value: Int?
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCommit: (Int?) -> Void
    let onCancel: () -> Void
    var placeholder: String = "—"
    var onTab: ((_ backwards: Bool) -> Void)? = nil
    var wrap: Bool = false

    static func == (lhs: EditableNumberCell, rhs: EditableNumberCell) -> Bool {
        lhs.value == rhs.value
            && lhs.isEditing == rhs.isEditing
            && lhs.placeholder == rhs.placeholder
            && lhs.wrap == rhs.wrap
    }

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
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: false, vertical: wrap)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Editable URL Cell

struct EditableURLCell: View, Equatable {
    let value: String
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    var onTab: ((_ backwards: Bool) -> Void)? = nil
    var wrap: Bool = false

    static func == (lhs: EditableURLCell, rhs: EditableURLCell) -> Bool {
        lhs.value == rhs.value
            && lhs.isEditing == rhs.isEditing
            && lhs.wrap == rhs.wrap
    }

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
                .lineLimit(wrap ? nil : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: wrap)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Editable Single-Select Cell

struct EditableSingleSelectCell: View, Equatable {
    let value: String
    let options: [SelectOption]
    let onSelect: (String) -> Void
    var onCreateOption: ((String) -> Void)? = nil

    static func == (lhs: EditableSingleSelectCell, rhs: EditableSingleSelectCell) -> Bool {
        lhs.value == rhs.value && lhs.options == rhs.options
    }

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
                // Pass the optional through directly so callers that don't
                // provide a creation closure get a picker without the inline
                // "create" affordance — Type relies on this to lock its
                // option set (it would otherwise display "Create X" but the
                // value would be silently dropped by the rawValue guard).
                onCreateOption: onCreateOption
            )
        }
    }
}

// MARK: - Editable Multi-Select Cell

struct EditableMultiSelectCell: View, Equatable {
    let selectedValues: [String]
    let options: [SelectOption]
    let onUpdate: ([String]) -> Void
    var onCreateOption: ((String) -> Void)? = nil

    static func == (lhs: EditableMultiSelectCell, rhs: EditableMultiSelectCell) -> Bool {
        lhs.selectedValues == rhs.selectedValues && lhs.options == rhs.options
    }

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
                onCreateOption: onCreateOption
            )
        }
    }
}

// MARK: - Editable Checkbox Cell

struct EditableCheckboxCell: View, Equatable {
    let isChecked: Bool
    let onToggle: (Bool) -> Void

    static func == (lhs: EditableCheckboxCell, rhs: EditableCheckboxCell) -> Bool {
        lhs.isChecked == rhs.isChecked
    }

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

struct EditableDateCell: View, Equatable {
    let value: Date?
    let onCommit: (Date?) -> Void

    static func == (lhs: EditableDateCell, rhs: EditableDateCell) -> Bool {
        lhs.value == rhs.value
    }

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

struct EditableDefaultPropertyCell: View, Equatable {
    let reference: Reference
    let fieldKey: String
    let property: PropertyDefinition
    // Pre-resolved by the parent for this cell's one `fieldKey` so it
    // participates in `==` as an Equatable Bool. Must not be a closure read
    // inside `body` — a closure-typed input can't be compared in `==`, so
    // changes to edit-state would be silently skipped and the cell would
    // fail to enter edit mode.
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCancel: () -> Void
    let commitRef: (Reference) -> Void
    var onTab: ((_ backwards: Bool) -> Void)? = nil
    var wrap: Bool = false

    static func == (lhs: EditableDefaultPropertyCell, rhs: EditableDefaultPropertyCell) -> Bool {
        lhs.fieldKey == rhs.fieldKey
            && lhs.isEditing == rhs.isEditing
            && lhs.wrap == rhs.wrap
            && propertyDefVisuallyEqual(lhs.property, rhs.property)
            && referenceFieldEqual(lhs.reference, rhs.reference, field: lhs.fieldKey)
    }

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
            .equatable()
        case "year":
            EditableNumberCell(
                value: reference.year,
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { val in
                    var u = reference
                    u.year = val
                    commitRef(u)
                },
                onCancel: onCancel,
                onTab: onTab,
                wrap: wrap
            )
            .equatable()
        case "doi":
            EditableURLCell(
                value: reference.doi ?? "",
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { val in
                    var u = reference
                    u.doi = val.isEmpty ? nil : val
                    commitRef(u)
                },
                onCancel: onCancel,
                onTab: onTab,
                wrap: wrap
            )
            .equatable()
        case "url":
            EditableURLCell(
                value: reference.url ?? "",
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { val in
                    var u = reference
                    u.url = val.isEmpty ? nil : val
                    commitRef(u)
                },
                onCancel: onCancel,
                onTab: onTab,
                wrap: wrap
            )
            .equatable()
        case "editors":
            EditableStringCell(
                value: reference.parsedEditors.displayString,
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { val in
                    var u = reference
                    u.editors = val.isEmpty ? nil : Reference.encodeNames(AuthorName.parseList(val))
                    commitRef(u)
                },
                onCancel: onCancel,
                onTab: onTab,
                wrap: wrap
            )
            .equatable()
        case "translators":
            EditableStringCell(
                value: reference.parsedTranslators.displayString,
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { val in
                    var u = reference
                    u.translators = val.isEmpty ? nil : Reference.encodeNames(AuthorName.parseList(val))
                    commitRef(u)
                },
                onCancel: onCancel,
                onTab: onTab,
                wrap: wrap
            )
            .equatable()
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
            isEditing: isEditing,
            onBeginEdit: onBeginEdit,
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
            onTab: onTab,
            wrap: wrap
        )
        .equatable()
    }
}

// MARK: - Custom Property Dispatcher Cell

struct EditableCustomPropertyCell: View, Equatable {
    let referenceId: Int64
    let property: PropertyDefinition
    let rawValue: String?
    // Pre-resolved by the parent for this cell's `property.customizationID`.
    // Was a closure `(String) -> Bool` read inside body; now a stored Bool
    // that participates in `==`.
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCancel: () -> Void
    let commitCustom: (Int64, Int64, String?) -> Void
    let onCreateOption: (Int64, String) -> Void
    var onTab: ((_ backwards: Bool) -> Void)? = nil
    var wrap: Bool = false

    private var propId: Int64 { property.id ?? 0 }
    private var currentValue: String { rawValue ?? "" }

    static func == (lhs: EditableCustomPropertyCell, rhs: EditableCustomPropertyCell) -> Bool {
        lhs.referenceId == rhs.referenceId
            && lhs.rawValue == rhs.rawValue
            && lhs.isEditing == rhs.isEditing
            && lhs.wrap == rhs.wrap
            && propertyDefVisuallyEqual(lhs.property, rhs.property)
    }

    var body: some View {
        switch property.type {
        case .string:
            EditableStringCell(
                value: currentValue,
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { val in
                    commitCustom(referenceId, propId, val.isEmpty ? nil : val)
                },
                onCancel: onCancel,
                onTab: onTab,
                wrap: wrap
            )
            .equatable()
        case .url:
            EditableURLCell(
                value: currentValue,
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { val in
                    commitCustom(referenceId, propId, val.isEmpty ? nil : val)
                },
                onCancel: onCancel,
                onTab: onTab,
                wrap: wrap
            )
            .equatable()
        case .number:
            EditableNumberCell(
                value: Int(currentValue),
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { val in
                    commitCustom(referenceId, propId, val.map(String.init))
                },
                onCancel: onCancel,
                onTab: onTab,
                wrap: wrap
            )
            .equatable()
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
            .equatable()
        case .multiSelect:
            let selected = PropertyValue.decodeMultiSelect(currentValue)
            EditableMultiSelectCell(
                selectedValues: selected,
                options: property.options,
                onUpdate: { values in
                    let json = PropertyValue.encodeMultiSelect(values)
                    commitCustom(referenceId, propId, json.isEmpty ? nil : json)
                },
                onCreateOption: { newName in
                    onCreateOption(propId, newName)
                }
            )
            .equatable()
        case .checkbox:
            EditableCheckboxCell(
                isChecked: currentValue == "true",
                onToggle: { checked in
                    commitCustom(referenceId, propId, checked ? "true" : "false")
                }
            )
            .equatable()
        case .date:
            let dateValue = cachedISO8601DateFormatter.date(from: currentValue)
            EditableDateCell(
                value: dateValue,
                onCommit: { date in
                    let str = date.map { cachedISO8601DateFormatter.string(from: $0) }
                    commitCustom(referenceId, propId, str)
                }
            )
            .equatable()
        }
    }

}
#endif
