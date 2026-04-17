import Foundation

extension FilterOperator {
    public static func allowed(for kind: FieldValueKind) -> [FilterOperator] {
        switch kind {
        case .text:
            return [.equals, .notEquals, .contains, .notContains, .startsWith, .endsWith, .isEmpty, .isNotEmpty]
        case .number:
            return [.equals, .notEquals, .greaterThan, .lessThan, .greaterOrEqual, .lessOrEqual, .isEmpty, .isNotEmpty]
        case .date:
            return [.equals, .notEquals, .greaterThan, .lessThan, .greaterOrEqual, .lessOrEqual, .isWithin, .isEmpty, .isNotEmpty]
        case .singleSelect:
            return [.equals, .notEquals, .isAnyOf, .isNoneOf, .isEmpty, .isNotEmpty]
        case .multiSelect:
            return [.contains, .notContains, .containsAnyOf, .containsNoneOf, .containsAllOf, .isEmpty, .isNotEmpty]
        case .checkbox:
            return [.isChecked, .isUnchecked]
        }
    }
}
