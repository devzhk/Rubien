import Foundation

/// Helpers for keeping saved and in-memory view configuration aligned when a
/// select option's string identity changes. Tags are intentionally excluded:
/// tag filters/grouping persist the stable stringified tag id, not its name.
public extension ViewFilter {
    @discardableResult
    mutating func renameOptionReference(
        target expectedTarget: FieldTarget,
        from oldValue: String,
        to newValue: String
    ) -> Bool {
        guard target == expectedTarget,
              case .selectKeys(let keys) = value,
              keys.contains(oldValue)
        else { return false }
        value = .selectKeys(keys.map { $0 == oldValue ? newValue : $0 })
        return true
    }
}

public extension GroupConfig {
    @discardableResult
    mutating func renameOptionReference(
        target expectedTarget: FieldTarget,
        from oldValue: String,
        to newValue: String
    ) -> Bool {
        guard target == expectedTarget else { return false }
        var changed = false
        if let customOrder, customOrder.contains(oldValue) {
            self.customOrder = customOrder.map { $0 == oldValue ? newValue : $0 }
            changed = true
        }
        if collapsed.remove(oldValue) != nil {
            collapsed.insert(newValue)
            changed = true
        }
        return changed
    }
}

public extension DatabaseView {
    @discardableResult
    mutating func renameOptionReferences(
        target: FieldTarget,
        from oldValue: String,
        to newValue: String
    ) -> Bool {
        var filters = parsedFilters
        var changed = false
        for index in filters.indices {
            if filters[index].renameOptionReference(
                target: target,
                from: oldValue,
                to: newValue
            ) {
                changed = true
            }
        }
        if changed { parsedFilters = filters }

        if var groupBy = parsedGroupBy,
           groupBy.renameOptionReference(
               target: target,
               from: oldValue,
               to: newValue
           ) {
            parsedGroupBy = groupBy
            changed = true
        }
        return changed
    }
}
