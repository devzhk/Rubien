#if canImport(CloudKit)
import Foundation
import GRDB

/// Durable local redirects for identities retired by deterministic
/// reconciliation. CloudKit children can arrive after their losing parent, so
/// dependency resolution must continue to recognize that historical identity.
enum SyncIdentityAliasStore {
    private static let maximumDepth = 32

    enum ResolutionError: LocalizedError, Equatable {
        case cycle(entityType: String, identity: String)
        case depthExceeded(entityType: String, identity: String)

        var errorDescription: String? {
            switch self {
            case .cycle(let entityType, let identity):
                "sync identity alias cycle for \(entityType):\(identity)"
            case .depthExceeded(let entityType, let identity):
                "sync identity alias depth exceeded for \(entityType):\(identity)"
            }
        }
    }

    static func record(
        entityType: SyncEntityType,
        losingId: String,
        winningId: String,
        db: Database
    ) throws {
        guard losingId != winningId else { return }
        let canonicalWinner = try resolve(
            entityType: entityType,
            identity: winningId,
            db: db
        )
        guard losingId != canonicalWinner else {
            throw ResolutionError.cycle(
                entityType: entityType.rawValue,
                identity: losingId
            )
        }
        let now = Date()
        try db.execute(sql: """
            INSERT INTO syncIdentityAlias(
                entityType, losingId, winningId, createdAt
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(entityType, losingId) DO UPDATE SET
                winningId = excluded.winningId,
                createdAt = excluded.createdAt
            """, arguments: [
                entityType.rawValue, losingId, canonicalWinner, now,
            ])
        // Keep the graph flat as identities are retired repeatedly. Every
        // alias that used to terminate at this loser now terminates directly
        // at the same canonical winner, so ordinary resolution stays O(1).
        try db.execute(sql: """
            UPDATE syncIdentityAlias
            SET winningId = ?, createdAt = ?
            WHERE entityType = ? AND winningId = ?
              AND losingId <> ?
            """, arguments: [
                canonicalWinner, now, entityType.rawValue,
                losingId, canonicalWinner,
            ])
    }

    static func resolve(
        entityType: SyncEntityType,
        identity: String,
        db: Database
    ) throws -> String {
        var current = identity
        var seen = Set<String>()
        for _ in 0 ..< maximumDepth {
            guard seen.insert(current).inserted else {
                throw ResolutionError.cycle(
                    entityType: entityType.rawValue,
                    identity: identity
                )
            }
            guard let next = try String.fetchOne(db, sql: """
                SELECT winningId FROM syncIdentityAlias
                WHERE entityType = ? AND losingId = ?
                """, arguments: [entityType.rawValue, current]) else {
                return current
            }
            current = next
        }
        throw ResolutionError.depthExceeded(
            entityType: entityType.rawValue,
            identity: identity
        )
    }
}
#endif
