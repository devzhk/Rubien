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
