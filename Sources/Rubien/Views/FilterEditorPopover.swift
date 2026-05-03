import SwiftUI
import RubienCore

struct FilterEditorPopover: View {
    let initial: ViewFilter?
    let tags: [Tag]
    let propertyDefs: [PropertyDefinition]
    let onCommit: (ViewFilter) -> Void
    let onCancel: () -> Void

    @State private var target: FieldTarget
    @State private var op: FilterOperator
    @State private var value: FilterValue
    /// Raw string for the numeric editor. Separate from `value` so we can
    /// distinguish "untouched" from "user typed 0".
    @State private var numberInput: String

    init(
        initial: ViewFilter? = nil,
        tags: [Tag] = [],
        propertyDefs: [PropertyDefinition] = [],
        onCommit: @escaping (ViewFilter) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initial = initial
        self.tags = tags
        self.propertyDefs = propertyDefs
        self.onCommit = onCommit
        self.onCancel = onCancel
        let defaults = Self.defaults(for: initial, propertyDefs: propertyDefs)
        _target = State(initialValue: defaults.target)
        _op = State(initialValue: defaults.op)
        _value = State(initialValue: defaults.value)
        _numberInput = State(initialValue: Self.initialNumberInput(for: initial))
    }

    private static func initialNumberInput(for initial: ViewFilter?) -> String {
        guard case .number(let n) = initial?.value else { return "" }
        return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(initial == nil ? "Add Filter" : "Edit Filter")
                .font(.system(size: 13, weight: .semibold))

            targetPicker
            operatorPicker

            if !isValueEditorHidden {
                valueEditor
            }

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(initial == nil ? "Add" : "Save") {
                    onCommit(ViewFilter(target: target, op: op, value: value))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isCommitEnabled)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - Target picker

    private var targetPicker: some View {
        let options = FieldTarget.selectableOptions(propertyDefs: propertyDefs)
        return Picker("Field", selection: Binding(
            get: { target },
            set: { newTarget in
                target = newTarget
                let kind = newTarget.valueKind(propertyDefs: propertyDefs)
                op = FilterOperator.allowed(for: kind).first ?? .equals
                value = defaultValue(for: op, kind: kind)
                numberInput = ""
            }
        )) {
            ForEach(options, id: \.self) { entry in
                Text(entry.label).tag(entry.target)
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: - Operator picker

    private var operatorPicker: some View {
        let kind = target.valueKind(propertyDefs: propertyDefs)
        let allowed = FilterOperator.allowed(for: kind)
        return Picker("Condition", selection: Binding(
            get: { op },
            set: { newOp in
                op = newOp
                value = defaultValue(for: newOp, kind: kind)
                numberInput = ""
            }
        )) {
            ForEach(allowed, id: \.self) { opCase in
                Text(opCase.label).tag(opCase)
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: - Value editor

    private var isValueEditorHidden: Bool {
        switch op {
        case .isEmpty, .isNotEmpty, .isChecked, .isUnchecked: return true
        default: return false
        }
    }

    private var isCommitEnabled: Bool {
        switch value {
        case .text(let s):        return !s.trimmingCharacters(in: .whitespaces).isEmpty
        case .number:             return Double(numberInput) != nil
        case .date:               return true
        case .datePreset:         return true
        case .selectKeys(let ks): return !ks.isEmpty
        case .bool:               return true
        case .none:               return true
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        let kind = target.valueKind(propertyDefs: propertyDefs)
        switch (kind, op) {
        case (.date, .isWithin):
            datePresetPicker
        case (.date, _):
            datePicker
        case (.number, _):
            numberField
        case (.singleSelect, .isAnyOf), (.singleSelect, .isNoneOf):
            selectOptionsList(allowMultiple: true)
        case (.singleSelect, _):
            selectOptionsList(allowMultiple: false)
        case (.multiSelect, .contains), (.multiSelect, .notContains):
            selectOptionsList(allowMultiple: false)
        case (.multiSelect, _):
            selectOptionsList(allowMultiple: true)
        default:
            textField
        }
    }

    private var textField: some View {
        TextField("Value", text: Binding(
            get: {
                if case .text(let s) = value { return s }
                return ""
            },
            set: { value = .text($0) }
        ))
        .textFieldStyle(.roundedBorder)
    }

    private var numberField: some View {
        TextField("Number", text: $numberInput)
            .textFieldStyle(.roundedBorder)
            .onChange(of: numberInput) { _, new in
                if let n = Double(new) {
                    value = .number(n)
                }
            }
    }

    private var datePicker: some View {
        DatePicker(
            "Date",
            selection: Binding(
                get: {
                    if case .date(let d) = value { return d }
                    return Date()
                },
                set: { value = .date($0) }
            ),
            displayedComponents: [.date]
        )
        .datePickerStyle(.compact)
    }

    private var datePresetPicker: some View {
        Picker("Preset", selection: Binding(
            get: {
                if case .datePreset(let p) = value { return p }
                return DatePreset.thisWeek
            },
            set: { value = .datePreset($0) }
        )) {
            Text("Today").tag(DatePreset.today)
            Text("Yesterday").tag(DatePreset.yesterday)
            Text("Tomorrow").tag(DatePreset.tomorrow)
            Divider()
            Text("This week").tag(DatePreset.thisWeek)
            Text("This month").tag(DatePreset.thisMonth)
            Text("This year").tag(DatePreset.thisYear)
            Divider()
            Text("Next week").tag(DatePreset.nextWeek)
            Text("Next month").tag(DatePreset.nextMonth)
            Divider()
            Text("Last 7 days").tag(DatePreset.lastNDays(7))
            Text("Last 30 days").tag(DatePreset.lastNDays(30))
            Text("Next 7 days").tag(DatePreset.nextNDays(7))
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private func selectOptionsList(allowMultiple: Bool) -> some View {
        let options = selectOptions(for: target)
        let selected: Set<String> = {
            if case .selectKeys(let keys) = value { return Set(keys) }
            return []
        }()
        ScrollView {
            FlowLayout(spacing: 6) {
                ForEach(options, id: \.key) { option in
                    let isSelected = selected.contains(option.key)
                    Button {
                        var updated = selected
                        if allowMultiple {
                            if isSelected { updated.remove(option.key) } else { updated.insert(option.key) }
                        } else {
                            updated = isSelected ? [] : [option.key]
                        }
                        value = .selectKeys(Array(updated).sorted())
                    } label: {
                        Text(option.label)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .chipBackground(isSelected ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 160)
    }

    // MARK: - Option resolution

    private func selectOptions(for target: FieldTarget) -> [(key: String, label: String)] {
        switch target {
        case .builtin(.readingStatus):
            // Status is user-extensible: pull options from the live Status
            // PropertyDefinition. Falls back to the 4 built-ins if missing.
            if let def = propertyDefs.first(forFieldKey: PropertyDefinition.readingStatusFieldKey) {
                return def.options.map { (key: $0.value, label: $0.value) }
            }
            return ReadingStatus.builtIn.map { (key: $0, label: $0) }
        case .builtin(.referenceType):
            return ReferenceType.allCases.map { (key: $0.rawValue, label: $0.rawValue) }
        case .builtin(.tags):
            return tags.compactMap { tag in
                guard let id = tag.id else { return nil }
                return (key: String(id), label: tag.name)
            }
        case .custom(let id):
            guard let def = propertyDefs.first(where: { $0.id == id }) else { return [] }
            return def.options.map { (key: $0.value, label: $0.value) }
        default:
            return []
        }
    }

    // MARK: - Defaults

    private static func defaults(
        for initial: ViewFilter?,
        propertyDefs: [PropertyDefinition]
    ) -> (target: FieldTarget, op: FilterOperator, value: FilterValue) {
        if let initial {
            return (initial.target, initial.op, initial.value)
        }
        let target = FieldTarget.builtin(.title)
        let kind = target.valueKind(propertyDefs: propertyDefs)
        let op = FilterOperator.allowed(for: kind).first ?? .equals
        return (target, op, defaultValueStatic(for: op, kind: kind))
    }

    private func defaultValue(for op: FilterOperator, kind: FieldValueKind) -> FilterValue {
        Self.defaultValueStatic(for: op, kind: kind)
    }

    private static func defaultValueStatic(for op: FilterOperator, kind: FieldValueKind) -> FilterValue {
        switch op {
        case .isEmpty, .isNotEmpty, .isChecked, .isUnchecked:
            return .none
        case .isWithin:
            return .datePreset(.thisWeek)
        default:
            switch kind {
            case .text:         return .text("")
            case .number:       return .number(0)
            case .date:         return .date(Date())
            case .singleSelect: return .selectKeys([])
            case .multiSelect:  return .selectKeys([])
            case .checkbox:     return .none
            }
        }
    }
}

