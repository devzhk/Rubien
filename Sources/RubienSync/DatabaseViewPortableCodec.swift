#if canImport(CloudKit)
import CloudKit
import Foundation
import GRDB
import RubienCore

/// Translates the local integer identities embedded in DatabaseView JSON to
/// globally stable sync identities for CloudKit, and back again on pull. The
/// SQLite/UI model deliberately remains unchanged.
enum DatabaseViewPortableCodec {
    enum Resolution: Equatable {
        case ready
        case unresolved
        case invalid
    }

    struct Projection {
        let scope: String
        let filters: String
        let sorts: String
        let groupBy: String?
        let columnWraps: String
        let legacyScope: String?
        let legacyFilters: String?
        let legacySorts: String?
        let legacyGroupBy: String?
        let legacyColumnWraps: String?

        var legacyIsLossless: Bool { legacyScope != nil }
    }

    private enum CodecError: Error {
        case invalid
        case unresolved
    }

    private enum SourceIdentity {
        case local(Int64)
        case sync(String)
    }

    private struct PortableScope: Codable {
        let kind: String
        let value: String?
    }

    private struct PortableFieldTarget: Codable {
        let kind: String
        let value: String
    }

    private struct PortableFilter: Codable {
        var target: PortableFieldTarget
        var op: FilterOperator
        var value: FilterValue
    }

    private struct PortableSort: Codable {
        var target: PortableFieldTarget
        var ascending: Bool
    }

    private struct PortableGroup: Codable {
        var target: PortableFieldTarget
        var dateBin: DateBin?
        var customOrder: [String]?
        var collapsed: Set<String>
        var showEmpty: Bool
    }

    private struct EncoderContext {
        let db: Database
        var legacyIsLossless = true

        mutating func syncId(table: String, localId: Int64) throws -> String {
            guard let value = try String.fetchOne(
                db,
                sql: "SELECT syncId FROM \(table) WHERE id = ? LIMIT 1",
                arguments: [localId]
            ), !value.isEmpty else { throw CodecError.invalid }
            if !SyncIdentifier.isCanonicalDecimal(value) {
                legacyIsLossless = false
            }
            return value
        }

        mutating func portableTarget(
            _ target: FieldTarget
        ) throws -> PortableFieldTarget {
            switch target {
            case .builtin(let column):
                return .init(kind: "builtin", value: column.rawValue)
            case .custom(let localId):
                return .init(
                    kind: "custom",
                    value: try syncId(
                        table: "propertyDefinition",
                        localId: localId
                    )
                )
            }
        }

        mutating func legacyTarget(_ target: FieldTarget) throws -> FieldTarget {
            switch target {
            case .builtin:
                return target
            case .custom(let localId):
                let syncId = try syncId(
                    table: "propertyDefinition",
                    localId: localId
                )
                guard let legacy = Int64(syncId),
                      String(legacy) == syncId else {
                    legacyIsLossless = false
                    return target
                }
                return .custom(legacy)
            }
        }

        mutating func tagKeys(_ keys: [String]) throws -> [String] {
            try keys.map { key in
                guard let localId = Int64(key), String(localId) == key else {
                    return key
                }
                return try syncId(table: "tag", localId: localId)
            }
        }

        mutating func filterValue(
            _ value: FilterValue,
            target: FieldTarget
        ) throws -> FilterValue {
            guard try DatabaseViewPortableCodec.targetUsesTags(
                target,
                db: db
            ),
                  case .selectKeys(let keys) = value else { return value }
            return .selectKeys(try tagKeys(keys))
        }

        mutating func wrapKey(_ key: String) throws -> String {
            guard key.hasPrefix("custom_"),
                  let localId = Int64(key.dropFirst("custom_".count))
            else { return key }
            return "custom_\(try syncId(table: "propertyDefinition", localId: localId))"
        }
    }

