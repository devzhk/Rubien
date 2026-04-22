import Foundation
import CloudKit
import RubienCore

/// `PropertyDefinition` ↔ `CKRecord` mapping.
///
/// Local seeds (Type, Status, Tags, …) all land here too. Post A-pks, seeded
/// rows get deterministic UUIDv5s keyed on `defaultFieldKey`, so both devices
/// agree on recordName without needing special-case handling.
extension PropertyDefinition {

    public enum RecordField {
        public static let name             = "name"
        public static let type             = "type"
        public static let optionsJSON      = "optionsJSON"
        public static let sortOrder        = "sortOrder"
        public static let isDefault        = "isDefault"
        public static let defaultFieldKey  = "defaultFieldKey"
        public static let isVisible        = "isVisible"
    }

    public func populate(record: CKRecord) {
        record[RecordField.name]            = name
        record[RecordField.type]            = type.rawValue
        record[RecordField.optionsJSON]     = optionsJSON
        record[RecordField.sortOrder]       = Int64(sortOrder)
        record[RecordField.isDefault]       = isDefault ? Int64(1) : Int64(0)
        record[RecordField.defaultFieldKey] = defaultFieldKey
        record[RecordField.isVisible]       = isVisible ? Int64(1) : Int64(0)
    }

    public static func makeRecord(
        recordName: String,
        definition: PropertyDefinition
    ) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(
            recordType: SyncConstants.RecordType.propertyDefinition,
            recordID: id
        )
        definition.populate(record: record)
        return record
    }

    /// Non-failable decode. Missing name falls back to "" (schema has UNIQUE
    /// constraint — caller should skip blank-name decodes). Unknown
    /// `PropertyType` rawValues fall back to `.string` per forward-compat
    /// guidance (e.g. a future peer introduces `.rating` — we shouldn't
    /// crash, just treat it as text until we ship an understanding of it).
    public init(record: CKRecord) {
        let type = (record[RecordField.type] as? String)
            .flatMap(PropertyType.init(rawValue:)) ?? .string

        self.init(
            name: (record[RecordField.name] as? String) ?? "",
            type: type,
            options: [],
            sortOrder: Int((record[RecordField.sortOrder] as? Int64) ?? 0),
            isDefault: Self.decodeBool(record[RecordField.isDefault]),
            defaultFieldKey: record[RecordField.defaultFieldKey] as? String,
            isVisible: Self.decodeBool(record[RecordField.isVisible], default: true)
        )

        // Preserve the peer's options JSON verbatim — re-encoding via the
        // `options:` memberwise init would round-trip through SelectOption,
        // silently dropping fields the newer peer added.
        if let json = record[RecordField.optionsJSON] as? String {
            self.optionsJSON = json
        }
    }

    /// CKRecord stores Bools as Int64 (see populate). Accept Bool too for
    /// peers that happen to write it natively; fall back to `defaultValue`
    /// when the field is missing entirely.
    private static func decodeBool(_ value: CKRecordValue?, default defaultValue: Bool = false) -> Bool {
        if let bool = value as? Bool { return bool }
        if let int = value as? Int64 { return int != 0 }
        return defaultValue
    }
}
