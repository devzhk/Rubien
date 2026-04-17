import Foundation

extension FieldTarget {
    public func displayLabel(propertyDefs: [PropertyDefinition]) -> String {
        switch self {
        case .builtin(let column): return column.header
        case .custom(let id):      return propertyDefs.first(where: { $0.id == id })?.name ?? "Property"
        }
    }
}

extension FilterValue {
    public var displayLabel: String {
        switch self {
        case .text(let s):         return s
        case .number(let n):       return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case .date(let d):         return d.formatted(date: .abbreviated, time: .omitted)
        case .datePreset(let p):   return p.label
        case .selectKeys(let ks):  return ks.joined(separator: ", ")
        case .bool(let b):         return b ? "yes" : "no"
        case .none:                return ""
        }
    }
}
