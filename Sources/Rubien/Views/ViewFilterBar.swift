import SwiftUI
import RubienCore

struct ViewFilterBar: View {
    @Binding var filters: [ViewFilter]
    @State private var showAddFilter = false

    var body: some View {
        if !filters.isEmpty || showAddFilter {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                ForEach(Array(filters.enumerated()), id: \.offset) { index, filter in
                    FilterPill(filter: filter) {
                        filters.remove(at: index)
                    }
                }

                Button {
                    showAddFilter = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .medium))
                        Text("Filter")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2))
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAddFilter) {
                    AddFilterPopover { newFilter in
                        filters.append(newFilter)
                        showAddFilter = false
                    }
                }

                Spacer()

                if !filters.isEmpty {
                    Button {
                        filters.removeAll()
                    } label: {
                        Text("Clear")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

private struct FilterPill: View {
    let filter: ViewFilter
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(headerLabel)
                .font(.system(size: 10, weight: .medium))
            Text(operatorLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(valueLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    private var headerLabel: String {
        switch filter.target {
        case .builtin(let id): return id.header
        case .custom:          return "Property"  // Phase 2 threads propertyDefs to resolve the real name
        }
    }

    private var operatorLabel: String {
        switch filter.op {
        case .equals:           return "is"
        case .notEquals:        return "is not"
        case .contains:         return "contains"
        case .notContains:      return "does not contain"
        case .startsWith:       return "starts with"
        case .endsWith:         return "ends with"
        case .greaterThan:      return ">"
        case .lessThan:         return "<"
        case .greaterOrEqual:   return "≥"
        case .lessOrEqual:      return "≤"
        case .isWithin:         return "is within"
        case .isAnyOf:          return "is any of"
        case .isNoneOf:         return "is none of"
        case .containsAnyOf:    return "contains any of"
        case .containsNoneOf:   return "contains none of"
        case .containsAllOf:    return "contains all of"
        case .isChecked:        return "is checked"
        case .isUnchecked:      return "is unchecked"
        case .isEmpty:          return "is empty"
        case .isNotEmpty:       return "is not empty"
        }
    }

    private var valueLabel: String {
        switch filter.value {
        case .text(let s):        return s
        case .number(let n):      return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case .date(let d):        return d.formatted(date: .abbreviated, time: .omitted)
        case .datePreset(let p):  return "\(p)"
        case .selectKeys(let ks): return ks.joined(separator: ", ")
        case .bool(let b):        return b ? "yes" : "no"
        case .none:               return ""
        }
    }
}

private struct AddFilterPopover: View {
    let onAdd: (ViewFilter) -> Void

    @State private var selectedField: ColumnIdentifier = .readingStatus
    @State private var selectedOp: FilterOperator = .equals
    @State private var value = ""

    private var filterableFields: [ColumnIdentifier] {
        [.readingStatus, .priority, .year, .journal, .referenceType, .authors, .doi, .publisher]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Filter")
                .font(.system(size: 13, weight: .semibold))

            Picker("Field", selection: $selectedField) {
                ForEach(filterableFields, id: \.self) { field in
                    Text(field.header).tag(field)
                }
            }
            .pickerStyle(.menu)

            Picker("Condition", selection: $selectedOp) {
                Text("is").tag(FilterOperator.equals)
                Text("is not").tag(FilterOperator.notEquals)
                Text("contains").tag(FilterOperator.contains)
                Text("is empty").tag(FilterOperator.isEmpty)
                Text("is not empty").tag(FilterOperator.isNotEmpty)
            }
            .pickerStyle(.menu)

            if needsValue {
                valueField
            }

            HStack {
                Spacer()
                Button("Add") {
                    onAdd(ViewFilter(target: .builtin(selectedField), op: selectedOp, value: buildFilterValue()))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(needsValue && value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private var needsValue: Bool {
        selectedOp != .isEmpty && selectedOp != .isNotEmpty
    }

    private func buildFilterValue() -> FilterValue {
        guard needsValue else { return .none }
        switch selectedField {
        case .year:
            return .number(Double(value) ?? 0)
        case .readingStatus, .priority, .referenceType:
            return .selectKeys([value])
        default:
            return .text(value)
        }
    }

    @ViewBuilder
    private var valueField: some View {
        switch selectedField {
        case .readingStatus:
            Picker("Value", selection: $value) {
                ForEach(ReadingStatus.allCases, id: \.rawValue) { status in
                    Text(status.label).tag(status.rawValue)
                }
            }
            .pickerStyle(.menu)
            .onAppear { if value.isEmpty { value = ReadingStatus.unread.rawValue } }
        case .priority:
            Picker("Value", selection: $value) {
                ForEach(Priority.allCases, id: \.rawValue) { p in
                    Text(p.label).tag(String(p.rawValue))
                }
            }
            .pickerStyle(.menu)
            .onAppear { if value.isEmpty { value = String(Priority.none.rawValue) } }
        default:
            TextField("Value", text: $value)
                .textFieldStyle(.roundedBorder)
        }
    }
}