    static func projection(
        for view: DatabaseView,
        db: Database
    ) throws -> Projection {
        var context = EncoderContext(db: db)

        let localScope = try decode(view.scopeJSON, as: ViewScope.self)
        let portableScope: PortableScope
        let legacyScope: ViewScope
        switch localScope {
        case .all:
            portableScope = .init(kind: "all", value: nil)
            legacyScope = .all
        case .tag(let localId):
            let syncId = try context.syncId(table: "tag", localId: localId)
            portableScope = .init(kind: "tag", value: syncId)
            legacyScope = SyncIdentifier.isCanonicalDecimal(syncId)
                ? .tag(Int64(syncId)!) : .tag(localId)
        }

        let localFilters = try decode(view.filtersJSON, as: [ViewFilter].self)
        var portableFilters: [PortableFilter] = []
        var legacyFilters: [ViewFilter] = []
        for filter in localFilters {
            let portableValue = try context.filterValue(
                filter.value,
                target: filter.target
            )
            let legacyTarget = try context.legacyTarget(filter.target)
            let legacyValue = try context.filterValue(
                filter.value,
                target: filter.target
            )
            portableFilters.append(.init(
                target: try context.portableTarget(filter.target),
                op: filter.op,
                value: portableValue
            ))
            legacyFilters.append(.init(
                target: legacyTarget,
                op: filter.op,
                value: legacyValue
            ))
        }

        let localSorts = try decode(view.sortsJSON, as: [ViewSort].self)
        var portableSorts: [PortableSort] = []
        var legacySorts: [ViewSort] = []
        for sort in localSorts {
            portableSorts.append(.init(
                target: try context.portableTarget(sort.target),
                ascending: sort.ascending
            ))
            legacySorts.append(.init(
                target: try context.legacyTarget(sort.target),
                ascending: sort.ascending
            ))
        }

        let portableGroup: PortableGroup?
        let legacyGroup: GroupConfig?
        if let groupJSON = view.groupByJSON {
            let group = try decode(groupJSON, as: GroupConfig.self)
            let usesTags = try targetUsesTags(group.target, db: db)
            let portableOrder = usesTags
                ? try group.customOrder.map { try context.tagKeys($0) }
                : group.customOrder
            let portableCollapsed = usesTags
                ? Set(try context.tagKeys(Array(group.collapsed)))
                : group.collapsed
            portableGroup = .init(
                target: try context.portableTarget(group.target),
                dateBin: group.dateBin,
                customOrder: portableOrder,
                collapsed: portableCollapsed,
                showEmpty: group.showEmpty
            )
            legacyGroup = .init(
                target: try context.legacyTarget(group.target),
                dateBin: group.dateBin,
                customOrder: portableOrder,
                collapsed: portableCollapsed,
                showEmpty: group.showEmpty
            )
        } else {
            portableGroup = nil
            legacyGroup = nil
        }

        let wraps = try decode(view.columnWrapsJSON, as: [String].self)
        let portableWraps = try wraps.map { try context.wrapKey($0) }.sorted()

        let lossless = context.legacyIsLossless
        return Projection(
            scope: try encode(portableScope),
            filters: try encode(portableFilters),
            sorts: try encode(portableSorts),
            groupBy: try portableGroup.map(encode),
            columnWraps: try encode(portableWraps),
            legacyScope: lossless ? try encode(legacyScope) : nil,
            legacyFilters: lossless ? try encode(legacyFilters) : nil,
            legacySorts: lossless ? try encode(legacySorts) : nil,
            legacyGroupBy: lossless ? try legacyGroup.map(encode) : nil,
            legacyColumnWraps: lossless ? try encode(portableWraps) : nil
        )
    }

    static func resolve(
        record: CKRecord,
        into view: inout DatabaseView,
        db: Database
    ) -> Resolution {
        do {
            view.scopeJSON = try resolveScope(record: record, db: db)
            view.filtersJSON = try resolveFilters(record: record, db: db)
            view.sortsJSON = try resolveSorts(record: record, db: db)
            view.groupByJSON = try resolveGroup(record: record, db: db)
            view.columnWrapsJSON = try resolveWraps(record: record, db: db)
            return .ready
        } catch CodecError.unresolved {
            return .unresolved
        } catch {
            return .invalid
        }
    }

