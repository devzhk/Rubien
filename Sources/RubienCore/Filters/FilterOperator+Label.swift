import Foundation

extension FilterOperator {
    public var label: String {
        switch self {
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
}

extension DatePreset {
    public var label: String {
        switch self {
        case .today:             return "today"
        case .yesterday:         return "yesterday"
        case .tomorrow:          return "tomorrow"
        case .thisWeek:          return "this week"
        case .thisMonth:         return "this month"
        case .thisYear:          return "this year"
        case .nextWeek:          return "next week"
        case .nextMonth:         return "next month"
        case .lastNDays(let n):  return "last \(n) days"
        case .nextNDays(let n):  return "next \(n) days"
        }
    }
}
