import Foundation

public enum FilterValue: Hashable, Sendable {
    case text(String)
    case number(Double)
    case date(Date)
    case datePreset(DatePreset)
    case selectKeys([String])
    case bool(Bool)
    /// Carries no payload — used by `isEmpty`/`isNotEmpty`/`isChecked`/`isUnchecked`.
    case none
}

extension FilterValue: Codable {
    // Custom Codable: see FieldTarget.swift for the rationale.
    private enum Kind: String, Codable {
        case text, number, date, datePreset, selectKeys, bool, none
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(s, forKey: .value)
        case .number(let n):
            try container.encode(Kind.number, forKey: .kind)
            try container.encode(n, forKey: .value)
        case .date(let d):
            try container.encode(Kind.date, forKey: .kind)
            try container.encode(d, forKey: .value)
        case .datePreset(let preset):
            try container.encode(Kind.datePreset, forKey: .kind)
            try container.encode(preset, forKey: .value)
        case .selectKeys(let keys):
            try container.encode(Kind.selectKeys, forKey: .kind)
            try container.encode(keys, forKey: .value)
        case .bool(let b):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(b, forKey: .value)
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:       self = .text(try container.decode(String.self, forKey: .value))
        case .number:     self = .number(try container.decode(Double.self, forKey: .value))
        case .date:       self = .date(try container.decode(Date.self, forKey: .value))
        case .datePreset: self = .datePreset(try container.decode(DatePreset.self, forKey: .value))
        case .selectKeys: self = .selectKeys(try container.decode([String].self, forKey: .value))
        case .bool:       self = .bool(try container.decode(Bool.self, forKey: .value))
        case .none:       self = .none
        }
    }
}

public enum DatePreset: Hashable, Sendable {
    case today, yesterday, tomorrow
    case thisWeek, thisMonth, thisYear
    case nextWeek, nextMonth
    case lastNDays(Int)
    case nextNDays(Int)
}

extension DatePreset: Codable {
    private enum PresetKind: String, Codable {
        case today, yesterday, tomorrow
        case thisWeek, thisMonth, thisYear
        case nextWeek, nextMonth
        case lastNDays, nextNDays
    }

    private enum CodingKeys: String, CodingKey {
        case preset, n
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .today:     try container.encode(PresetKind.today, forKey: .preset)
        case .yesterday: try container.encode(PresetKind.yesterday, forKey: .preset)
        case .tomorrow:  try container.encode(PresetKind.tomorrow, forKey: .preset)
        case .thisWeek:  try container.encode(PresetKind.thisWeek, forKey: .preset)
        case .thisMonth: try container.encode(PresetKind.thisMonth, forKey: .preset)
        case .thisYear:  try container.encode(PresetKind.thisYear, forKey: .preset)
        case .nextWeek:  try container.encode(PresetKind.nextWeek, forKey: .preset)
        case .nextMonth: try container.encode(PresetKind.nextMonth, forKey: .preset)
        case .lastNDays(let n):
            try container.encode(PresetKind.lastNDays, forKey: .preset)
            try container.encode(n, forKey: .n)
        case .nextNDays(let n):
            try container.encode(PresetKind.nextNDays, forKey: .preset)
            try container.encode(n, forKey: .n)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let preset = try container.decode(PresetKind.self, forKey: .preset)
        switch preset {
        case .today:     self = .today
        case .yesterday: self = .yesterday
        case .tomorrow:  self = .tomorrow
        case .thisWeek:  self = .thisWeek
        case .thisMonth: self = .thisMonth
        case .thisYear:  self = .thisYear
        case .nextWeek:  self = .nextWeek
        case .nextMonth: self = .nextMonth
        case .lastNDays:
            let n = try container.decode(Int.self, forKey: .n)
            self = .lastNDays(n)
        case .nextNDays:
            let n = try container.decode(Int.self, forKey: .n)
            self = .nextNDays(n)
        }
    }
}
