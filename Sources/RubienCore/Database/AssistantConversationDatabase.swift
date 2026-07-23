import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Conversation lifecycle

    @discardableResult
    public func createAssistantConversation(
        _ proposed: AssistantConversation
    ) throws -> AssistantConversation {
        var conversation = try Self.validatedNewAssistantConversation(proposed)
        try dbWriter.write { db in
            try conversation.insert(db)
            if let runID = conversation.scheduledJobRunId {
                try db.execute(
                    sql: """
                        UPDATE scheduledJobRun
                        SET assistantTranscriptState = 'capturing',
                            assistantTranscriptStatusCode = NULL
                        WHERE id = ? AND hiddenAt IS NULL
                        """,
                    arguments: [runID]
                )
                guard db.changesCount == 1 else {
                    throw AssistantConversationError.notFound
                }
            }
        }
        return conversation
    }

    public func fetchAssistantConversation(
        id: String
    ) throws -> AssistantConversation? {
        try dbWriter.read { db in
            try AssistantConversation.fetchOne(db, key: id)
        }
    }

    public func fetchAssistantConversationDetail(
        id: String,
        before cursor: AssistantTranscriptCursor? = nil,
        limit: Int = AssistantConversationDetail.defaultPageLimit
    ) throws -> AssistantConversationDetail? {
        try dbWriter.read { db in
            try Self.fetchAssistantConversationDetail(
                conversationID: id,
                before: cursor,
                limit: limit,
                in: db
            )
        }
    }

    public func fetchAssistantConversationDetail(
        scheduledJobRunID: String,
        before cursor: AssistantTranscriptCursor? = nil,
        limit: Int = AssistantConversationDetail.defaultPageLimit
    ) throws -> AssistantConversationDetail? {
        try dbWriter.read { db in
            guard let conversationID = try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM assistantConversation
                    WHERE scheduledJobRunId = ?
                """,
                arguments: [scheduledJobRunID]
            ) else { return nil }
            return try Self.fetchAssistantConversationDetail(
                conversationID: conversationID,
                before: cursor,
                limit: limit,
                in: db
            )
        }
    }

    public func fetchAssistantConversationSummaries(
        query: AssistantConversationQuery = AssistantConversationQuery()
    ) throws -> [AssistantConversationSummary] {
        guard query.limit > 0 else { return [] }
        return try dbWriter.read { db in
            let ftsQuery = Self.assistantFTSQuery(query.search)
            let conversations: [AssistantConversation]
            if let ftsQuery {
                conversations = try Self.fetchRankedAssistantConversations(
                    query: query,
                    ftsQuery: ftsQuery,
                    in: db
                )
            } else {
                var request = AssistantConversation
                    .filter(
                        AssistantConversationOrigin.localHistoryRawValues.contains(
                            AssistantConversation.Columns.origin
                        )
                    )
                if !query.includeArchived {
                    request = request.filter(AssistantConversation.Columns.archivedAt == nil)
                }
                if let workspace = Self.nonBlank(query.workspaceIdentityHash) {
                    request = request.filter(
                        AssistantConversation.Columns.workspaceIdentityHash == workspace
                    )
                }
                if let provider = query.provider {
                    request = request.filter(
                        AssistantConversation.Columns.provider == provider.rawValue
                    )
                }
                if let contextKind = query.contextKind {
                    request = request.filter(
                        AssistantConversation.Columns.contextKind == contextKind.rawValue
                    )
                }
                if let referenceID = query.referenceId {
                    request = request.filter(
                        AssistantConversation.Columns.contextKind
                            == AssistantConversationContextKind.reference.rawValue
                        && AssistantConversation.Columns.referenceId == referenceID
                    )
                }
                request = request.order(
                    AssistantConversation.Columns.lastActivityAt.desc,
                    AssistantConversation.Columns.id.desc
                )
                conversations = try request
                    .limit(min(query.limit, 500))
                    .fetchAll(db)
            }

            let conversationIDs = conversations.map(\.id)
            guard !conversationIDs.isEmpty else { return [] }
            let placeholders = Array(
                repeating: "?",
                count: conversationIDs.count
            ).joined(separator: ",")
            var previewArguments = StatementArguments([
                AssistantConversationSummary.previewSourceCharacterLimit
            ])
            _ = previewArguments.append(
                contentsOf: StatementArguments(conversationIDs)
            )
            let previewRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT conversationId, body
                    FROM (
                        SELECT turn.conversationId,
                               substr(entry.body, 1, ?) AS body,
                               ROW_NUMBER() OVER (
                                   PARTITION BY turn.conversationId
                                   ORDER BY turn.ordinal ASC, entry.sequence ASC,
                                            entry.id ASC
                               ) AS rowNumber
                        FROM assistantTranscriptEntry AS entry
                        JOIN assistantTurn AS turn ON turn.id = entry.turnId
                        WHERE entry.kind = 'user'
                          AND turn.conversationId IN (\(placeholders))
                    )
                    WHERE rowNumber = 1
                    """,
                arguments: previewArguments
            )
            let previews = Dictionary(
                uniqueKeysWithValues: previewRows.map { row in
                    (
                        row["conversationId"] as String,
                        AssistantConversationSummary.boundedPreview(
                            row["body"] as String
                        )
                    )
                }
            )
            let countRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT conversationId, COUNT(*) AS turnCount
                    FROM assistantTurn
                    WHERE conversationId IN (\(placeholders))
                    GROUP BY conversationId
                    """,
                arguments: StatementArguments(conversationIDs)
            )
            let turnCounts = Dictionary(
                uniqueKeysWithValues: countRows.map { row in
                    (row["conversationId"] as String, row["turnCount"] as Int)
                }
            )
            return conversations.map { conversation in
                AssistantConversationSummary(
                    conversation: conversation,
                    preview: previews[conversation.id] ?? "",
                    turnCount: turnCounts[conversation.id] ?? 0
                )
            }
        }
    }

    // MARK: - Turn and transcript writes

    /// Inserts a turn and its user-visible prompt before provider admission.
    /// The caller allocates both stable IDs before dispatch.
    @discardableResult
    public func beginAssistantTurn(
        _ proposedTurn: AssistantTurn,
        userEntry proposedEntry: AssistantTranscriptEntry,
        attachments: [StoredAssistantAttachment] = []
    ) throws -> AssistantTurn {
        guard proposedTurn.ordinal > 0,
              proposedEntry.turnId == proposedTurn.id,
              proposedEntry.sequence == 0,
              proposedEntry.kind == .user else {
            throw AssistantConversationError.invalidOrdinal
        }
        try Self.validateIdentifier(proposedTurn.id)
        try Self.validateIdentifier(proposedEntry.id)
        try Self.validateAttachments(attachments, entryID: proposedEntry.id)

        var turn = proposedTurn
        var entry = proposedEntry
        try dbWriter.write { db in
            guard try AssistantConversation.fetchOne(db, key: turn.conversationId) != nil else {
                throw AssistantConversationError.notFound
            }
            try turn.insert(db)
            try entry.insert(db)
            for var attachment in attachments {
                try attachment.insert(db)
            }
            try Self.advanceAssistantConversationActivity(
                conversationID: turn.conversationId,
                to: entry.dateModified,
                in: db
            )
        }
        return turn
    }

    /// Atomically creates the local conversation on its first turn, allocates
    /// the next per-conversation ordinal, and durably inserts the user row. This
    /// is the interactive composition root's single pre-provider transaction.
    @discardableResult
    public func beginInteractiveAssistantTurn(
        conversation proposedConversation: AssistantConversation,
        turn proposedTurn: AssistantTurn,
        userEntry proposedEntry: AssistantTranscriptEntry,
        attachments: [StoredAssistantAttachment] = [],
        allowConversationCreation: Bool
    ) throws -> AssistantTurn {
        let conversation = try Self.validatedNewAssistantConversation(proposedConversation)
        guard conversation.scheduledJobRunId == nil,
              proposedTurn.conversationId == conversation.id,
              proposedEntry.turnId == proposedTurn.id,
              proposedEntry.sequence == 0,
              proposedEntry.kind == .user else {
            throw AssistantConversationError.invalidOrdinal
        }
        try Self.validateIdentifier(proposedTurn.id)
        try Self.validateIdentifier(proposedEntry.id)
        try Self.validateAttachments(attachments, entryID: proposedEntry.id)

        var turn = proposedTurn
        var entry = proposedEntry
        return try dbWriter.write { db in
            if let existing = try AssistantConversation.fetchOne(db, key: conversation.id) {
                guard existing.scheduledJobRunId == nil,
                      existing.provider == conversation.provider else {
                    throw AssistantConversationError.invalidIdentifier
                }
            } else {
                guard allowConversationCreation else {
                    throw AssistantConversationError.notFound
                }
                var inserted = conversation
                try inserted.insert(db)
            }
            turn.ordinal = (try Int.fetchOne(
                db,
                sql: """
                    SELECT MAX(
                        COALESCE((
                            SELECT MAX(ordinal) FROM assistantTurn
                            WHERE conversationId = conversation.id
                        ), 0),
                        COALESCE(conversation.latestSessionTurnOrdinal, 0)
                    ) + 1
                    FROM assistantConversation AS conversation
                    WHERE conversation.id = ?
                    """,
                arguments: [conversation.id]
            )) ?? 1
            try turn.insert(db)
            try entry.insert(db)
            for var attachment in attachments { try attachment.insert(db) }
            try Self.advanceAssistantConversationActivity(
                conversationID: conversation.id,
                to: entry.dateModified,
                in: db
            )
            return turn
        }
    }

    /// Scheduled capture is established atomically with the run lifecycle so a
    /// provider can never start for an invisible/unlinked transcript.
    public func beginScheduledAssistantCapture(
        runID: String,
        conversation proposedConversation: AssistantConversation,
        turn proposedTurn: AssistantTurn,
        userEntry proposedEntry: AssistantTranscriptEntry,
        attachments: [StoredAssistantAttachment] = [],
        at date: Date = Date()
    ) throws {
        var conversation = try Self.validatedNewAssistantConversation(proposedConversation)
        guard conversation.scheduledJobRunId == runID,
              proposedTurn.conversationId == conversation.id,
              proposedTurn.ordinal == 1,
              proposedEntry.turnId == proposedTurn.id,
              proposedEntry.sequence == 0,
              proposedEntry.kind == .user else {
            throw AssistantConversationError.invalidOrdinal
        }
        try Self.validateAttachments(attachments, entryID: proposedEntry.id)
        var turn = proposedTurn
        turn.status = .running
        turn.startedAt = turn.startedAt ?? date
        turn.dateModified = date
        var entry = proposedEntry

        try dbWriter.write { db in
            let runStatus = try String.fetchOne(
                db,
                sql: """
                    SELECT status FROM scheduledJobRun
                    WHERE id = ? AND hiddenAt IS NULL
                    """,
                arguments: [runID]
            )
            guard runStatus == ScheduledJobRunStatus.pending.rawValue else {
                throw AssistantConversationError.notFound
            }
            try conversation.insert(db)
            try turn.insert(db)
            try entry.insert(db)
            for var attachment in attachments { try attachment.insert(db) }
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun
                    SET status = 'running', startedAt = ?,
                        assistantTranscriptState = 'capturing',
                        assistantTranscriptStatusCode = NULL
                    WHERE id = ? AND status = 'pending' AND hiddenAt IS NULL
                    """,
                arguments: [date, runID]
            )
            guard db.changesCount == 1 else {
                throw AssistantConversationError.notFound
            }
        }
    }

    /// Commits the authoritative final projection, turn terminal metadata, and
    /// scheduled-run terminal metadata as one SQLite transaction.
    @discardableResult
    public func finishScheduledAssistantCapture(
        runID: String,
        turnID: String,
        runStatus: ScheduledJobRunStatus,
        runFailureKind: ScheduledJobFailureKind? = nil,
        turnStatus: AssistantTurnStatus,
        turnFailureKind: String? = nil,
        completion: AssistantTurnAccounting? = nil,
        finalEntry proposedFinalEntry: AssistantTranscriptEntry? = nil,
        at date: Date = Date()
    ) throws -> Bool {
        guard runStatus.isTerminal, turnStatus.isTerminal else { return false }
        return try dbWriter.write { db in
            guard let turn = try AssistantTurn.fetchOne(db, key: turnID),
                  let conversation = try AssistantConversation.fetchOne(
                    db,
                    key: turn.conversationId
                  ),
                  conversation.scheduledJobRunId == runID,
                  let run = try ScheduledJobRun.fetchOne(db, key: runID) else {
                throw AssistantConversationError.notFound
            }
            guard [.queued, .starting, .running].contains(turn.status),
                  [.pending, .running].contains(run.status) else { return false }
            if var finalEntry = proposedFinalEntry {
                guard finalEntry.turnId == turnID else {
                    throw AssistantConversationError.invalidIdentifier
                }
                finalEntry = try Self.upsertAssistantTranscriptEntry(
                    finalEntry,
                    in: db
                )
                try Self.advanceAssistantConversationActivity(
                    conversationID: conversation.id,
                    to: finalEntry.dateModified,
                    in: db
                )
            }
            try db.execute(
                sql: """
                    UPDATE assistantTurn
                    SET status = ?, failureKind = ?,
                        resolvedModel = COALESCE(?, resolvedModel),
                        resolvedEffort = COALESCE(?, resolvedEffort),
                        inputTokens = ?, outputTokens = ?, cacheReadTokens = ?,
                        cacheCreationTokens = ?, totalCostUSD = ?,
                        finishedAt = ?, dateModified = ?
                    WHERE id = ? AND status IN ('queued', 'starting', 'running')
                    """,
                arguments: [
                    turnStatus.rawValue, Self.nonBlank(turnFailureKind),
                    Self.nonBlank(completion?.resolvedModel),
                    Self.nonBlank(completion?.resolvedEffort),
                    completion?.inputTokens, completion?.outputTokens,
                    completion?.cacheReadTokens, completion?.cacheCreationTokens,
                    completion?.totalCostUSD, date, date, turnID,
                ]
            )
            guard db.changesCount == 1 else {
                throw AssistantConversationError.notFound
            }
            try Self.finishStreamingAssistantEntries(
                turnID: turnID,
                turnStatus: turnStatus,
                at: date,
                in: db
            )
            let visibleCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM assistantTranscriptEntry WHERE turnId = ?",
                arguments: [turnID]
            ) ?? 0
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun
                    SET status = ?, failureKind = ?, finishedAt = ?, isUnread = 1,
                        assistantTranscriptState = ?,
                        assistantTranscriptStatusCode = ?
                    WHERE id = ? AND status IN ('pending', 'running')
                    """,
                arguments: [
                    runStatus.rawValue, runFailureKind?.rawValue, date,
                    visibleCount > 0 ? AssistantTranscriptState.finishingIdentity.rawValue
                        : AssistantTranscriptState.none.rawValue,
                    visibleCount > 0 ? nil : AssistantTranscriptStatusCode.interrupted.rawValue,
                    runID,
                ]
            )
            guard db.changesCount == 1 else {
                throw AssistantConversationError.notFound
            }
            return true
        }
    }

    /// Publishes a terminal scheduled transcript for continuation only after the
    /// provider identity observer has closed. Until this transition, late session
    /// rotation may still update the parent binding and Continue must remain disabled.
    @discardableResult
    public func finishScheduledAssistantIdentity(runID: String) throws -> Bool {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun
                    SET assistantTranscriptState = 'available'
                    WHERE id = ?
                      AND assistantTranscriptState = 'finishingIdentity'
                      AND status IN ('succeeded', 'failed', 'cancelled')
                    """,
                arguments: [runID]
            )
            return db.changesCount == 1
        }
    }

    /// Upserts one logical provider projection while retaining its Rubien row ID
    /// and sequence when a provisional item changes kind (for example tool → paper).
    @discardableResult
    public func upsertAssistantTranscriptEntry(
        _ proposed: AssistantTranscriptEntry
    ) throws -> AssistantTranscriptEntry {
        guard proposed.sequence >= 0, proposed.payloadVersion > 0 else {
            throw AssistantConversationError.invalidOrdinal
        }
        try Self.validateIdentifier(proposed.id)

        return try dbWriter.write { db in
            guard let turn = try AssistantTurn.fetchOne(db, key: proposed.turnId),
                  try AssistantConversation.fetchOne(db, key: turn.conversationId) != nil else {
                throw AssistantConversationError.notFound
            }
            let stored = try Self.upsertAssistantTranscriptEntry(proposed, in: db)
            try Self.advanceAssistantConversationActivity(
                conversationID: turn.conversationId,
                to: stored.dateModified,
                in: db
            )
            return stored
        }
    }

    /// Appends one streaming delta without rewriting the accumulated assistant
    /// body through the SQLite bind/WAL path. Completion still performs one
    /// authoritative full-row upsert, so provider canonicalization can replace a
    /// malformed or divergent stream safely.
    @discardableResult
    public func appendAssistantTranscriptEntryDelta(
        _ proposed: AssistantTranscriptEntry,
        delta: String
    ) throws -> Bool {
        guard proposed.kind == .assistant,
              proposed.status == .streaming,
              proposed.sequence >= 0,
              proposed.payloadVersion > 0,
              !delta.isEmpty else {
            throw AssistantConversationError.invalidIdentifier
        }
        return try dbWriter.write { db in
            guard let turn = try AssistantTurn.fetchOne(db, key: proposed.turnId),
                  try AssistantConversation.fetchOne(
                    db,
                    key: turn.conversationId
                  ) != nil else {
                throw AssistantConversationError.notFound
            }
            if let existing = try AssistantTranscriptEntry.fetchOne(
                db,
                key: proposed.id
            ) {
                guard existing.turnId == proposed.turnId,
                      existing.sequence == proposed.sequence,
                      existing.kind == .assistant else {
                    throw AssistantConversationError.invalidIdentifier
                }
                try db.execute(
                    sql: """
                        UPDATE assistantTranscriptEntry
                        SET body = body || ?,
                            providerItemId = COALESCE(providerItemId, ?),
                            dateModified = ?
                        WHERE id = ? AND status = 'streaming'
                        """,
                    arguments: [
                        delta, Self.nonBlank(proposed.providerItemId),
                        proposed.dateModified, proposed.id,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw AssistantConversationError.notFound
                }
            } else {
                var initial = proposed
                initial.body = delta
                _ = try Self.upsertAssistantTranscriptEntry(initial, in: db)
            }
            try Self.advanceAssistantConversationActivity(
                conversationID: turn.conversationId,
                to: proposed.dateModified,
                in: db
            )
            return true
        }
    }

    public func fetchStoredAssistantAttachmentPaths() throws -> [StoredAssistantAttachmentPath] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT attachment.id, turn.conversationId,
                           attachment.relativePath
                    FROM assistantAttachment AS attachment
                    JOIN assistantTranscriptEntry AS entry
                      ON entry.id = attachment.entryId
                    JOIN assistantTurn AS turn ON turn.id = entry.turnId
                    WHERE attachment.relativePath IS NOT NULL
                    """
            )
            return rows.compactMap { row in
                guard let path = row["relativePath"] as String? else { return nil }
                return StoredAssistantAttachmentPath(
                    id: row["id"],
                    conversationId: row["conversationId"],
                    relativePath: path
                )
            }
        }
    }

    /// Replaces normalized attachment metadata for a user entry. The returned
    /// paths belong to superseded rows and can be removed after commit by the
    /// app-layer attachment store.
    @discardableResult
    public func replaceAssistantAttachments(
        entryID: String,
        with proposed: [StoredAssistantAttachment]
    ) throws -> [String] {
        try Self.validateAttachments(proposed, entryID: entryID)
        return try dbWriter.write { db in
            guard let entry = try AssistantTranscriptEntry.fetchOne(
                db,
                sql: "SELECT * FROM assistantTranscriptEntry WHERE id = ?",
                arguments: [entryID]
            ),
                  entry.kind == .user else {
                throw AssistantConversationError.invalidAttachment
            }
            let obsolete = try String.fetchAll(
                db,
                sql: """
                    SELECT relativePath FROM assistantAttachment
                    WHERE entryId = ? AND relativePath IS NOT NULL
                    """,
                arguments: [entryID]
            )
            try db.execute(
                sql: "DELETE FROM assistantAttachment WHERE entryId = ?",
                arguments: [entryID]
            )
            for var attachment in proposed {
                try attachment.insert(db)
            }
            return obsolete
        }
    }

    @discardableResult
    public func markAssistantTurnStarted(
        id: String,
        providerTurnID: String? = nil,
        at date: Date = Date()
    ) throws -> Bool {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE assistantTurn
                    SET status = 'running', providerTurnId = COALESCE(?, providerTurnId),
                        startedAt = COALESCE(startedAt, ?), dateModified = ?
                    WHERE id = ? AND status IN ('queued', 'starting')
                    """,
                arguments: [Self.nonBlank(providerTurnID), date, date, id]
            )
            return db.changesCount == 1
        }
    }

    @discardableResult
    public func finishAssistantTurn(
        id: String,
        status: AssistantTurnStatus,
        failureKind: String? = nil,
        resolvedModel: String? = nil,
        resolvedEffort: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        totalCostUSD: Double? = nil,
        at date: Date = Date()
    ) throws -> Bool {
        guard status.isTerminal else { return false }
        return try dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE assistantTurn
                    SET status = ?, failureKind = ?, resolvedModel = ?, resolvedEffort = ?,
                        inputTokens = ?, outputTokens = ?, cacheReadTokens = ?,
                        cacheCreationTokens = ?, totalCostUSD = ?,
                        finishedAt = ?, dateModified = ?
                    WHERE id = ? AND status IN ('queued', 'starting', 'running')
                    """,
                arguments: [
                    status.rawValue, Self.nonBlank(failureKind), Self.nonBlank(resolvedModel),
                    Self.nonBlank(resolvedEffort), inputTokens, outputTokens, cacheReadTokens,
                    cacheCreationTokens, totalCostUSD, date, date, id,
                ]
            )
            guard db.changesCount == 1 else { return false }
            try Self.finishStreamingAssistantEntries(
                turnID: id,
                turnStatus: status,
                at: date,
                in: db
            )
            return true
        }
    }

    // MARK: - Provider-session ownership

    public func assistantSessionAliasSnapshot(
        keyHash: String
    ) throws -> AssistantSessionAliasSnapshot {
        try dbWriter.read { db in
            try Self.assistantSessionAliasSnapshot(keyHash: keyHash, in: db)
        }
    }

    /// Claims a hashed provider session and advances continuation state only
    /// when the turn/event tuple is newer than the stored binding.
    @discardableResult
    public func recordAssistantSessionBinding(
        keyHash: String,
        provider: AssistantProvider,
        providerSessionID: String,
        conversationID: String,
        turnOrdinal: Int,
        identityEventOrdinal: Int,
        at date: Date = Date()
    ) throws -> Bool {
        guard turnOrdinal > 0, identityEventOrdinal >= 0,
              Self.nonBlank(keyHash) != nil,
              Self.nonBlank(providerSessionID) != nil else {
            throw AssistantConversationError.invalidOrdinal
        }
        return try dbWriter.write { db in
            guard try AssistantConversation.fetchOne(db, key: conversationID) != nil else {
                throw AssistantConversationError.notFound
            }
            try Self.claimAssistantSessionAlias(
                keyHash: keyHash,
                provider: provider,
                conversationID: conversationID,
                at: date,
                in: db
            )
            return try Self.advanceAssistantSessionBinding(
                providerSessionID: providerSessionID,
                conversationID: conversationID,
                turnOrdinal: turnOrdinal,
                identityEventOrdinal: identityEventOrdinal,
                in: db
            )
        }
    }

    /// Scheduled variant keeps the run's provider pointer and the conversation's
    /// continuation binding in the same transaction.
    @discardableResult
    public func recordScheduledAssistantSessionBinding(
        runID: String,
        keyHash: String,
        provider: AssistantProvider,
        providerSessionID: String,
        conversationID: String,
        turnOrdinal: Int,
        identityEventOrdinal: Int,
        at date: Date = Date()
    ) throws -> Bool {
        guard turnOrdinal > 0, identityEventOrdinal >= 0,
              Self.nonBlank(keyHash) != nil,
              Self.nonBlank(providerSessionID) != nil else {
            throw AssistantConversationError.invalidOrdinal
        }
        return try dbWriter.write { db in
            guard let conversation = try AssistantConversation.fetchOne(
                db,
                key: conversationID
            ), conversation.scheduledJobRunId == runID else {
                throw AssistantConversationError.notFound
            }
            try Self.claimAssistantSessionAlias(
                keyHash: keyHash,
                provider: provider,
                conversationID: conversationID,
                at: date,
                in: db
            )
            let advanced = try Self.advanceAssistantSessionBinding(
                providerSessionID: providerSessionID,
                conversationID: conversationID,
                turnOrdinal: turnOrdinal,
                identityEventOrdinal: identityEventOrdinal,
                in: db
            )
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun SET providerSessionId = ?
                    WHERE id = ? AND status IN ('pending', 'running')
                    """,
                arguments: [providerSessionID, runID]
            )
            guard db.changesCount == 1 else {
                throw AssistantConversationError.notFound
            }
            return advanced
        }
    }

    /// Claims an alias after a provider fetch only if its pre-fetch generation
    /// is still current. A live owner always wins; a tombstone can be reclaimed
    /// only when the caller explicitly allows it.
    public func claimAssistantSessionAlias(
        keyHash: String,
        provider: AssistantProvider,
        conversationID: String,
        snapshot: AssistantSessionAliasSnapshot,
        allowTombstoneReclaim: Bool,
        at date: Date = Date()
    ) throws -> String {
        try dbWriter.write { db in
            guard try AssistantConversation.fetchOne(db, key: conversationID) != nil else {
                throw AssistantConversationError.notFound
            }
            let current = try Self.assistantSessionAliasSnapshot(keyHash: keyHash, in: db)
            switch (snapshot, current) {
            case (.absent, .absent):
                var alias = AssistantSessionAlias(
                    keyHash: keyHash,
                    conversationId: conversationID,
                    provider: provider,
                    recordedAt: date
                )
                try alias.insert(db)
                return conversationID
            case let (.live(expectedOwner, expectedRevision), .live(owner, revision))
                where expectedOwner == owner && expectedRevision == revision:
                return owner
            case (.live, _):
                throw AssistantConversationError.staleAliasSnapshot
            case let (_, .live(owner, _)):
                return owner
            case let (.tombstone(expected), .tombstone(actual))
                where allowTombstoneReclaim && expected == actual:
                try db.execute(
                    sql: """
                        UPDATE assistantSessionAlias
                        SET conversationId = ?, provider = ?,
                            ownerRevision = ownerRevision + 1, recordedAt = ?
                        WHERE keyHash = ? AND conversationId IS NULL AND ownerRevision = ?
                        """,
                    arguments: [conversationID, provider.rawValue, date, keyHash, expected]
                )
                guard db.changesCount == 1 else {
                    throw AssistantConversationError.staleAliasSnapshot
                }
                return conversationID
            default:
                throw AssistantConversationError.staleAliasSnapshot
            }
        }
    }

    /// Splits an immutable scheduled result from its first interactive
    /// continuation. Provider identity is transferred exactly once; reopening
    /// returns the existing child, while deleting that child never silently
    /// creates a replacement.
    public func canContinueScheduledAssistantConversation(
        runID: String
    ) throws -> Bool {
        try dbWriter.read { db in
            guard let run = try ScheduledJobRun.fetchOne(db, key: runID),
                  run.status.isTerminal,
                  run.assistantTranscriptState == .available else {
                return false
            }
            guard let parent = try AssistantConversation.fetchOne(
                db,
                sql: "SELECT * FROM assistantConversation WHERE scheduledJobRunId = ?",
                arguments: [runID]
            ) else { return false }
            if try AssistantConversation.fetchOne(
                db,
                sql: "SELECT * FROM assistantConversation WHERE continuedFromConversationId = ?",
                arguments: [parent.id]
            ) != nil {
                return true
            }
            return parent.continuationTransferredAt == nil
                && Self.nonBlank(parent.latestProviderSessionId) != nil
        }
    }

    @discardableResult
    public func createScheduledAssistantContinuation(
        runID: String,
        childID: String = UUID().uuidString.lowercased(),
        at date: Date = Date()
    ) throws -> AssistantConversation {
        try Self.validateIdentifier(childID)
        return try dbWriter.write { db in
            guard let parent = try AssistantConversation.fetchOne(
                db,
                sql: "SELECT * FROM assistantConversation WHERE scheduledJobRunId = ?",
                arguments: [runID]
            ) else { throw AssistantConversationError.notFound }

            if let existing = try AssistantConversation.fetchOne(
                db,
                sql: "SELECT * FROM assistantConversation WHERE continuedFromConversationId = ?",
                arguments: [parent.id]
            ) {
                return existing
            }
            guard parent.continuationTransferredAt == nil else {
                throw AssistantConversationError.continuationAlreadyTransferred
            }
            guard parent.continuedFromConversationId == nil,
                  let providerSessionID = Self.nonBlank(parent.latestProviderSessionId),
                  let latestTurnOrdinal = parent.latestSessionTurnOrdinal,
                  let latestEventOrdinal = parent.latestSessionEventOrdinal,
                  try !Self.hasNonterminalAssistantTurn(
                    conversationID: parent.id,
                    in: db
                  ),
                  let runStatus = try String.fetchOne(
                    db,
                    sql: "SELECT status FROM scheduledJobRun WHERE id = ?",
                    arguments: [runID]
                  ),
                  ScheduledJobRunStatus(rawValue: runStatus).isTerminal,
                  let transcriptState = try String.fetchOne(
                    db,
                    sql: "SELECT assistantTranscriptState FROM scheduledJobRun WHERE id = ?",
                    arguments: [runID]
                  ),
                  AssistantTranscriptState(rawValue: transcriptState) == .available else {
                throw AssistantConversationError.scheduledResultNotTerminal
            }

            var child = AssistantConversation(
                id: childID,
                provider: parent.provider,
                origin: .rubien,
                workspaceIdentityHash: parent.workspaceIdentityHash,
                contextKind: parent.contextKind,
                referenceId: parent.referenceId,
                continuedFromConversationId: parent.id,
                latestProviderSessionId: providerSessionID,
                latestSessionTurnOrdinal: latestTurnOrdinal,
                latestSessionEventOrdinal: latestEventOrdinal,
                createdAt: date,
                lastActivityAt: date
            )
            try child.insert(db)

            try db.execute(
                sql: """
                    UPDATE assistantSessionAlias
                    SET conversationId = ?, ownerRevision = ownerRevision + 1,
                        recordedAt = ?
                    WHERE conversationId = ?
                    """,
                arguments: [child.id, date, parent.id]
            )
            try db.execute(
                sql: """
                    UPDATE assistantConversation
                    SET latestProviderSessionId = NULL,
                        latestSessionTurnOrdinal = NULL,
                        latestSessionEventOrdinal = NULL,
                        continuationTransferredAt = ?
                    WHERE id = ? AND continuationTransferredAt IS NULL
                    """,
                arguments: [date, parent.id]
            )
            guard db.changesCount == 1 else {
                throw AssistantConversationError.continuationAlreadyTransferred
            }
            return child
        }
    }

    /// Commits a provider transcript and its alias claim as one transaction.
    /// A concurrent live owner wins without replacing its local projection.
    public func importAssistantConversation(
        conversation proposedConversation: AssistantConversation,
        turns proposedTurns: [AssistantTurn],
        entries proposedEntries: [AssistantTranscriptEntry],
        attachments: [StoredAssistantAttachment] = [],
        aliasKeyHash: String,
        aliasSnapshot: AssistantSessionAliasSnapshot,
        allowTombstoneReclaim: Bool,
        at date: Date = Date()
    ) throws -> AssistantConversationImportResult {
        guard Self.nonBlank(aliasKeyHash) != nil else {
            throw AssistantConversationError.invalidIdentifier
        }
        let validated = try Self.validatedAssistantImport(
            conversation: proposedConversation,
            turns: proposedTurns,
            entries: proposedEntries,
            attachments: attachments,
            at: date
        )
        let conversation = validated.conversation

        return try dbWriter.write { db in
            let current = try Self.assistantSessionAliasSnapshot(
                keyHash: aliasKeyHash,
                in: db
            )
            switch (aliasSnapshot, current) {
            case let (.live(expectedOwner, expectedRevision), .live(owner, revision))
                where expectedOwner == owner && expectedRevision == revision:
                return .existing(conversationId: owner)
            case (.live, _):
                throw AssistantConversationError.staleAliasSnapshot
            case let (_, .live(owner, _)):
                return .existing(conversationId: owner)
            case (.absent, .absent):
                break
            case let (.tombstone(expected), .tombstone(actual))
                where allowTombstoneReclaim && expected == actual:
                break
            default:
                throw AssistantConversationError.staleAliasSnapshot
            }

            try Self.insertAssistantImport(validated, in: db)

            switch current {
            case .absent:
                var alias = AssistantSessionAlias(
                    keyHash: aliasKeyHash,
                    conversationId: conversation.id,
                    provider: conversation.provider,
                    recordedAt: date
                )
                try alias.insert(db)
            case .tombstone(let revision):
                try db.execute(
                    sql: """
                        UPDATE assistantSessionAlias
                        SET conversationId = ?, provider = ?,
                            ownerRevision = ownerRevision + 1, recordedAt = ?
                        WHERE keyHash = ? AND conversationId IS NULL
                          AND ownerRevision = ?
                        """,
                    arguments: [
                        conversation.id, conversation.provider.rawValue, date,
                        aliasKeyHash, revision,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw AssistantConversationError.staleAliasSnapshot
                }
            case .live:
                throw AssistantConversationError.staleAliasSnapshot
            }
            return .imported(conversationId: conversation.id)
        }
    }

    // MARK: - Migrated scheduled transcript import

    /// Resolves local ownership and consumes the exact scheduled import state in
    /// one transaction. The caller may contact the provider only for `.admitted`.
    /// Automatic opens consume `legacyEligible`; explicit retries consume
    /// `legacyAttempted` and enter the crash-recoverable `legacyRetrying` state.
    public func admitScheduledAssistantImport(
        runID: String,
        aliasKeyHash: String,
        isRetry: Bool,
        at date: Date = Date()
    ) throws -> ScheduledAssistantImportAdmission {
        guard Self.nonBlank(runID) != nil,
              Self.nonBlank(aliasKeyHash) != nil else {
            throw AssistantConversationError.invalidIdentifier
        }
        return try dbWriter.write { db in
            guard let run = try Row.fetchOne(
                db,
                sql: """
                    SELECT assistantTranscriptState, assistantTranscriptStatusCode
                    FROM scheduledJobRun
                    WHERE id = ? AND hiddenAt IS NULL
                    """,
                arguments: [runID]
            ) else { throw AssistantConversationError.notFound }
            let rawState: String = run["assistantTranscriptState"]
            let state = AssistantTranscriptState(rawValue: rawState)
            let expected: AssistantTranscriptState = isRetry
                ? .legacyAttempted : .legacyEligible
            guard state == expected else { return .notEligible(state: state) }

            switch try Self.assistantSessionAliasSnapshot(
                keyHash: aliasKeyHash,
                in: db
            ) {
            case let .live(conversationID, _):
                try Self.resolveScheduledAssistantImport(
                    runID: runID,
                    expectedState: expected,
                    state: .legacyAttempted,
                    status: .alreadyLocal,
                    in: db
                )
                return .existing(conversationId: conversationID)
            case .tombstone:
                try Self.resolveScheduledAssistantImport(
                    runID: runID,
                    expectedState: expected,
                    state: .legacyAttempted,
                    status: .deletedLocal,
                    in: db
                )
                return .deletedLocally
            case .absent:
                if isRetry {
                    let rawStatus: String? = run["assistantTranscriptStatusCode"]
                    guard rawStatus.map(
                        AssistantTranscriptStatusCode.init(rawValue:)
                    )?.isRetryable == true else {
                        return .notEligible(state: state)
                    }
                }
                try Self.resolveScheduledAssistantImport(
                    runID: runID,
                    expectedState: expected,
                    state: isRetry ? .legacyRetrying : .legacyAttempted,
                    status: nil,
                    in: db
                )
                return .admitted
            }
        }
    }

    /// Stores a failed/cancelled admitted import without changing the scheduled
    /// execution result. Reopen never retries automatically; only explicit Retry
    /// can move `legacyAttempted` back through the provider metadata lane.
    @discardableResult
    public func failScheduledAssistantImport(
        runID: String,
        status: AssistantTranscriptStatusCode,
        at date: Date = Date()
    ) throws -> Bool {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun
                    SET assistantTranscriptState = 'legacyAttempted',
                        assistantTranscriptStatusCode = ?
                    WHERE id = ?
                      AND assistantTranscriptState IN ('legacyAttempted', 'legacyRetrying')
                      AND hiddenAt IS NULL
                    """,
                arguments: [status.rawValue, runID]
            )
            return db.changesCount == 1
        }
    }

    /// Gives an import admission back when the provider's metadata scheduler did
    /// not admit a read. The exact-state compare-and-swap prevents this process
    /// from undoing a concurrent retry or completed import.
    @discardableResult
    public func deferScheduledAssistantImport(
        runID: String,
        isRetry: Bool
    ) throws -> Bool {
        guard Self.nonBlank(runID) != nil else {
            throw AssistantConversationError.invalidIdentifier
        }
        let admittedState: AssistantTranscriptState = isRetry
            ? .legacyRetrying : .legacyAttempted
        let restoredState: AssistantTranscriptState = isRetry
            ? .legacyAttempted : .legacyEligible
        return try dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun
                    SET assistantTranscriptState = ?
                    WHERE id = ?
                      AND assistantTranscriptState = ?
                      AND assistantTranscriptStatusCode IS NULL
                      AND hiddenAt IS NULL
                    """,
                arguments: [
                    restoredState.rawValue, runID, admittedState.rawValue,
                ]
            )
            return db.changesCount == 1
        }
    }

    /// Atomically inserts an imported provider transcript, claims its alias, links
    /// it to the historical run, and publishes the run as locally available.
    public func completeScheduledAssistantImport(
        runID: String,
        conversation proposedConversation: AssistantConversation,
        turns proposedTurns: [AssistantTurn],
        entries proposedEntries: [AssistantTranscriptEntry],
        attachments: [StoredAssistantAttachment] = [],
        aliasKeyHash: String,
        at date: Date = Date()
    ) throws -> ScheduledAssistantImportResult {
        guard Self.nonBlank(aliasKeyHash) != nil else {
            throw AssistantConversationError.invalidIdentifier
        }
        let validated = try Self.validatedAssistantImport(
            conversation: proposedConversation,
            turns: proposedTurns,
            entries: proposedEntries,
            attachments: attachments,
            at: date
        )
        let conversation = validated.conversation
        guard conversation.scheduledJobRunId == runID else {
            throw AssistantConversationError.invalidIdentifier
        }

        return try dbWriter.write { db in
            guard let rawState = try String.fetchOne(
                db,
                sql: """
                    SELECT assistantTranscriptState FROM scheduledJobRun
                    WHERE id = ? AND hiddenAt IS NULL
                    """,
                arguments: [runID]
            ), [.legacyAttempted, .legacyRetrying].contains(
                AssistantTranscriptState(rawValue: rawState)
            ) else { throw AssistantConversationError.staleAliasSnapshot }

            switch try Self.assistantSessionAliasSnapshot(
                keyHash: aliasKeyHash,
                in: db
            ) {
            case let .live(owner, _):
                try db.execute(
                    sql: """
                        UPDATE scheduledJobRun
                        SET assistantTranscriptState = 'legacyAttempted',
                            assistantTranscriptStatusCode = 'alreadyLocal'
                        WHERE id = ?
                        """,
                    arguments: [runID]
                )
                return .existing(conversationId: owner)
            case .tombstone:
                try db.execute(
                    sql: """
                        UPDATE scheduledJobRun
                        SET assistantTranscriptState = 'legacyAttempted',
                            assistantTranscriptStatusCode = 'deletedLocal'
                        WHERE id = ?
                        """,
                    arguments: [runID]
                )
                return .deletedLocally
            case .absent:
                break
            }

            try Self.insertAssistantImport(validated, in: db)
            var alias = AssistantSessionAlias(
                keyHash: aliasKeyHash,
                conversationId: conversation.id,
                provider: conversation.provider,
                recordedAt: date
            )
            try alias.insert(db)
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun
                    SET assistantTranscriptState = 'available',
                        assistantTranscriptStatusCode = NULL
                    WHERE id = ?
                      AND assistantTranscriptState IN ('legacyAttempted', 'legacyRetrying')
                    """,
                arguments: [runID]
            )
            guard db.changesCount == 1 else {
                throw AssistantConversationError.staleAliasSnapshot
            }
            return .imported(conversationId: conversation.id)
        }
    }

    // MARK: - Delete, clear, and recovery

    public func hasActiveAssistantWork() throws -> Bool {
        try dbWriter.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM assistantTurn
                        WHERE status IN ('queued', 'starting', 'running')
                    ) OR EXISTS(
                        SELECT 1 FROM scheduledJobRun
                        WHERE status IN ('pending', 'running')
                    )
                    """
            ) ?? false
        }
    }

    public func deleteAssistantConversation(id: String) throws {
        try dbWriter.write { db in
            guard try AssistantConversation.fetchOne(db, key: id) != nil else {
                throw AssistantConversationError.notFound
            }
            guard try !Self.hasNonterminalAssistantTurn(conversationID: id, in: db) else {
                throw AssistantConversationError.activeConversation
            }
            try Self.markLinkedRunTranscriptDeleted(conversationID: id, in: db)
            try db.execute(sql: "DELETE FROM assistantConversation WHERE id = ?", arguments: [id])
        }
    }

    @discardableResult
    public func clearAssistantConversations(before date: Date? = nil) throws -> Int {
        try dbWriter.write { db in
            var sql = """
                SELECT conversation.id,
                       EXISTS (
                    SELECT 1 FROM assistantTurn AS turn
                    WHERE turn.conversationId = conversation.id
                      AND turn.status IN ('queued', 'starting', 'running')
                ) AS isActive
                FROM assistantConversation AS conversation
                """
            var arguments: StatementArguments = []
            if let date {
                sql += " WHERE lastActivityAt < ?"
                arguments = [date]
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            guard !rows.contains(where: { (row: Row) in
                (row["isActive"] as Bool?) == true
            }) else {
                throw AssistantConversationError.activeConversation
            }
            let ids = rows.map { (row: Row) -> String in row["id"] }
            for id in ids {
                try Self.markLinkedRunTranscriptDeleted(conversationID: id, in: db)
                try db.execute(
                    sql: "DELETE FROM assistantConversation WHERE id = ?",
                    arguments: [id]
                )
            }
            return ids.count
        }
    }

    /// Repairs abandoned Assistant work after the process has acquired the
    /// per-library execution lock. The snapshot CTE is materialized before any
    /// status changes so scheduled capture classification is deterministic.
    @discardableResult
    public func recoverInterruptedAssistantWork(at date: Date = Date()) throws -> Int {
        try dbWriter.write { db in
            try db.execute(sql: """
                CREATE TEMP TABLE assistantRecoveryTurnSnapshot AS
                SELECT turn.id AS turnId, turn.conversationId,
                       conversation.scheduledJobRunId,
                       EXISTS(
                           SELECT 1 FROM assistantTranscriptEntry AS entry
                           WHERE entry.turnId = turn.id
                       ) AS hasVisibleEntry
                FROM assistantTurn AS turn
                JOIN assistantConversation AS conversation
                  ON conversation.id = turn.conversationId
                WHERE turn.status IN ('queued', 'starting', 'running')
                """)
            defer {
                try? db.execute(sql: "DROP TABLE IF EXISTS temp.assistantRecoveryTurnSnapshot")
            }

            let interruptedTurns = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM assistantRecoveryTurnSnapshot"
            ) ?? 0
            try db.execute(
                sql: """
                    UPDATE assistantTurn
                    SET status = 'interrupted', failureKind = 'interrupted',
                        finishedAt = ?, dateModified = ?
                    WHERE id IN (SELECT turnId FROM assistantRecoveryTurnSnapshot)
                    """,
                arguments: [date, date]
            )
            try db.execute(sql: """
                UPDATE assistantTranscriptEntry
                SET status = 'interrupted', dateModified = ?
                WHERE status = 'streaming'
                  AND turnId IN (SELECT turnId FROM assistantRecoveryTurnSnapshot)
                """, arguments: [date])

            // Preserve readable partials and remove empty scheduled shells.
            try db.execute(sql: """
                UPDATE scheduledJobRun
                SET assistantTranscriptState = 'available',
                    assistantTranscriptStatusCode = 'interrupted'
                WHERE assistantTranscriptState = 'capturing'
                  AND id IN (
                    SELECT scheduledJobRunId FROM assistantRecoveryTurnSnapshot
                    WHERE scheduledJobRunId IS NOT NULL AND hasVisibleEntry = 1
                  )
                """)
            try db.execute(sql: """
                DELETE FROM assistantConversation
                WHERE scheduledJobRunId IN (
                    SELECT scheduledJobRunId FROM assistantRecoveryTurnSnapshot
                    WHERE scheduledJobRunId IS NOT NULL AND hasVisibleEntry = 0
                )
                """)
            // A crash can happen after linking the conversation but before the
            // first turn is inserted. Such a capturing shell is absent from the
            // turn snapshot above and must not remain permanently openable.
            try db.execute(sql: """
                DELETE FROM assistantConversation
                WHERE scheduledJobRunId IN (
                    SELECT run.id
                    FROM scheduledJobRun AS run
                    JOIN assistantConversation AS conversation
                      ON conversation.scheduledJobRunId = run.id
                    WHERE run.assistantTranscriptState = 'capturing'
                      AND NOT EXISTS (
                          SELECT 1 FROM assistantRecoveryTurnSnapshot AS snapshot
                          WHERE snapshot.conversationId = conversation.id
                      )
                )
                """)
            try db.execute(sql: """
                UPDATE scheduledJobRun
                SET assistantTranscriptState = 'none',
                    assistantTranscriptStatusCode = 'interrupted'
                WHERE assistantTranscriptState = 'capturing'
                  AND NOT EXISTS (
                    SELECT 1 FROM assistantConversation
                    WHERE assistantConversation.scheduledJobRunId = scheduledJobRun.id
                  )
                """)
            try db.execute(sql: """
                UPDATE scheduledJobRun
                SET assistantTranscriptState = 'legacyAttempted',
                    assistantTranscriptStatusCode = 'interrupted'
                WHERE assistantTranscriptState = 'legacyRetrying'
                """)
            try db.execute(sql: """
                UPDATE scheduledJobRun
                SET assistantTranscriptState = 'available'
                WHERE assistantTranscriptState = 'finishingIdentity'
                  AND status IN ('succeeded', 'failed', 'cancelled')
                """)
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun
                    SET status = 'failed',
                        failureKind = CASE status
                            WHEN 'pending' THEN 'interruptedBeforeStart'
                            ELSE 'interrupted'
                        END,
                        finishedAt = ?, isUnread = 1
                    WHERE status IN ('pending', 'running')
                    """,
                arguments: [date]
            )
            return interruptedTurns
        }
    }

    // MARK: - Internal transaction helpers

    private static func validatedNewAssistantConversation(
        _ proposed: AssistantConversation
    ) throws -> AssistantConversation {
        try validateIdentifier(proposed.id)
        guard nonBlank(proposed.provider.rawValue) != nil,
              nonBlank(proposed.origin.rawValue) != nil,
              nonBlank(proposed.contextKind.rawValue) != nil else {
            throw AssistantConversationError.invalidIdentifier
        }
        switch proposed.contextKind {
        case .reference where proposed.referenceId == nil:
            throw AssistantConversationError.invalidContext
        case .library where proposed.referenceId != nil:
            throw AssistantConversationError.invalidContext
        case .unclassified where proposed.referenceId != nil:
            throw AssistantConversationError.invalidContext
        case .unknown:
            throw AssistantConversationError.invalidContext
        default:
            break
        }
        return proposed
    }

    private struct ValidatedAssistantImport {
        var conversation: AssistantConversation
        var turns: [AssistantTurn]
        var entries: [AssistantTranscriptEntry]
        var attachments: [StoredAssistantAttachment]
    }

    private static func validatedAssistantImport(
        conversation proposedConversation: AssistantConversation,
        turns proposedTurns: [AssistantTurn],
        entries proposedEntries: [AssistantTranscriptEntry],
        attachments: [StoredAssistantAttachment],
        at date: Date
    ) throws -> ValidatedAssistantImport {
        var conversation = try validatedNewAssistantConversation(proposedConversation)
        guard conversation.origin == .providerImport,
              nonBlank(conversation.latestProviderSessionId) != nil,
              !proposedTurns.isEmpty else {
            throw AssistantConversationError.invalidIdentifier
        }

        let turnIDs = Set(proposedTurns.map(\.id))
        guard turnIDs.count == proposedTurns.count,
              proposedTurns.allSatisfy({
                  $0.conversationId == conversation.id && $0.ordinal > 0
                      && $0.status.isTerminal
              }),
              Set(proposedTurns.map(\.ordinal)).count == proposedTurns.count,
              proposedEntries.allSatisfy({
                  turnIDs.contains($0.turnId) && $0.sequence >= 0
              }),
              Set(proposedEntries.map { "\($0.turnId)\u{1f}\($0.sequence)" }).count
                == proposedEntries.count else {
            throw AssistantConversationError.invalidOrdinal
        }

        let entryIDs = Set(proposedEntries.map(\.id))
        let attachmentIDs = Set(attachments.map(\.id))
        guard entryIDs.count == proposedEntries.count,
              attachmentIDs.count == attachments.count,
              attachments.allSatisfy({ entryIDs.contains($0.entryId) }) else {
            throw AssistantConversationError.invalidAttachment
        }
        for turn in proposedTurns { try validateIdentifier(turn.id) }
        for entry in proposedEntries { try validateIdentifier(entry.id) }
        for (entryID, rows) in Dictionary(grouping: attachments, by: \.entryId) {
            try validateAttachments(rows, entryID: entryID)
        }

        conversation.lastActivityAt = proposedEntries.map(\.dateModified).max()
            .map { max(conversation.createdAt, $0) }
            ?? date
        let ordinalByTurn = Dictionary(
            uniqueKeysWithValues: proposedTurns.map { ($0.id, $0.ordinal) }
        )
        return ValidatedAssistantImport(
            conversation: conversation,
            turns: proposedTurns.sorted { $0.ordinal < $1.ordinal },
            entries: proposedEntries.sorted {
                let lhsOrdinal = ordinalByTurn[$0.turnId] ?? Int.max
                let rhsOrdinal = ordinalByTurn[$1.turnId] ?? Int.max
                if lhsOrdinal != rhsOrdinal { return lhsOrdinal < rhsOrdinal }
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                return $0.id < $1.id
            },
            attachments: attachments
        )
    }

    private static func insertAssistantImport(
        _ validated: ValidatedAssistantImport,
        in db: Database
    ) throws {
        var conversation = validated.conversation
        try conversation.insert(db)
        for var turn in validated.turns { try turn.insert(db) }
        for var entry in validated.entries { try entry.insert(db) }
        for var attachment in validated.attachments { try attachment.insert(db) }
    }

    private static func resolveScheduledAssistantImport(
        runID: String,
        expectedState: AssistantTranscriptState,
        state: AssistantTranscriptState,
        status: AssistantTranscriptStatusCode?,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE scheduledJobRun
                SET assistantTranscriptState = ?,
                    assistantTranscriptStatusCode = ?
                WHERE id = ? AND assistantTranscriptState = ?
                  AND hiddenAt IS NULL
                """,
            arguments: [state.rawValue, status?.rawValue, runID, expectedState.rawValue]
        )
        guard db.changesCount == 1 else {
            throw AssistantConversationError.staleAliasSnapshot
        }
    }

    private static func upsertAssistantTranscriptEntry(
        _ proposed: AssistantTranscriptEntry,
        in db: Database
    ) throws -> AssistantTranscriptEntry {
        var stored = proposed
        if let providerItemID = nonBlank(proposed.providerItemId),
           let existing = try AssistantTranscriptEntry.fetchOne(
                db,
                sql: """
                    SELECT * FROM assistantTranscriptEntry
                    WHERE turnId = ? AND providerItemId = ?
                    """,
                arguments: [proposed.turnId, providerItemID]
           ) {
            stored.rowId = existing.rowId
            stored.id = existing.id
            stored.sequence = existing.sequence
            stored.providerItemId = providerItemID
            stored.createdAt = existing.createdAt
            try stored.update(db)
        } else if let existing = try AssistantTranscriptEntry.fetchOne(
            db,
            sql: "SELECT * FROM assistantTranscriptEntry WHERE id = ?",
            arguments: [proposed.id]
        ) {
            guard existing.turnId == proposed.turnId else {
                throw AssistantConversationError.invalidIdentifier
            }
            stored.rowId = existing.rowId
            stored.sequence = existing.sequence
            stored.createdAt = existing.createdAt
            try stored.update(db)
        } else {
            try stored.insert(db)
        }
        return stored
    }

    private static func validateIdentifier(_ value: String) throws {
        guard let trimmed = nonBlank(value), trimmed == value, value.count <= 512 else {
            throw AssistantConversationError.invalidIdentifier
        }
    }

    private static func validateAttachments(
        _ attachments: [StoredAssistantAttachment],
        entryID: String
    ) throws {
        var seen = Set<String>()
        for attachment in attachments {
            try validateIdentifier(attachment.id)
            guard attachment.entryId == entryID,
                  seen.insert(attachment.id).inserted,
                  nonBlank(attachment.displayName) != nil,
                  nonBlank(attachment.kind.rawValue) != nil,
                  nonBlank(attachment.mediaType) != nil,
                  attachment.byteCount >= 0,
                  validAssistantRelativePath(attachment.relativePath) else {
                throw AssistantConversationError.invalidAttachment
            }
        }
    }

    private static func validAssistantRelativePath(_ path: String?) -> Bool {
        guard let path else { return true }
        guard let trimmed = nonBlank(path), trimmed == path,
              !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Computes each matching conversation's best FTS rank once, then joins that
    /// compact result to the filtered conversation rows. This avoids re-running
    /// the MATCH/bm25 scan from a correlated ORDER BY subquery for every result.
    private static func fetchRankedAssistantConversations(
        query: AssistantConversationQuery,
        ftsQuery: String,
        in db: Database
    ) throws -> [AssistantConversation] {
        let visibleOrigins = AssistantConversationOrigin.localHistoryRawValues
        let originPlaceholders = Array(repeating: "?", count: visibleOrigins.count)
            .joined(separator: ", ")
        var predicates = ["conversation.origin IN (\(originPlaceholders))"]
        var arguments = StatementArguments([ftsQuery])
        for origin in visibleOrigins {
            _ = arguments.append(contentsOf: [origin])
        }
        if !query.includeArchived {
            predicates.append("conversation.archivedAt IS NULL")
        }
        if let workspace = nonBlank(query.workspaceIdentityHash) {
            predicates.append("conversation.workspaceIdentityHash = ?")
            _ = arguments.append(contentsOf: [workspace])
        }
        if let provider = query.provider {
            predicates.append("conversation.provider = ?")
            _ = arguments.append(contentsOf: [provider.rawValue])
        }
        if let contextKind = query.contextKind {
            predicates.append("conversation.contextKind = ?")
            _ = arguments.append(contentsOf: [contextKind.rawValue])
        }
        if let referenceID = query.referenceId {
            predicates.append("conversation.contextKind = ?")
            predicates.append("conversation.referenceId = ?")
            _ = arguments.append(contentsOf: [
                AssistantConversationContextKind.reference.rawValue,
                referenceID,
            ])
        }
        _ = arguments.append(contentsOf: [min(query.limit, 500)])
        return try AssistantConversation.fetchAll(
            db,
            sql: """
                WITH matchedEntry AS MATERIALIZED (
                    SELECT turn.conversationId,
                           bm25(assistantTranscriptEntryFts) AS rank
                    FROM assistantTranscriptEntryFts
                    JOIN assistantTranscriptEntry AS entry
                      ON entry.rowId = assistantTranscriptEntryFts.rowid
                    JOIN assistantTurn AS turn ON turn.id = entry.turnId
                    WHERE assistantTranscriptEntryFts MATCH ?
                ),
                rankedConversation AS (
                    SELECT conversationId, MIN(rank) AS bestRank
                    FROM matchedEntry
                    GROUP BY conversationId
                )
                SELECT conversation.*
                FROM rankedConversation AS ranked
                JOIN assistantConversation AS conversation
                  ON conversation.id = ranked.conversationId
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY ranked.bestRank ASC,
                         conversation.lastActivityAt DESC,
                         conversation.id DESC
                LIMIT ?
                """,
            arguments: arguments
        )
    }

    private static func assistantFTSQuery(_ raw: String?) -> String? {
        let tokens = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map {
                $0.replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "(", with: "")
                    .replacingOccurrences(of: ")", with: "")
            }
            .filter { !$0.isEmpty } ?? []
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\" *" }.joined(separator: " AND ")
    }

    private static func fetchAssistantConversationDetail(
        conversationID: String,
        before cursor: AssistantTranscriptCursor?,
        limit: Int,
        in db: Database
    ) throws -> AssistantConversationDetail? {
        guard let conversation = try AssistantConversation.fetchOne(
            db,
            key: conversationID
        ) else { return nil }

        let pageLimit = min(
            max(limit, 1),
            AssistantConversationDetail.maximumPageLimit
        )
        if let cursor, cursor.conversationID != conversationID {
            throw AssistantConversationError.invalidTranscriptCursor
        }

        var turnArguments = StatementArguments([conversationID])
        let turnCursorPredicate: String
        if let cursor {
            turnCursorPredicate = "AND ordinal <= ?"
            _ = turnArguments.append(contentsOf: [cursor.turnOrdinal])
        } else {
            turnCursorPredicate = ""
        }
        _ = turnArguments.append(contentsOf: [pageLimit + 1])
        let candidateTurns = try Row.fetchAll(
            db,
            sql: """
                SELECT id, ordinal
                FROM assistantTurn
                WHERE conversationId = ?
                \(turnCursorPredicate)
                ORDER BY ordinal DESC
                LIMIT ?
                """,
            arguments: turnArguments
        )

        // Query each candidate turn through UNIQUE(turnId, sequence). This keeps
        // work proportional to the requested page even when one turn contains
        // a very large tool trace; joining all entries before the cross-turn
        // ORDER BY makes SQLite sort that entire trace.
        var descendingEntries: [(entry: AssistantTranscriptEntry, ordinal: Int)] = []
        descendingEntries.reserveCapacity(pageLimit + 1)
        for turnRow in candidateTurns where descendingEntries.count <= pageLimit {
            let turnID: String = turnRow["id"]
            let turnOrdinal: Int = turnRow["ordinal"]
            var entryArguments = StatementArguments([turnID])
            let entryCursorPredicate: String
            if let cursor, cursor.turnOrdinal == turnOrdinal {
                entryCursorPredicate = "AND sequence < ?"
                _ = entryArguments.append(contentsOf: [cursor.sequence])
            } else {
                entryCursorPredicate = ""
            }
            _ = entryArguments.append(
                contentsOf: [pageLimit + 1 - descendingEntries.count]
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM assistantTranscriptEntry
                    WHERE turnId = ?
                    \(entryCursorPredicate)
                    ORDER BY sequence DESC
                    LIMIT ?
                    """,
                arguments: entryArguments
            )
            descendingEntries.append(contentsOf: rows.map {
                (AssistantTranscriptEntry(row: $0), turnOrdinal)
            })
        }

        let hasOlderEntries = descendingEntries.count > pageLimit
        let pageEntries = Array(descendingEntries.prefix(pageLimit))
        let olderCursor = hasOlderEntries
            ? pageEntries.last.map {
                AssistantTranscriptCursor(
                    conversationID: conversationID,
                    turnOrdinal: $0.ordinal,
                    sequence: $0.entry.sequence
                )
            }
            : nil
        let entries = pageEntries.map(\.entry).reversed()

        let turnIDs = Array(Set(entries.map(\.turnId))).sorted()
        let entryIDs = entries.map(\.id)
        guard !entryIDs.isEmpty else {
            return AssistantConversationDetail(
                conversation: conversation,
                turns: [],
                entries: [],
                attachments: []
            )
        }

        let turnPlaceholders = Array(
            repeating: "?",
            count: turnIDs.count
        ).joined(separator: ",")
        let turns = try AssistantTurn.fetchAll(
            db,
            sql: """
                SELECT * FROM assistantTurn
                WHERE id IN (\(turnPlaceholders))
                ORDER BY ordinal ASC, id ASC
                """,
            arguments: StatementArguments(turnIDs)
        )
        let entryPlaceholders = Array(
            repeating: "?",
            count: entryIDs.count
        ).joined(separator: ",")
        let attachments = try StoredAssistantAttachment.fetchAll(
            db,
            sql: """
                SELECT attachment.*
                FROM assistantAttachment AS attachment
                JOIN assistantTranscriptEntry AS entry ON entry.id = attachment.entryId
                JOIN assistantTurn AS turn ON turn.id = entry.turnId
                WHERE entry.id IN (\(entryPlaceholders))
                ORDER BY turn.ordinal ASC, entry.sequence ASC,
                         attachment.createdAt ASC, attachment.id ASC
                """,
            arguments: StatementArguments(entryIDs)
        )
        return AssistantConversationDetail(
            conversation: conversation,
            turns: turns,
            entries: Array(entries),
            attachments: attachments,
            olderCursor: olderCursor
        )
    }

    private static func claimAssistantSessionAlias(
        keyHash: String,
        provider: AssistantProvider,
        conversationID: String,
        at date: Date,
        in db: Database
    ) throws {
        if let alias = try AssistantSessionAlias.fetchOne(db, key: keyHash) {
            guard alias.conversationId == conversationID else {
                throw AssistantConversationError.aliasConflict
            }
            return
        }
        var alias = AssistantSessionAlias(
            keyHash: keyHash,
            conversationId: conversationID,
            provider: provider,
            recordedAt: date
        )
        try alias.insert(db)
    }

    private static func advanceAssistantSessionBinding(
        providerSessionID: String,
        conversationID: String,
        turnOrdinal: Int,
        identityEventOrdinal: Int,
        in db: Database
    ) throws -> Bool {
        try db.execute(
            sql: """
                UPDATE assistantConversation
                SET latestProviderSessionId = ?,
                    latestSessionTurnOrdinal = ?,
                    latestSessionEventOrdinal = ?
                WHERE id = ?
                  AND (
                    latestSessionTurnOrdinal IS NULL
                    OR latestSessionTurnOrdinal < ?
                    OR (latestSessionTurnOrdinal = ?
                        AND latestSessionEventOrdinal < ?)
                  )
                """,
            arguments: [
                providerSessionID, turnOrdinal, identityEventOrdinal,
                conversationID, turnOrdinal, turnOrdinal, identityEventOrdinal,
            ]
        )
        return db.changesCount == 1
    }

    private static func advanceAssistantConversationActivity(
        conversationID: String,
        to date: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE assistantConversation
                SET lastActivityAt = CASE
                    WHEN lastActivityAt < ? THEN ? ELSE lastActivityAt END
                WHERE id = ?
                """,
            arguments: [date, date, conversationID]
        )
        guard db.changesCount == 1 else {
            throw AssistantConversationError.notFound
        }
    }

    private static func finishStreamingAssistantEntries(
        turnID: String,
        turnStatus: AssistantTurnStatus,
        at date: Date,
        in db: Database
    ) throws {
        let entryStatus: AssistantTranscriptEntryStatus
        switch turnStatus {
        case .succeeded:
            entryStatus = .completed
        case .failed:
            entryStatus = .failed
        case .interrupted:
            entryStatus = .interrupted
        case .queued, .starting, .running, .unknown:
            return
        }
        try db.execute(
            sql: """
                UPDATE assistantTranscriptEntry
                SET status = ?, dateModified = ?
                WHERE turnId = ? AND status = 'streaming'
                """,
            arguments: [entryStatus.rawValue, date, turnID]
        )
    }

    private static func assistantSessionAliasSnapshot(
        keyHash: String,
        in db: Database
    ) throws -> AssistantSessionAliasSnapshot {
        guard let alias = try AssistantSessionAlias.fetchOne(db, key: keyHash) else {
            return .absent
        }
        if let owner = alias.conversationId {
            return .live(conversationId: owner, ownerRevision: alias.ownerRevision)
        }
        return .tombstone(ownerRevision: alias.ownerRevision)
    }

    private static func hasNonterminalAssistantTurn(
        conversationID: String,
        in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM assistantTurn
                    WHERE conversationId = ?
                      AND status IN ('queued', 'starting', 'running')
                )
                """,
            arguments: [conversationID]
        ) ?? false
    }

    private static func markLinkedRunTranscriptDeleted(
        conversationID: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE scheduledJobRun
                SET assistantTranscriptState = 'deleted',
                    assistantTranscriptStatusCode = 'deletedLocal'
                WHERE id = (
                    SELECT scheduledJobRunId FROM assistantConversation WHERE id = ?
                )
                """,
            arguments: [conversationID]
        )
    }
}
