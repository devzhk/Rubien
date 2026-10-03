import Foundation
import GRDB

extension AppDatabase {
    /// Additive foundation. App/CLI entry points stay gated until sync dispatch is ready.
    static func applyV15AttachmentSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE referenceAttachment (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                syncId TEXT NOT NULL UNIQUE,
                referenceId INTEGER REFERENCES reference(id) ON DELETE SET NULL,
                referenceSyncId TEXT NOT NULL,
                kind TEXT NOT NULL,
                originalFilename TEXT NOT NULL,
                displayName TEXT NOT NULL CHECK(length(trim(displayName)) > 0),
                byteCount INTEGER NOT NULL CHECK(byteCount >= 0),
                contentHash TEXT NOT NULL CHECK(length(contentHash) = 64),
                dateCreated DATETIME NOT NULL,
                dateModified DATETIME NOT NULL,
                deletedAt DATETIME,
                CHECK(deletedAt IS NOT NULL OR referenceId IS NOT NULL)
            );
            CREATE INDEX attachment_reference ON referenceAttachment(referenceId, dateCreated, syncId);
            CREATE INDEX attachment_global_parent ON referenceAttachment(referenceSyncId);
            CREATE TABLE attachmentCache (
                attachmentSyncId TEXT PRIMARY KEY REFERENCES referenceAttachment(syncId),
                relativePath TEXT NOT NULL UNIQUE,
                contentHash TEXT NOT NULL,
                materializedAt DATETIME NOT NULL,
                lastOpenedAt DATETIME
            );
            CREATE TABLE attachmentUploadQueue (
                attachmentSyncId TEXT PRIMARY KEY REFERENCES referenceAttachment(syncId),
                contentHash TEXT NOT NULL,
                queuedAt DATETIME NOT NULL
            );
            CREATE TABLE attachmentFileJournal (
                operationId TEXT PRIMARY KEY,
                attachmentSyncId TEXT NOT NULL,
                stagedPath TEXT NOT NULL,
                finalPath TEXT NOT NULL,
                purpose TEXT NOT NULL,
                createdAt DATETIME NOT NULL
            );
            CREATE TABLE attachmentReaderState (
                attachmentSyncId TEXT PRIMARY KEY REFERENCES referenceAttachment(syncId),
                contentHash TEXT NOT NULL,
                readerKind TEXT NOT NULL,
                positionVersion INTEGER NOT NULL,
                positionJSON TEXT NOT NULL
            );
            CREATE TABLE attachmentAnnotation (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                syncId TEXT NOT NULL UNIQUE,
                attachmentId INTEGER REFERENCES referenceAttachment(id) ON DELETE SET NULL,
                attachmentSyncId TEXT NOT NULL,
                contentHash TEXT NOT NULL,
                type TEXT,
                color TEXT,
                selectedText TEXT,
                noteText TEXT,
                anchorKind TEXT,
                anchorVersion INTEGER,
                anchorJSON TEXT,
                dateCreated DATETIME NOT NULL,
                dateModified DATETIME NOT NULL,
                deletedAt DATETIME,
                CHECK(deletedAt IS NOT NULL OR
                    (attachmentId IS NOT NULL AND type IS NOT NULL AND color IS NOT NULL
                     AND anchorKind IS NOT NULL AND anchorVersion IS NOT NULL AND anchorJSON IS NOT NULL))
            );
            CREATE INDEX attachment_annotation_parent ON attachmentAnnotation(attachmentSyncId);
            CREATE TRIGGER attachment_immutable BEFORE UPDATE ON referenceAttachment
            WHEN NEW.syncId != OLD.syncId OR NEW.referenceSyncId != OLD.referenceSyncId
                OR NEW.kind != OLD.kind OR NEW.originalFilename != OLD.originalFilename
                OR NEW.byteCount != OLD.byteCount OR NEW.contentHash != OLD.contentHash
                OR (OLD.deletedAt IS NOT NULL AND NEW.deletedAt IS NULL)
            BEGIN SELECT RAISE(ABORT, 'attachment identity and content are immutable'); END;
            CREATE TRIGGER attachment_annotation_identity BEFORE UPDATE ON attachmentAnnotation
            WHEN NEW.syncId != OLD.syncId OR NEW.attachmentSyncId != OLD.attachmentSyncId
                OR NEW.contentHash != OLD.contentHash
                OR (OLD.deletedAt IS NOT NULL AND NEW.deletedAt IS NULL)
            BEGIN SELECT RAISE(ABORT, 'annotation identity and removal are immutable'); END;
            """)

        // This extends the existing handshake without changing any shipped trigger.
        for table in ["referenceAttachment", "attachmentAnnotation"] {
            for (suffix, event) in [("ai", "INSERT"), ("au", "UPDATE")] {
                try db.execute(sql: """
                    CREATE TRIGGER \(table)_\(suffix) AFTER \(event) ON \(table)
                    WHEN (SELECT value FROM syncSession WHERE key='applyingRemote') IS NULL
                    BEGIN
                        DELETE FROM tombstone WHERE entityType='\(table)' AND entityId=NEW.syncId;
                        INSERT INTO syncState(entityType, entityId, isDirty, pushInFlight)
                        VALUES('\(table)', NEW.syncId, 1, 0)
                        ON CONFLICT(entityType, entityId) DO UPDATE SET isDirty=1, pushInFlight=0;
                    END;
                    """)
            }
        }
        // Parent removal must preserve child markers even when remote-apply suppresses
        // ordinary triggers. This updates children once; it is not a timestamp loop.
        try db.execute(sql: """
            CREATE TRIGGER reference_remove_attachments BEFORE DELETE ON reference
            BEGIN
                UPDATE referenceAttachment
                SET deletedAt=COALESCE(deletedAt, strftime('%Y-%m-%dT%H:%M:%fZ','now')),
                    dateModified=strftime('%Y-%m-%dT%H:%M:%fZ','now')
                WHERE referenceId=OLD.id;
                DELETE FROM tombstone WHERE entityType='referenceAttachment'
                    AND entityId IN (SELECT syncId FROM referenceAttachment WHERE referenceId=OLD.id);
                INSERT INTO syncState(entityType, entityId, isDirty, pushInFlight)
                SELECT 'referenceAttachment', syncId, 1, 0 FROM referenceAttachment WHERE referenceId=OLD.id
                ON CONFLICT(entityType, entityId) DO UPDATE SET isDirty=1, pushInFlight=0;
                DELETE FROM attachmentUploadQueue WHERE attachmentSyncId IN
                    (SELECT syncId FROM referenceAttachment WHERE referenceId=OLD.id);
                DELETE FROM syncState WHERE entityType='attachmentAsset' AND entityId IN
                    (SELECT syncId FROM referenceAttachment WHERE referenceId=OLD.id);
            END;
            """)
    }
}