    private static func resolveScope(record: CKRecord, db: Database) throws -> String {
        if let json = record[DatabaseView.RecordField.scopeSyncJSON] as? String {
            let portable = try decode(json, as: PortableScope.self)
            switch portable.kind {
            case "all": return try encode(ViewScope.all)
            case "tag":
                guard let syncId = portable.value else { throw CodecError.invalid }
                return try encode(ViewScope.tag(try localId(
                    table: "tag", syncId: syncId, db: db
                )))
            default: throw CodecError.invalid
            }
        }
        let fallbackScope = try encode(ViewScope.all)
        let legacyJSON = (record[DatabaseView.RecordField.scopeJSON] as? String)
            ?? fallbackScope
        let legacy = try decode(legacyJSON, as: ViewScope.self)
        switch legacy {
        case .all: return legacyJSON
        case .tag(let id):
            return try encode(ViewScope.tag(try localId(
                table: "tag", syncId: String(id), db: db
            )))
        }
    }

    private static func resolveFilters(record: CKRecord, db: Database) throws -> String {
        if let json = record[DatabaseView.RecordField.filtersSyncJSON] as? String {
            let filters = try decode(json, as: [PortableFilter].self)
            return try encode(filters.map { filter in
                let target = try localTarget(filter.target, db: db)
                return ViewFilter(
                    target: target,
                    op: filter.op,
                    value: try localFilterValue(
                        filter.value,
                        target: target,
                        db: db
                    )
                )
            })
        }
        let json = (record[DatabaseView.RecordField.filtersJSON] as? String) ?? "[]"
        let filters = try decode(json, as: [ViewFilter].self)
        return try encode(filters.map { filter in
            let target = try localTarget(fromLegacy: filter.target, db: db)
            return ViewFilter(
                target: target,
                op: filter.op,
                value: try localFilterValue(
                    filter.value,
                    target: target,
                    legacy: true,
                    db: db
                )
            )
        })
    }

    private static func resolveSorts(record: CKRecord, db: Database) throws -> String {
        if let json = record[DatabaseView.RecordField.sortsSyncJSON] as? String {
            let sorts = try decode(json, as: [PortableSort].self)
            return try encode(sorts.map {
                ViewSort(
                    target: try localTarget($0.target, db: db),
                    ascending: $0.ascending
                )
            })
        }
        let json = (record[DatabaseView.RecordField.sortsJSON] as? String) ?? "[]"
        let sorts = try decode(json, as: [ViewSort].self)
        return try encode(sorts.map {
            ViewSort(
                target: try localTarget(fromLegacy: $0.target, db: db),
                ascending: $0.ascending
            )
        })
    }

    private static func resolveGroup(record: CKRecord, db: Database) throws -> String? {
        if let json = record[DatabaseView.RecordField.groupBySyncJSON] as? String {
            let group = try decode(json, as: PortableGroup.self)
            let target = try localTarget(group.target, db: db)
            let usesTags = try targetUsesTags(target, db: db)
            return try encode(GroupConfig(
                target: target,
                dateBin: group.dateBin,
                customOrder: usesTags ? try group.customOrder.map {
                    try localTagKeys($0, db: db)
                } : group.customOrder,
                collapsed: usesTags
                    ? Set(try localTagKeys(Array(group.collapsed), db: db))
                    : group.collapsed,
                showEmpty: group.showEmpty
            ))
        }
        guard let json = record[DatabaseView.RecordField.groupByJSON] as? String else {
            return nil
        }
        let group = try decode(json, as: GroupConfig.self)
        let target = try localTarget(fromLegacy: group.target, db: db)
        let usesTags = try targetUsesTags(target, db: db)
        return try encode(GroupConfig(
            target: target,
            dateBin: group.dateBin,
            customOrder: usesTags ? try group.customOrder.map {
                try localTagKeys($0, legacy: true, db: db)
            } : group.customOrder,
            collapsed: usesTags
                ? Set(try localTagKeys(Array(group.collapsed), legacy: true, db: db))
                : group.collapsed,
            showEmpty: group.showEmpty
        ))
    }

