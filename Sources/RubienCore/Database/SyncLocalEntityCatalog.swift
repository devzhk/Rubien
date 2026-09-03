import Foundation
import GRDB

/// Current local identity sources for rows represented in CloudKit.
///
/// This catalog is runtime metadata only. Shipped migrations must embed their
/// own frozen literal sources so future catalog changes cannot alter an older
/// migration on fresh installs.
public enum SyncLocalEntityCatalog {
    public struct Source: Equatable, Sendable {
        public let entityType: String
        fileprivate let fromClause: String
        fileprivate let identityExpression: String

        fileprivate init(
            entityType: String,
            fromClause: String,
            identityExpression: String
        ) {
            self.entityType = entityType
            self.fromClause = fromClause
            self.identityExpression = identityExpression
        }

        public func identities(_ db: Database) throws -> [String] {
            try String.fetchAll(
                db,
                sql: "SELECT \(identityExpression) FROM \(fromClause)"
            )
        }

        /// Returns only requested live identities. Chunking keeps the query
        /// below SQLite's host-parameter limit when an engine batch is large.
        public func matchingIdentities(
            _ entityIds: Set<String>,
            in db: Database
        ) throws -> Set<String> {
            guard !entityIds.isEmpty else { return [] }
            let sorted = entityIds.sorted()
            var matches: Set<String> = []
            for start in stride(from: 0, to: sorted.count, by: 400) {
                let end = min(start + 400, sorted.count)
                let chunk = Array(sorted[start..<end])
                let placeholders = Array(
                    repeating: "?",
                    count: chunk.count
                ).joined(separator: ",")
                matches.formUnion(try String.fetchAll(
                    db,
                    sql: """
                        SELECT \(identityExpression) FROM \(fromClause)
                        WHERE \(identityExpression) IN (\(placeholders))
                        """,
                    arguments: StatementArguments(chunk)
                ))
            }
            return matches
        }

        public func contains(_ entityId: String, in db: Database) throws -> Bool {
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM \(fromClause)
                        WHERE \(identityExpression) = ?
                    )
                    """,
                arguments: [entityId]
            ) ?? false
        }

        /// SQL fragments used by the initial-baseline INSERT-SELECT. Values
        /// are fixed literals owned by this type, never user-controlled.
        public var baselineFromClause: String { fromClause }
        public var baselineIdentityExpression: String { identityExpression }
    }

    public static let current: [Source] = {
        let syncIdTables = [
            "reference", "tag", "referenceTag", "pdfAnnotation",
            "webAnnotation", "metadataIntake", "metadataEvidence",
            "propertyDefinition", "propertyValue", "databaseView",
            "readingActivity",
        ]
        var result = syncIdTables.map {
            Source(
                entityType: $0,
                fromClause: $0,
                identityExpression: "syncId"
            )
        }
        result.append(Source(
            entityType: "assistantActivity",
            fromClause: "assistantActivity",
            identityExpression: "id"
        ))
        result.append(Source(
            entityType: "activityEpoch",
            fromClause: "activityEpoch",
            identityExpression: "kind"
        ))
        result.append(Source(
            entityType: "referencePDF",
            fromClause: "pdfCache pc JOIN reference r ON r.id = pc.referenceId",
            identityExpression: "r.syncId"
        ))
        return result
    }()

    public static func source(for entityType: String) -> Source? {
        current.first { $0.entityType == entityType }
    }

    public static func contains(
        entityType: String,
        entityId: String,
        in db: Database
    ) throws -> Bool {
        guard let source = source(for: entityType) else { return false }
        return try source.contains(entityId, in: db)
    }
}
