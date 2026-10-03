import GRDB

extension AppDatabase {
    static func applyV18AttachmentSyncRecoverySchema(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE attachmentServerState ADD COLUMN physicalDeletedAt DATETIME;
            ALTER TABLE attachmentServerState ADD COLUMN observationVersion INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE attachmentQuarantineScope ADD COLUMN parentSyncId TEXT;
            ALTER TABLE attachmentQuarantineScope ADD COLUMN pendingReplay BOOLEAN NOT NULL DEFAULT 1;
            ALTER TABLE attachmentQuarantineScope ADD COLUMN buffered BOOLEAN NOT NULL DEFAULT 0;
            CREATE INDEX attachmentQuarantine_pending ON attachmentQuarantineScope(scopeID,pendingReplay,recordName);
            CREATE INDEX attachmentQuarantine_parent ON attachmentQuarantineScope(scopeID,parentSyncId);
            CREATE TABLE attachmentRemovalWork (
                scopeID TEXT NOT NULL, attachmentSyncId TEXT NOT NULL,
                PRIMARY KEY(scopeID,attachmentSyncId)
            );
            CREATE TABLE attachmentDeferredDeletion (
                scopeID TEXT NOT NULL, recordName TEXT NOT NULL, recordType TEXT NOT NULL,
                PRIMARY KEY(scopeID,recordName)
            );
            CREATE TRIGGER attachment_quarantine_removed AFTER DELETE ON syncOrphan
            BEGIN DELETE FROM attachmentQuarantineScope WHERE recordName=OLD.recordName; END;
            INSERT INTO attachmentServerState(scopeID,entityType,entityId,observedAt,physicalDeletedAt)
            SELECT s.value,t.entityType,t.entityId,t.deletedAt,t.deletedAt FROM tombstone t
            JOIN syncSession s ON s.key='attachmentSyncScope'
            WHERE t.entityType IN ('attachmentAsset','attachmentAnnotation') AND t.confirmedByServer=1
            ON CONFLICT(scopeID,entityType,entityId) DO UPDATE SET physicalDeletedAt=excluded.physicalDeletedAt;
            INSERT INTO attachmentRemovalWork(scopeID,attachmentSyncId)
            SELECT s.value,a.syncId FROM referenceAttachment a JOIN syncSession s ON s.key='attachmentSyncScope'
            WHERE a.deletedAt IS NOT NULL;
            """)
        for (suffix,event) in [("ai","INSERT"),("au","UPDATE")] {
            try db.execute(sql: """
                CREATE TRIGGER attachment_removal_work_\(suffix) AFTER \(event) ON referenceAttachment
                WHEN NEW.deletedAt IS NOT NULL AND (SELECT value FROM syncSession WHERE key='attachmentSyncScope') IS NOT NULL
                BEGIN
                    INSERT INTO attachmentRemovalWork(scopeID,attachmentSyncId)
                    VALUES((SELECT value FROM syncSession WHERE key='attachmentSyncScope'),NEW.syncId)
                    ON CONFLICT(scopeID,attachmentSyncId) DO NOTHING;
                END;
                CREATE TRIGGER attachment_parent_ready_\(suffix) AFTER \(event) ON referenceAttachment
                BEGIN UPDATE attachmentQuarantineScope SET pendingReplay=1
                    WHERE parentSyncId=NEW.syncId AND scopeID=(SELECT value FROM syncSession WHERE key='attachmentSyncScope'); END;
                CREATE TRIGGER attachment_reference_ready_\(suffix) AFTER \(event) ON reference
                BEGIN UPDATE attachmentQuarantineScope SET pendingReplay=1
                    WHERE parentSyncId=NEW.syncId AND scopeID=(SELECT value FROM syncSession WHERE key='attachmentSyncScope'); END;
                """)
        }
    }
}
