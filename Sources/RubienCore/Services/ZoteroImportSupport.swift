import Foundation
import GRDB

/// Target used by the Zotero folder importer (and the generic CLI `--property` flag)
/// to stamp a single value onto every imported reference.
public struct ZoteroImportPropertyTarget: Equatable, Sendable {
    public let propertyId: Int64
    public let value: String

    public init(propertyId: Int64, value: String) {
        self.propertyId = propertyId
        self.value = value
    }
}

/// Errors thrown while stamping the import's property target.
public enum ZoteroImportError: Error, LocalizedError, Equatable {
    case propertyNotFound(name: String)
    case unsupportedPropertyType(typeLabel: String)

    public var errorDescription: String? {
        switch self {
        case .propertyNotFound(let name):
            return "Property not found: '\(name)'"
        case .unsupportedPropertyType(let label):
            return "Property type '\(label)' cannot receive the folder-name value. Allowed types: Text, URL, Select, Multi-select."
        }
    }
}

// MARK: - In-transaction property writer

extension AppDatabase {
    /// Apply a single value to `referenceIds` on the given property, inside an existing transaction.
    ///
    /// - `Tags` (multiSelect with `defaultFieldKey == "tags"`) → Tag/ReferenceTag pivot
    /// - Non-Tags multiSelect → append value to the JSON-encoded `[String]` in `propertyValue.value`
    /// - singleSelect / string / url → overwrite `propertyValue.value`
    /// - Any other type throws `ZoteroImportError.unsupportedPropertyType`.
    ///
    /// For singleSelect and multiSelect (non-Tags), the property's `optionsJSON` is mutated
    /// to include the new value (with an auto-picked color) if it isn't already listed.
    func applyPropertyValueInTransaction(
        referenceIds: [Int64],
        propertyId: Int64,
        value: String,
        db: Database
    ) throws {
        guard !referenceIds.isEmpty else { return }
        guard var property = try PropertyDefinition
            .filter(PropertyDefinition.Columns.id == propertyId)
            .fetchOne(db)
        else {
            throw ZoteroImportError.propertyNotFound(name: "id=\(propertyId)")
        }

        switch property.type {
        case .multiSelect where property.defaultFieldKey == PropertyDefinition.tagsFieldKey:
            try stampTagValue(value: value, on: referenceIds, db: db)

        case .multiSelect:
            try ensureOption(&property, value: value, db: db)
            try stampMultiSelectValue(propertyId: propertyId, value: value, on: referenceIds, db: db)

        case .singleSelect:
            try ensureOption(&property, value: value, db: db)
            try stampScalarValue(propertyId: propertyId, value: value, on: referenceIds, db: db)

        case .string, .url:
            try stampScalarValue(propertyId: propertyId, value: value, on: referenceIds, db: db)

        case .number, .date, .checkbox:
            throw ZoteroImportError.unsupportedPropertyType(typeLabel: property.type.label)
        }
    }

    // MARK: Tags (built-in)

    private func stampTagValue(value: String, on referenceIds: [Int64], db: Database) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let tag: Tag
        if let existing = try Tag.filter(Tag.Columns.name == trimmed).fetchOne(db) {
            tag = existing
        } else {
            let usedColors = try Set(String.fetchAll(db, sql: "SELECT DISTINCT color FROM tag"))
            var fresh = Tag(name: trimmed, color: ColorPalette.nextUnused(excluding: usedColors))
            try fresh.insert(db)
            tag = fresh
        }
        guard let tagId = tag.id else { return }

        for refId in referenceIds {
            try db.execute(
                sql: "INSERT OR IGNORE INTO referenceTag (referenceId, tagId) VALUES (?, ?)",
                arguments: [refId, tagId]
            )
        }
    }

    // MARK: Custom multiSelect

    private func stampMultiSelectValue(
        propertyId: Int64,
        value: String,
        on referenceIds: [Int64],
        db: Database
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let existing = try fetchExistingPropertyValues(
            propertyId: propertyId,
            referenceIds: referenceIds,
            db: db
        )

        for refId in referenceIds {
            if var row = existing[refId] {
                var current = PropertyValue.decodeMultiSelect(row.value ?? "")
                if !current.contains(trimmed) {
                    current.append(trimmed)
                    row.value = PropertyValue.encodeMultiSelect(current)
                    try row.update(db)
                }
            } else {
                var row = PropertyValue(
                    referenceId: refId,
                    propertyId: propertyId,
                    value: PropertyValue.encodeMultiSelect([trimmed])
                )
                try row.insert(db)
            }
        }
    }

    // MARK: Scalar (singleSelect / string / url)

    private func stampScalarValue(
        propertyId: Int64,
        value: String,
        on referenceIds: [Int64],
        db: Database
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let existing = try fetchExistingPropertyValues(
            propertyId: propertyId,
            referenceIds: referenceIds,
            db: db
        )

        for refId in referenceIds {
            if var row = existing[refId] {
                row.value = trimmed
                try row.update(db)
            } else {
                var row = PropertyValue(referenceId: refId, propertyId: propertyId, value: trimmed)
                try row.insert(db)
            }
        }
    }

    /// Batch-fetch existing `propertyValue` rows for the given reference ids, keyed by
    /// `referenceId`. Chunked to respect SQLite's host-parameter limit (matches the
    /// convention in `fetchPropertyValues(forReferences:)`).
    private func fetchExistingPropertyValues(
        propertyId: Int64,
        referenceIds: [Int64],
        db: Database
    ) throws -> [Int64: PropertyValue] {
        guard !referenceIds.isEmpty else { return [:] }
        var result: [Int64: PropertyValue] = [:]
        let chunkSize = 500
        for start in stride(from: 0, to: referenceIds.count, by: chunkSize) {
            let slice = Array(referenceIds[start..<min(start + chunkSize, referenceIds.count)])
            let rows = try PropertyValue
                .filter(PropertyValue.Columns.propertyId == propertyId)
                .filter(slice.contains(PropertyValue.Columns.referenceId))
                .fetchAll(db)
            for row in rows { result[row.referenceId] = row }
        }
        return result
    }

    // MARK: Option-list upkeep for select properties

    private func ensureOption(_ property: inout PropertyDefinition, value: String, db: Database) throws {
        if property.addOptionIfMissing(value) {
            try property.update(db)
        }
    }
}

// MARK: - Property lookup for CLI

extension AppDatabase {
    /// Resolve a property by exact name. Used by the CLI's `--property` flag.
    public func findPropertyDefinition(byName name: String) throws -> PropertyDefinition? {
        try dbWriter.read { db in
            try PropertyDefinition
                .filter(PropertyDefinition.Columns.name == name)
                .fetchOne(db)
        }
    }

    /// Pre-flight check for a property target: the property must exist and have a type
    /// that `applyPropertyValueInTransaction` can write (`string`, `url`, `singleSelect`,
    /// `multiSelect`). Throws `ZoteroImportError` otherwise.
    ///
    /// Call this before any filesystem side effects (PDF copies) so a bad target fails
    /// fast and we don't leak copied files.
    package func validatePropertyTarget(_ target: ZoteroImportPropertyTarget) throws {
        try dbWriter.read { db in
            guard let prop = try PropertyDefinition
                .filter(PropertyDefinition.Columns.id == target.propertyId)
                .fetchOne(db) else {
                throw ZoteroImportError.propertyNotFound(name: "id=\(target.propertyId)")
            }
            switch prop.type {
            case .string, .url, .singleSelect, .multiSelect: return
            case .number, .date, .checkbox:
                throw ZoteroImportError.unsupportedPropertyType(typeLabel: prop.type.label)
            }
        }
    }
}