    private static func resolveWraps(record: CKRecord, db: Database) throws -> String {
        let portable = record[DatabaseView.RecordField.columnWrapsSyncJSON] as? String
        let json = portable
            ?? (record[DatabaseView.RecordField.columnWrapsJSON] as? String)
            ?? "[]"
        let keys = try decode(json, as: [String].self)
        return try encode(keys.map { key in
            guard key.hasPrefix("custom_") else { return key }
            let raw = String(key.dropFirst("custom_".count))
            let syncId: String
            if portable != nil {
                syncId = raw
            } else {
                guard SyncIdentifier.isCanonicalDecimal(raw) else {
                    throw CodecError.invalid
                }
                syncId = raw
            }
            let id = try localId(
                table: "propertyDefinition",
                syncId: syncId,
                db: db
            )
            return "custom_\(id)"
        }.sorted())
    }

    private static func localTarget(
        _ target: PortableFieldTarget,
        db: Database
    ) throws -> FieldTarget {
        switch target.kind {
        case "builtin":
            guard let column = ColumnIdentifier(rawValue: target.value) else {
                throw CodecError.invalid
            }
            return .builtin(column)
        case "custom":
            return .custom(try localId(
                table: "propertyDefinition",
                syncId: target.value,
                db: db
            ))
        default:
            throw CodecError.invalid
        }
    }

    private static func localTarget(
        fromLegacy target: FieldTarget,
        db: Database
    ) throws -> FieldTarget {
        switch target {
        case .builtin:
            return target
        case .custom(let legacyId):
            return .custom(try localId(
                table: "propertyDefinition",
                syncId: String(legacyId),
                db: db
            ))
        }
    }

    private static func targetUsesTags(
        _ target: FieldTarget,
        db: Database
    ) throws -> Bool {
        switch target {
        case .builtin(let column):
            return column == .tags
        case .custom(let id):
            return try String.fetchOne(db, sql: """
                SELECT defaultFieldKey FROM propertyDefinition
                WHERE id = ? LIMIT 1
                """, arguments: [id]) == PropertyDefinition.tagsFieldKey
        }
    }

    private static func localFilterValue(
        _ value: FilterValue,
        target: FieldTarget,
        legacy: Bool = false,
        db: Database
    ) throws -> FilterValue {
        guard try targetUsesTags(target, db: db),
              case .selectKeys(let keys) = value else { return value }
        return .selectKeys(try localTagKeys(keys, legacy: legacy, db: db))
    }

    private static func localTagKeys(
        _ keys: [String],
        legacy: Bool = false,
        db: Database
    ) throws -> [String] {
        try keys.map { key in
            if !legacy,
               !SyncIdentifier.isCanonicalDecimal(key),
               UUID(uuidString: key) == nil
            {
                // Non-identity sentinel group keys remain verbatim.
                return key
            }
            return String(try localId(table: "tag", syncId: key, db: db))
        }
    }

    private static func localId(
        table: String,
        syncId: String,
        db: Database
    ) throws -> Int64 {
        guard let type = SyncEntityType(rawValue: table) else {
            throw CodecError.invalid
        }
        let canonical = try SyncIdentityAliasStore.resolve(
            entityType: type,
            identity: syncId,
            db: db
        )
        guard let id = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM \(table) WHERE syncId = ? LIMIT 1",
            arguments: [canonical]
        ) else { throw CodecError.unresolved }
        return id
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodecError.invalid
        }
        return string
    }

    private static func decode<T: Decodable>(
        _ string: String,
        as type: T.Type
    ) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw CodecError.invalid
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CodecError.invalid
        }
    }
}
#endif
