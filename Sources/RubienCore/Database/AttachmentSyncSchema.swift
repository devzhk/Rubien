import Foundation
import GRDB

extension AppDatabase {
    static func applyV17AttachmentSyncSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE attachmentSyncScope (
                scopeID TEXT PRIMARY KEY, accountID TEXT NOT NULL, environment TEXT NOT NULL,
                zoneName TEXT NOT NULL, zoneOwner TEXT NOT NULL, featureVersion INTEGER NOT NULL,
                inventoryToken BLOB, inventoryComplete BOOLEAN NOT NULL DEFAULT 0, error TEXT
            );
            CREATE TABLE attachmentServerState (
                scopeID TEXT NOT NULL, entityType TEXT NOT NULL, entityId TEXT NOT NULL,
                observedAt DATETIME NOT NULL, removalAcknowledgedAt DATETIME,
                PRIMARY KEY(scopeID, entityType, entityId)
            );
            CREATE TABLE attachmentReferenceDeletion (
                scopeID TEXT NOT NULL, referenceSyncId TEXT NOT NULL, deletedAt DATETIME NOT NULL,
                PRIMARY KEY(scopeID, referenceSyncId)
            );
            CREATE TABLE attachmentQuarantineScope (
                recordName TEXT PRIMARY KEY, scopeID TEXT NOT NULL
            );
            CREATE TABLE attachmentDownload (
                scopeID TEXT NOT NULL, attachmentSyncId TEXT NOT NULL, contentHash TEXT NOT NULL,
                byteCount INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                nextAttemptAt DATETIME, error TEXT,
                PRIMARY KEY(scopeID, attachmentSyncId)
            );
            CREATE TABLE attachmentTransferError (
                scopeID TEXT NOT NULL, attachmentSyncId TEXT NOT NULL, error TEXT NOT NULL,
                PRIMARY KEY(scopeID, attachmentSyncId)
            );
            CREATE TABLE attachmentRecovery (
                scopeID TEXT NOT NULL, entityType TEXT NOT NULL, entityId TEXT NOT NULL,
                parentSyncId TEXT NOT NULL, error TEXT,
                PRIMARY KEY(scopeID, entityType, entityId)
            );
            CREATE TABLE attachmentCleanup (
                scopeID TEXT NOT NULL, attachmentSyncId TEXT NOT NULL, requestedAt DATETIME NOT NULL, error TEXT,
                PRIMARY KEY(scopeID, attachmentSyncId)
            );
            CREATE TRIGGER attachment_reference_deletion_evidence BEFORE DELETE ON reference
            WHEN (SELECT value FROM syncSession WHERE key='attachmentSyncScope') IS NOT NULL
            BEGIN
                INSERT INTO attachmentReferenceDeletion(scopeID, referenceSyncId, deletedAt)
                VALUES((SELECT value FROM syncSession WHERE key='attachmentSyncScope'), OLD.syncId, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
                ON CONFLICT(scopeID, referenceSyncId) DO NOTHING;
            END;
            """)
    }
}
