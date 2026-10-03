#if os(macOS)
import Foundation
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienSync

final class CloudKitSchemaFileTests: XCTestCase {
    func testCheckedInSchemaMatchesEveryRecordMapping() throws {
        let schemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CloudKit/RubienSchema.ckdb")
        let schema = try String(contentsOf: schemaURL, encoding: .utf8)
        let database = try AppDatabase(DatabaseQueue())

        for entity in SyncEntityType.allCases {
            XCTAssertEqual(
                try customFields(in: schema, recordType: entity.recordType),
                try expectedFieldSignatures(for: entity, database: database),
                "Checked-in CloudKit schema drifted for \(entity.recordType)"
            )
        }
    }

    func testDormantAttachmentSchemaMatchesMappingsAndSQLite() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let schema = try String(contentsOf: root.appendingPathComponent("CloudKit/RubienSchema.ckdb"), encoding: .utf8)
        let database = try AppDatabase(DatabaseQueue())
        let entries: [(AttachmentRecordKind, [String], Set<String>)] = [
            (.referenceAttachment, ReferenceAttachment.allFieldNames, ["id", "referenceId"]),
            (.attachmentAnnotation, ReferenceAttachmentAnnotation.allFieldNames, ["id", "attachmentId"]),
        ]
        for (kind, fields, local) in entries {
            let columns = try database.dbWriter.read { db in
                try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT name, type FROM pragma_table_info(?)", arguments: [kind.rawValue])
                    .map { ($0["name"] as String, $0["type"] as String) })
            }
            XCTAssertEqual(Set(columns.keys).subtracting(local), Set(fields))
            let signatures = try Dictionary(uniqueKeysWithValues: fields.map { ($0, try cloudKitSignature(forSQLiteType: XCTUnwrap(columns[$0]))) })
            XCTAssertEqual(try customFields(in: schema, recordType: kind.recordType), signatures)
        }
        let assetFields = try customFields(in: schema, recordType: "CDAttachmentAsset")
        XCTAssertEqual(Set(assetFields.keys), Set(AttachmentAssetRecord.allFieldNames))
        XCTAssertEqual(assetFields["asset"], "ASSET")
        XCTAssertEqual(assetFields["byteCount"], "INT64 QUERYABLE SORTABLE")
        for key in ["syncId", "attachmentSyncId", "contentHash"] {
            XCTAssertEqual(assetFields[key], "STRING QUERYABLE SEARCHABLE SORTABLE")
        }
    }

    func testInventoryProjectionCannotRequestLargePrimaryFields() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let schema = try String(contentsOf: root.appendingPathComponent("CloudKit/RubienSchema.ckdb"), encoding: .utf8)
        let projection = Set(AttachmentInventoryProjection.desiredKeys)
        // String content must be classified explicitly; binary types are discovered
        // from every existing primary schema declaration to catch future additions.
        var excluded: Set<String> = ["asset", "webContent", "notes", "favicon"]
        var primaryFields = Set<String>()
        for kind in SyncEntityType.allCases {
            let fields = try customFields(in: schema, recordType: kind.recordType)
            primaryFields.formUnion(fields.keys)
            excluded.formUnion(fields.filter { $0.value.hasPrefix("ASSET") || $0.value.hasPrefix("BYTES") }.keys)
        }
        XCTAssertTrue(projection.isDisjoint(with: excluded))
        XCTAssertFalse(projection.isEmpty)
        for overlap in ["selectedText", "noteText", "color", "type", "contentHash", "kind"] {
            XCTAssertTrue(primaryFields.contains(overlap))
            XCTAssertTrue(projection.contains(overlap), "Known scalar/text overlap is expected across the zone")
        }
    }

    private func customFields(
        in schema: String,
        recordType: String
    ) throws -> [String: String] {
        let startMarker = "RECORD TYPE \(recordType) ("
        let start = try XCTUnwrap(schema.range(of: startMarker))
        let remaining = schema[start.upperBound...]
        let end = try XCTUnwrap(remaining.range(of: "\n    );"))
        let body = remaining[..<end.lowerBound]

        return Dictionary(uniqueKeysWithValues: body.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("\"___"),
                  !trimmed.hasPrefix("GRANT ")
            else {
                return nil
            }
            let parts = trimmed
                .dropLast(trimmed.hasSuffix(",") ? 1 : 0)
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            guard let fieldName = parts.first else { return nil }
            return (fieldName, parts.dropFirst().joined(separator: " "))
        })
    }

    private func expectedFieldSignatures(
        for entity: SyncEntityType,
        database: AppDatabase
    ) throws -> [String: String] {
        if entity == .attachmentAsset {
            return ["asset": "ASSET", "byteCount": "INT64 QUERYABLE SORTABLE",
                    "syncId": "STRING QUERYABLE SEARCHABLE SORTABLE",
                    "attachmentSyncId": "STRING QUERYABLE SEARCHABLE SORTABLE",
                    "contentHash": "STRING QUERYABLE SEARCHABLE SORTABLE"]
        }
        if entity == .referencePDF {
            return [
                ReferencePDFRecord.RecordField.asset: "ASSET",
                ReferencePDFRecord.RecordField.assetVersion: "INT64 QUERYABLE SORTABLE",
                ReferencePDFRecord.RecordField.contentHash: "STRING QUERYABLE SEARCHABLE SORTABLE",
                ReferencePDFRecord.RecordField.dateModified: "TIMESTAMP QUERYABLE SORTABLE",
                ReferencePDFRecord.RecordField.originalFilename: "STRING QUERYABLE SEARCHABLE SORTABLE",
                ReferencePDFRecord.RecordField.referenceId: "INT64 QUERYABLE SORTABLE",
                ReferencePDFRecord.RecordField.referenceSyncId: "STRING QUERYABLE SEARCHABLE SORTABLE",
                ReferencePDFRecord.RecordField.syncId: "STRING QUERYABLE SEARCHABLE SORTABLE",
            ]
        }

        let columnTypes: [String: String] = try database.dbWriter.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(
                db,
                sql: "SELECT name, type FROM pragma_table_info(?)",
                arguments: [entity.rawValue]
            ).map { row in
                (row["name"] as String, row["type"] as String)
            })
        }

        let cloudOnlyViewFields = Set([
            DatabaseView.RecordField.scopeSyncJSON,
            DatabaseView.RecordField.filtersSyncJSON,
            DatabaseView.RecordField.sortsSyncJSON,
            DatabaseView.RecordField.groupBySyncJSON,
            DatabaseView.RecordField.columnWrapsSyncJSON,
        ])
        var result = try Dictionary(uniqueKeysWithValues: recordFieldNames(for: entity)
            .filter {
                if entity == .databaseView, cloudOnlyViewFields.contains($0) {
                    return false
                }
                if (entity == .assistantActivity || entity == .activityEpoch),
                   $0 == SyncRecordIdentity.syncIdField
                {
                    return false
                }
                return true
            }
            .map {
            recordField in
            let columnName = databaseColumnName(
                for: recordField,
                entity: entity
            )
            let columnType = try XCTUnwrap(
                columnTypes[columnName],
                "Missing SQLite column \(columnName) for \(entity.recordType)"
            )
            return (
                recordField,
                try cloudKitSignature(forSQLiteType: columnType)
            )
        })
        if entity == .assistantActivity || entity == .activityEpoch {
            result[SyncRecordIdentity.syncIdField] = "STRING QUERYABLE SEARCHABLE SORTABLE"
        }
        if entity == .databaseView {
            for field in cloudOnlyViewFields {
                result[field] = "STRING QUERYABLE SEARCHABLE SORTABLE"
            }
        }
        return result
    }

    private func databaseColumnName(
        for recordField: String,
        entity: SyncEntityType
    ) -> String {
        guard entity == .reference else { return recordField }
        switch recordField {
        case Reference.RecordField.authorsJSON:
            return "authors"
        case Reference.RecordField.editorsJSON:
            return "editors"
        case Reference.RecordField.translatorsJSON:
            return "translators"
        default:
            return recordField
        }
    }

    private func cloudKitSignature(forSQLiteType type: String) throws -> String {
        try XCTUnwrap(
            [
                "TEXT": "STRING QUERYABLE SEARCHABLE SORTABLE",
                "INTEGER": "INT64 QUERYABLE SORTABLE",
                "BOOLEAN": "INT64 QUERYABLE SORTABLE",
                "DATETIME": "TIMESTAMP QUERYABLE SORTABLE",
                "DOUBLE": "DOUBLE QUERYABLE SORTABLE",
                "REAL": "DOUBLE QUERYABLE SORTABLE",
            ][type.uppercased()],
            "Add an explicit CloudKit mapping for SQLite type \(type)"
        )
    }

    private func recordFieldNames(for entity: SyncEntityType) -> [String] {
        switch entity {
        case .referenceAttachment: return ReferenceAttachment.allFieldNames
        case .attachmentAsset: return AttachmentAssetRecord.allFieldNames
        case .attachmentAnnotation: return ReferenceAttachmentAnnotation.allFieldNames
        case .reference:
            return Reference.allFieldNames.map {
                switch $0 {
                case "authors": return Reference.RecordField.authorsJSON
                case "editors": return Reference.RecordField.editorsJSON
                case "translators": return Reference.RecordField.translatorsJSON
                default: return $0
                }
            }
        case .tag:
            return Tag.allFieldNames
        case .referenceTag:
            return ReferenceTag.allFieldNames
        case .pdfAnnotation:
            return PDFAnnotationRecord.allFieldNames
        case .webAnnotation:
            return WebAnnotationRecord.allFieldNames
        case .metadataIntake:
            return MetadataIntake.allFieldNames
        case .metadataEvidence:
            return MetadataEvidence.allFieldNames
        case .propertyDefinition:
            return PropertyDefinition.allFieldNames
        case .propertyValue:
            return PropertyValue.allFieldNames
        case .databaseView:
            return DatabaseView.allFieldNames
        case .readingActivity:
            return ReadingActivity.allFieldNames
        case .assistantActivity:
            return AssistantActivity.allFieldNames
        case .activityEpoch:
            return ActivityEpoch.allFieldNames
        case .referencePDF:
            return ReferencePDFRecord.allFieldNames
        }
    }
}
#endif
