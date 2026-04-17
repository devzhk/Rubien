import Foundation

public struct GroupConfig: Codable, Hashable, Sendable {
    public var target: FieldTarget
    /// Only applied when `target` resolves to a date-typed column. Ignored otherwise.
    public var dateBin: DateBin?
    /// `nil` = natural order. Otherwise drag-reordered group keys.
    public var customOrder: [String]?
    /// Group keys stored as strings so all key types (tag id, enum raw value,
    /// date bucket label) fit one shape.
    public var collapsed: Set<String>
    /// Only meaningful for single-select with a known option universe.
    public var showEmpty: Bool

    public init(
        target: FieldTarget,
        dateBin: DateBin? = nil,
        customOrder: [String]? = nil,
        collapsed: Set<String> = [],
        showEmpty: Bool = false
    ) {
        self.target = target
        self.dateBin = dateBin
        self.customOrder = customOrder
        self.collapsed = collapsed
        self.showEmpty = showEmpty
    }
}

public enum DateBin: String, Codable, Hashable, Sendable {
    case week, month, year
}
