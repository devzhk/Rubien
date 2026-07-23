import XCTest
import GRDB
@testable import RubienCore

final class AssistantConversationDatabaseTests: XCTestCase {
    func testInteractiveTurnRequiresExplicitCreationForMissingConversation() throws {
        let database = try AppDatabase(DatabaseQueue())
        let conversation = AssistantConversation(
            id: "fresh-conversation",
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        )
        let turn = AssistantTurn(
            id: "fresh-turn",
            conversationId: conversation.id,
            ordinal: 0
        )
        let user = AssistantTranscriptEntry(
            id: "fresh-user",
            turnId: turn.id,
            sequence: 0,
            kind: .user,
            body: "Prompt"
        )

        XCTAssertThrowsError(try database.beginInteractiveAssistantTurn(
            conversation: conversation,
            turn: turn,
            userEntry: user,
            allowConversationCreation: false
        )) {
            XCTAssertEqual($0 as? AssistantConversationError, .notFound)
        }
        XCTAssertNil(try database.fetchAssistantConversation(id: conversation.id))

        XCTAssertEqual(try database.beginInteractiveAssistantTurn(
            conversation: conversation,
            turn: turn,
            userEntry: user,
            allowConversationCreation: true
        ).ordinal, 1)
    }

    func testSummaryQueryCanConstrainConversationContext() throws {
        let database = try AppDatabase(DatabaseQueue())
        let library = try database.createAssistantConversation(.init(
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        ))
        var reference = Reference(title: "Reader context")
        _ = try database.saveReference(&reference)
        _ = try database.createAssistantConversation(.init(
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .reference,
            referenceId: try XCTUnwrap(reference.id)
        ))

        let summaries = try database.fetchAssistantConversationSummaries(
            query: .init(
                workspaceIdentityHash: "workspace",
                contextKind: .library
            )
        )

        XCTAssertEqual(summaries.map(\.conversation.id), [library.id])
    }

    func testSummaryPreviewIsWhitespaceNormalizedAndBounded() throws {
        let database = try AppDatabase(DatabaseQueue())
        let conversation = try database.createAssistantConversation(.init(
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        ))
        let turn = AssistantTurn(conversationId: conversation.id, ordinal: 1)
        try database.beginAssistantTurn(
            turn,
            userEntry: .init(
                turnId: turn.id,
                sequence: 0,
                kind: .user,
                body: String(repeating: "  a long\nquestion\t", count: 80)
            )
        )

        let preview = try XCTUnwrap(
            database.fetchAssistantConversationSummaries().first?.preview
        )
        XCTAssertLessThanOrEqual(
            preview.count,
            AssistantConversationSummary.previewCharacterLimit
        )
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertFalse(preview.contains("\t"))
        XCTAssertFalse(preview.contains("  "))
    }

    func testTranscriptDetailPagesNewestEntriesWithScopedTurnsAndAttachments() throws {
        let database = try AppDatabase(DatabaseQueue())
        let conversation = try database.createAssistantConversation(.init(
            provider: .claude,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        ))
        for ordinal in 1...3 {
            let turn = AssistantTurn(
                id: "turn-\(ordinal)",
                conversationId: conversation.id,
                ordinal: ordinal
            )
            let entry = AssistantTranscriptEntry(
                id: "entry-\(ordinal)",
                turnId: turn.id,
                sequence: 0,
                kind: .user,
                body: "Prompt \(ordinal)"
            )
            try database.beginAssistantTurn(
                turn,
                userEntry: entry,
                attachments: [.init(
                    id: "attachment-\(ordinal)",
                    entryId: entry.id,
                    displayName: "note-\(ordinal).md",
                    kind: .text,
                    relativePath: nil,
                    mediaType: "text/markdown",
                    byteCount: Int64(ordinal)
                )]
            )
            XCTAssertTrue(try database.finishAssistantTurn(
                id: turn.id,
                status: .succeeded
            ))
        }

        let newest = try XCTUnwrap(database.fetchAssistantConversationDetail(
            id: conversation.id,
            limit: 2
        ))
        XCTAssertEqual(newest.entries.map(\.body), ["Prompt 2", "Prompt 3"])
        XCTAssertEqual(newest.turns.map(\.ordinal), [2, 3])
        XCTAssertEqual(
            Set(newest.attachments.map(\.id)),
            Set(["attachment-2", "attachment-3"])
        )
        let cursor = try XCTUnwrap(newest.olderCursor)
        XCTAssertEqual(
            AssistantTranscriptCursor(token: cursor.token),
            cursor
        )

        let older = try XCTUnwrap(database.fetchAssistantConversationDetail(
            id: conversation.id,
            before: cursor,
            limit: 2
        ))
        XCTAssertEqual(older.entries.map(\.body), ["Prompt 1"])
        XCTAssertEqual(older.turns.map(\.ordinal), [1])
        XCTAssertEqual(older.attachments.map(\.id), ["attachment-1"])
        XCTAssertNil(older.olderCursor)

        let otherConversation = try database.createAssistantConversation(.init(
            provider: .claude,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        ))
        XCTAssertThrowsError(
            try database.fetchAssistantConversationDetail(
                id: otherConversation.id,
                before: cursor,
                limit: 2
            )
        ) {
            XCTAssertEqual(
                $0 as? AssistantConversationError,
                .invalidTranscriptCursor
            )
        }
    }

    func testTranscriptDetailPagesWithinOneLargeTurn() throws {
        let database = try AppDatabase(DatabaseQueue())
        let conversation = try database.createAssistantConversation(.init(
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        ))
        let turn = AssistantTurn(
            id: "large-turn",
            conversationId: conversation.id,
            ordinal: 1
        )
        try database.beginAssistantTurn(
            turn,
            userEntry: AssistantTranscriptEntry(
                id: "large-entry-0",
                turnId: turn.id,
                sequence: 0,
                kind: .user,
                body: "Prompt"
            )
        )
        try database.dbWriter.write { db in
            for sequence in 1...1_000 {
                var entry = AssistantTranscriptEntry(
                    id: "large-entry-\(sequence)",
                    turnId: turn.id,
                    sequence: sequence,
                    kind: .tool,
                    body: "Tool \(sequence)"
                )
                try entry.insert(db)
            }
        }

        let newest = try XCTUnwrap(
            database.fetchAssistantConversationDetail(
                id: conversation.id,
                limit: 7
            )
        )
        XCTAssertEqual(
            newest.entries.map(\.sequence),
            Array(994...1_000)
        )

        let older = try XCTUnwrap(
            database.fetchAssistantConversationDetail(
                id: conversation.id,
                before: try XCTUnwrap(newest.olderCursor),
                limit: 7
            )
        )
        XCTAssertEqual(
            older.entries.map(\.sequence),
            Array(987...993)
        )
    }

    func testBeginUpsertSearchAndDirectCascadeKeepFTSConsistent() throws {
        let queue = try DatabaseQueue()
        let database = try AppDatabase(queue)
        let conversation = try database.createAssistantConversation(
            .init(
                provider: .codex,
                workspaceIdentityHash: "workspace-a",
                contextKind: .library,
                createdAt: date("2026-07-22T10:00:00Z")
            )
        )
        let turn = AssistantTurn(
            conversationId: conversation.id,
            ordinal: 1,
            requestedModel: "gpt-test",
            dateModified: date("2026-07-22T10:00:01Z")
        )
        let userEntry = AssistantTranscriptEntry(
            turnId: turn.id,
            sequence: 0,
            kind: .user,
            body: "Explain latent geometry",
            status: .completed,
            createdAt: date("2026-07-22T10:00:01Z")
        )
        try database.beginAssistantTurn(turn, userEntry: userEntry)

        let provisional = try database.upsertAssistantTranscriptEntry(
            .init(
                turnId: turn.id,
                sequence: 1,
                providerItemId: "item-1",
                kind: .tool,
                body: "lookup",
                status: .streaming,
                createdAt: date("2026-07-22T10:00:02Z")
            )
        )
        let replacement = try database.upsertAssistantTranscriptEntry(
            .init(
                turnId: turn.id,
                sequence: 99,
                providerItemId: "item-1",
                kind: .paper,
                body: "Spectral Cartography",
                status: .completed,
                createdAt: date("2026-07-22T10:00:03Z")
            )
        )
        XCTAssertEqual(replacement.id, provisional.id)
        XCTAssertEqual(replacement.sequence, provisional.sequence)

        let search = try database.fetchAssistantConversationSummaries(
            query: .init(
                workspaceIdentityHash: "workspace-a",
                search: "spectral cart",
                limit: 10
            )
        )
        XCTAssertEqual(search.map(\.conversation.id), [conversation.id])
        XCTAssertEqual(search.first?.preview, "Explain latent geometry")
        XCTAssertEqual(search.first?.turnCount, 1)

        try queue.write { db in
            try db.execute(sql: "DELETE FROM assistantTurn WHERE id = ?", arguments: [turn.id])
        }
        let remainingFTSRows = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assistantTranscriptEntryFts") ?? -1
        }
        XCTAssertEqual(remainingFTSRows, 0)
        XCTAssertTrue(
            try database.fetchAssistantConversationSummaries(
                query: .init(search: "spectral", limit: 10)
            ).isEmpty
        )
    }

    func testSearchDeduplicatesMatchingEntriesBeforeApplyingConversationLimit() throws {
        let database = try AppDatabase(DatabaseQueue())
        let older = try database.createAssistantConversation(.init(
            id: "older-search-conversation",
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library,
            createdAt: date("2026-07-22T10:00:00Z")
        ))
        let newer = try database.createAssistantConversation(.init(
            id: "newer-search-conversation",
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library,
            createdAt: date("2026-07-22T11:00:00Z")
        ))

        let olderTurn = AssistantTurn(
            id: "older-search-turn",
            conversationId: older.id,
            ordinal: 1
        )
        try database.beginAssistantTurn(
            olderTurn,
            userEntry: .init(
                id: "older-search-entry",
                turnId: olderTurn.id,
                sequence: 0,
                kind: .user,
                body: "spectral match",
                createdAt: date("2026-07-22T10:00:01Z")
            )
        )

        let newerTurn = AssistantTurn(
            id: "newer-search-turn",
            conversationId: newer.id,
            ordinal: 1
        )
        try database.beginAssistantTurn(
            newerTurn,
            userEntry: .init(
                id: "newer-search-entry-1",
                turnId: newerTurn.id,
                sequence: 0,
                kind: .user,
                body: "spectral match",
                createdAt: date("2026-07-22T11:00:01Z")
            )
        )
        _ = try database.upsertAssistantTranscriptEntry(.init(
            id: "newer-search-entry-2",
            turnId: newerTurn.id,
            sequence: 1,
            kind: .assistant,
            body: "spectral match",
            createdAt: date("2026-07-22T11:00:02Z")
        ))

        let results = try database.fetchAssistantConversationSummaries(
            query: .init(
                workspaceIdentityHash: "workspace",
                search: "spectral",
                limit: 2
            )
        )

        XCTAssertEqual(
            results.map(\.conversation.id),
            [newer.id, older.id]
        )
    }

    func testSyntheticEntryIDUpsertKeepsRowAndSequence() throws {
        let database = try AppDatabase(DatabaseQueue())
        let conversation = try database.createAssistantConversation(.init(
            provider: .claude,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        ))
        let turn = AssistantTurn(conversationId: conversation.id, ordinal: 1)
        try database.beginAssistantTurn(
            turn,
            userEntry: .init(turnId: turn.id, sequence: 0, kind: .user, body: "Prompt")
        )
        let entryID = UUID().uuidString.lowercased()
        let first = try database.upsertAssistantTranscriptEntry(.init(
            id: entryID,
            turnId: turn.id,
            sequence: 1,
            kind: .assistant,
            body: "Part",
            status: .streaming
        ))
        let completed = try database.upsertAssistantTranscriptEntry(.init(
            id: entryID,
            turnId: turn.id,
            sequence: 99,
            kind: .assistant,
            body: "Part complete",
            status: .completed
        ))

        XCTAssertEqual(completed.id, first.id)
        XCTAssertEqual(completed.sequence, 1)
        let detail = try XCTUnwrap(
            database.fetchAssistantConversationDetail(id: conversation.id)
        )
        XCTAssertEqual(detail.entries.map(\.body), ["Prompt", "Part complete"])
    }

    func testFinishingTurnClosesEveryStreamingProjection() throws {
        let database = try AppDatabase(DatabaseQueue())
        let conversation = try database.createAssistantConversation(.init(
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        ))
        let turn = AssistantTurn(conversationId: conversation.id, ordinal: 1)
        try database.beginAssistantTurn(
            turn,
            userEntry: .init(turnId: turn.id, sequence: 0, kind: .user, body: "Prompt")
        )
        try database.upsertAssistantTranscriptEntry(.init(
            turnId: turn.id,
            sequence: 1,
            kind: .assistant,
            body: "Partial answer",
            status: .streaming
        ))
        try database.upsertAssistantTranscriptEntry(.init(
            turnId: turn.id,
            sequence: 2,
            kind: .tool,
            body: "tool",
            status: .streaming
        ))

        XCTAssertTrue(try database.finishAssistantTurn(
            id: turn.id,
            status: .interrupted
        ))
        let detail = try XCTUnwrap(
            database.fetchAssistantConversationDetail(id: conversation.id)
        )
        XCTAssertEqual(
            detail.entries.dropFirst().map(\.status),
            [.interrupted, .interrupted]
        )
    }

    func testUnknownStorageValuesDecodeSafelyAndFuturePayloadFallsBack() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        let now = date("2026-07-22T10:00:00Z")

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO assistantConversation (
                        id, provider, origin, contextKind, createdAt, lastActivityAt
                    ) VALUES ('future-conversation', 'future-provider',
                              'future-origin', 'future-context', ?, ?)
                    """,
                arguments: [now, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO assistantTurn (
                        id, conversationId, ordinal, status, dateModified
                    ) VALUES ('future-turn', 'future-conversation', 1,
                              'future-status', ?)
                    """,
                arguments: [now]
            )
            try db.execute(
                sql: """
                    INSERT INTO assistantTranscriptEntry (
                        id, turnId, sequence, kind, body, payloadVersion,
                        payloadJSON, searchText, status, createdAt, dateModified
                    ) VALUES ('future-entry', 'future-turn', 0, 'future-kind',
                              'Visible fallback', 99, '{"future":true}',
                              'visible fallback', 'future-entry-status', ?, ?)
                    """,
                arguments: [now, now]
            )
        }

        let detail = try XCTUnwrap(
            AppDatabase(queue).fetchAssistantConversationDetail(id: "future-conversation")
        )
        XCTAssertEqual(detail.conversation.provider, .unknown("future-provider"))
        XCTAssertEqual(detail.conversation.origin, .unknown("future-origin"))
        // Unknown context with no reference decodes into the safe detached bucket.
        XCTAssertEqual(detail.conversation.contextKind, .unclassified)
        XCTAssertEqual(detail.turns.first?.status, .unknown("future-status"))
        XCTAssertEqual(detail.entries.first?.kind, .unknown("future-kind"))
        XCTAssertEqual(detail.entries.first?.status, .unknown("future-entry-status"))
        XCTAssertTrue(detail.entries.first?.hasUnavailablePayloadDetails == true)
        XCTAssertEqual(detail.entries.first?.body, "Visible fallback")
    }

    func testCurrentPayloadVersionDoesNotParsePayloadDuringListing() {
        let entry = AssistantTranscriptEntry(
            turnId: "turn",
            sequence: 1,
            kind: .tool,
            body: "Visible fallback",
            payloadVersion: AssistantTranscriptEntry.currentPayloadVersion,
            payloadJSON: "{not parsed by the model layer"
        )

        XCTAssertFalse(entry.hasUnavailablePayloadDetails)
    }

    func testSessionBindingIsMonotonicAndDeletionLeavesTombstone() throws {
        let database = try AppDatabase(DatabaseQueue())
        let conversation = try database.createAssistantConversation(
            .init(
                provider: .claude,
                workspaceIdentityHash: "workspace",
                contextKind: .library
            )
        )

        XCTAssertTrue(try database.recordAssistantSessionBinding(
            keyHash: "alias-new",
            provider: .claude,
            providerSessionID: "session-new",
            conversationID: conversation.id,
            turnOrdinal: 2,
            identityEventOrdinal: 3
        ))
        XCTAssertFalse(try database.recordAssistantSessionBinding(
            keyHash: "alias-old",
            provider: .claude,
            providerSessionID: "session-old",
            conversationID: conversation.id,
            turnOrdinal: 1,
            identityEventOrdinal: 99
        ))
        XCTAssertEqual(
            try database.fetchAssistantConversation(id: conversation.id)?.latestProviderSessionId,
            "session-new"
        )

        try database.deleteAssistantConversation(id: conversation.id)
        XCTAssertEqual(
            try database.assistantSessionAliasSnapshot(keyHash: "alias-new"),
            .tombstone(ownerRevision: 2)
        )
        XCTAssertEqual(
            try database.assistantSessionAliasSnapshot(keyHash: "alias-old"),
            .tombstone(ownerRevision: 2)
        )
    }

    func testActiveDeleteRejectedThenScheduledRunDeleteScrubsTranscript() throws {
        let database = try AppDatabase(DatabaseQueue())
        let job = try database.createScheduledJob(
            .init(
                name: "Morning papers",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 480),
                provider: .codex
            ),
            now: date("2026-07-22T07:00:00Z"),
            calendar: utcCalendar()
        )
        let claim = try database.claimManualScheduledJob(id: job.id)
        let conversation = try database.createAssistantConversation(
            .init(
                provider: .codex,
                workspaceIdentityHash: "workspace",
                contextKind: .library,
                scheduledJobRunId: claim.run.id
            )
        )
        let turn = AssistantTurn(conversationId: conversation.id, ordinal: 1)
        try database.beginAssistantTurn(
            turn,
            userEntry: .init(turnId: turn.id, sequence: 0, kind: .user, body: "Run")
        )

        XCTAssertThrowsError(try database.deleteAssistantConversation(id: conversation.id)) {
            XCTAssertEqual($0 as? AssistantConversationError, .activeConversation)
        }
        XCTAssertThrowsError(try database.clearAssistantConversations()) {
            XCTAssertEqual($0 as? AssistantConversationError, .activeConversation)
        }
        XCTAssertNotNil(try database.fetchAssistantConversation(id: conversation.id))
        XCTAssertTrue(try database.finishAssistantTurn(id: turn.id, status: .succeeded))
        XCTAssertTrue(try database.finishScheduledJobRun(id: claim.run.id, status: .succeeded))
        try database.deleteScheduledJobRun(id: claim.run.id)

        XCTAssertNil(try database.fetchAssistantConversation(id: conversation.id))
        let hidden = try database.dbWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT hiddenAt, assistantTranscriptState,
                           assistantTranscriptStatusCode
                    FROM scheduledJobRun WHERE id = ?
                    """,
                arguments: [claim.run.id]
            )
        }
        XCTAssertNotNil(hidden?["hiddenAt"] as Date?)
        XCTAssertEqual(hidden?["assistantTranscriptState"] as String?, "deleted")
        XCTAssertEqual(hidden?["assistantTranscriptStatusCode"] as String?, "deletedLocal")
    }

    func testRecoveryPreservesDurableScheduledPartialAndRemovesEmptyShell() throws {
        let database = try AppDatabase(DatabaseQueue())
        let job = try database.createScheduledJob(
            .init(
                name: "Morning papers",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 480),
                provider: .codex
            ),
            now: date("2026-07-22T07:00:00Z"),
            calendar: utcCalendar()
        )

        let durable = try database.claimManualScheduledJob(id: job.id)
        let durableConversation = try database.createAssistantConversation(
            .init(
                provider: .codex,
                workspaceIdentityHash: "workspace",
                contextKind: .library,
                scheduledJobRunId: durable.run.id
            )
        )
        let durableTurn = AssistantTurn(conversationId: durableConversation.id, ordinal: 1)
        try database.beginAssistantTurn(
            durableTurn,
            userEntry: .init(
                turnId: durableTurn.id,
                sequence: 0,
                kind: .user,
                body: "Persisted prompt"
            )
        )
        XCTAssertTrue(try database.markScheduledJobRunStarted(id: durable.run.id))

        // The scheduler serializes claims; insert a second pending run directly
        // to exercise the empty-capture branch in the same recovery snapshot.
        let emptyRunID = "empty-run"
        let emptyConversation = AssistantConversation(
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library,
            scheduledJobRunId: emptyRunID
        )
        let emptyTurn = AssistantTurn(conversationId: emptyConversation.id, ordinal: 1)
        try database.dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO scheduledJobRun (
                        id, jobId, trigger, occurrenceKey, scheduledFor, status,
                        provider, isUnread, assistantTranscriptState
                    ) VALUES (?, ?, 'manual', 'manual/empty', ?, 'running',
                              'codex', 0, 'capturing')
                    """,
                arguments: [emptyRunID, job.id, Date()]
            )
            var candidate = emptyConversation
            try candidate.insert(db)
            var candidateTurn = emptyTurn
            try candidateTurn.insert(db)
        }

        let missingTurnRunID = "missing-turn-run"
        let missingTurnConversation = AssistantConversation(
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library,
            scheduledJobRunId: missingTurnRunID
        )
        try database.dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO scheduledJobRun (
                        id, jobId, trigger, occurrenceKey, scheduledFor, status,
                        provider, isUnread, assistantTranscriptState
                    ) VALUES (?, ?, 'manual', 'manual/missing-turn', ?, 'running',
                              'codex', 0, 'capturing')
                    """,
                arguments: [missingTurnRunID, job.id, Date()]
            )
            var candidate = missingTurnConversation
            try candidate.insert(db)
        }

        XCTAssertEqual(try database.recoverInterruptedAssistantWork(), 2)
        XCTAssertEqual(
            try database.fetchScheduledJobRun(id: durable.run.id)?.assistantTranscriptState,
            .available
        )
        XCTAssertEqual(
            try database.fetchScheduledJobRun(id: durable.run.id)?.status,
            .failed
        )
        XCTAssertNotNil(try database.fetchAssistantConversation(id: durableConversation.id))
        XCTAssertNil(try database.fetchAssistantConversation(id: emptyConversation.id))
        XCTAssertEqual(
            try database.fetchScheduledJobRun(id: emptyRunID)?.assistantTranscriptState,
            AssistantTranscriptState.none
        )
        XCTAssertNil(try database.fetchAssistantConversation(
            id: missingTurnConversation.id
        ))
        XCTAssertEqual(
            try database.fetchScheduledJobRun(id: missingTurnRunID)?
                .assistantTranscriptState,
            AssistantTranscriptState.none
        )
    }

    func testScheduledContinuationTransfersIdentityOnceAndPreservesOrdinal() throws {
        let database = try AppDatabase(DatabaseQueue())
        let job = try database.createScheduledJob(
            .init(
                name: "Morning papers",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 480),
                provider: .codex
            ),
            now: date("2026-07-22T07:00:00Z"),
            calendar: utcCalendar()
        )
        let claim = try database.claimManualScheduledJob(id: job.id)
        let parent = try database.createAssistantConversation(.init(
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library,
            scheduledJobRunId: claim.run.id
        ))
        let scheduledTurn = AssistantTurn(conversationId: parent.id, ordinal: 1)
        try database.beginAssistantTurn(
            scheduledTurn,
            userEntry: .init(
                turnId: scheduledTurn.id,
                sequence: 0,
                kind: .user,
                body: "Find papers"
            )
        )
        XCTAssertTrue(try database.recordScheduledAssistantSessionBinding(
            runID: claim.run.id,
            keyHash: "scheduled-alias",
            provider: .codex,
            providerSessionID: "thread-1",
            conversationID: parent.id,
            turnOrdinal: 1,
            identityEventOrdinal: 2
        ))
        XCTAssertTrue(try database.finishScheduledAssistantCapture(
            runID: claim.run.id,
            turnID: scheduledTurn.id,
            runStatus: .succeeded,
            turnStatus: .succeeded
        ))
        XCTAssertFalse(try database.canContinueScheduledAssistantConversation(
            runID: claim.run.id
        ))
        XCTAssertTrue(try database.finishScheduledAssistantIdentity(runID: claim.run.id))
        XCTAssertTrue(try database.canContinueScheduledAssistantConversation(
            runID: claim.run.id
        ))

        let child = try database.createScheduledAssistantContinuation(
            runID: claim.run.id,
            childID: "continuation-child"
        )
        XCTAssertTrue(try database.canContinueScheduledAssistantConversation(
            runID: claim.run.id
        ))
        XCTAssertEqual(child.continuedFromConversationId, parent.id)
        XCTAssertEqual(child.latestProviderSessionId, "thread-1")
        XCTAssertEqual(
            try database.assistantSessionAliasSnapshot(keyHash: "scheduled-alias"),
            .live(conversationId: child.id, ownerRevision: 2)
        )
        let storedParent = try XCTUnwrap(database.fetchAssistantConversation(id: parent.id))
        XCTAssertNil(storedParent.latestProviderSessionId)
        XCTAssertNotNil(storedParent.continuationTransferredAt)
        XCTAssertEqual(
            try database.createScheduledAssistantContinuation(runID: claim.run.id).id,
            child.id
        )

        let continuationTurn = AssistantTurn(conversationId: child.id, ordinal: 1)
        let allocated = try database.beginInteractiveAssistantTurn(
            conversation: child,
            turn: continuationTurn,
            userEntry: .init(
                turnId: continuationTurn.id,
                sequence: 0,
                kind: .user,
                body: "Continue"
            ),
            allowConversationCreation: false
        )
        XCTAssertEqual(allocated.ordinal, 2)
        XCTAssertTrue(try database.finishAssistantTurn(
            id: continuationTurn.id,
            status: .succeeded
        ))
        try database.deleteAssistantConversation(id: child.id)
        XCTAssertFalse(try database.canContinueScheduledAssistantConversation(
            runID: claim.run.id
        ))
        XCTAssertThrowsError(
            try database.createScheduledAssistantContinuation(runID: claim.run.id)
        ) {
            XCTAssertEqual(
                $0 as? AssistantConversationError,
                .continuationAlreadyTransferred
            )
        }
    }

    func testScheduledCaptureFinishesRunTurnAndStreamingRowsAtomicallyOnce() throws {
        let database = try AppDatabase(DatabaseQueue())
        let job = try database.createScheduledJob(
            .init(
                name: "Capture",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 480),
                provider: .codex
            ),
            now: date("2026-07-22T07:00:00Z"),
            calendar: utcCalendar()
        )
        let claim = try database.claimManualScheduledJob(id: job.id)
        let conversation = AssistantConversation(
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library,
            scheduledJobRunId: claim.run.id
        )
        let turn = AssistantTurn(
            conversationId: conversation.id,
            ordinal: 1,
            status: .starting
        )
        let user = AssistantTranscriptEntry(
            turnId: turn.id,
            sequence: 0,
            kind: .user,
            body: "Find papers",
            status: .completed
        )
        try database.beginScheduledAssistantCapture(
            runID: claim.run.id,
            conversation: conversation,
            turn: turn,
            userEntry: user
        )
        try database.upsertAssistantTranscriptEntry(.init(
            turnId: turn.id,
            sequence: 1,
            kind: .tool,
            body: "search",
            status: .streaming
        ))
        let final = AssistantTranscriptEntry(
            turnId: turn.id,
            sequence: 2,
            kind: .assistant,
            body: "Durable partial",
            status: .failed
        )

        XCTAssertTrue(try database.finishScheduledAssistantCapture(
            runID: claim.run.id,
            turnID: turn.id,
            runStatus: .failed,
            runFailureKind: .storageFailure,
            turnStatus: .failed,
            turnFailureKind: "storageFailure",
            finalEntry: final
        ))
        XCTAssertFalse(try database.finishScheduledAssistantCapture(
            runID: claim.run.id,
            turnID: turn.id,
            runStatus: .succeeded,
            turnStatus: .succeeded,
            finalEntry: .init(
                turnId: turn.id,
                sequence: 3,
                kind: .assistant,
                body: "Must not be inserted"
            )
        ))

        let storedRun = try XCTUnwrap(database.fetchScheduledJobRun(id: claim.run.id))
        XCTAssertEqual(storedRun.status, .failed)
        XCTAssertEqual(storedRun.failureKind, .storageFailure)
        XCTAssertEqual(storedRun.assistantTranscriptState, .finishingIdentity)
        XCTAssertFalse(try database.canContinueScheduledAssistantConversation(
            runID: claim.run.id
        ))
        XCTAssertTrue(try database.finishScheduledAssistantIdentity(runID: claim.run.id))
        XCTAssertEqual(
            try database.fetchScheduledJobRun(id: claim.run.id)?.assistantTranscriptState,
            .available
        )
        let detail = try XCTUnwrap(
            database.fetchAssistantConversationDetail(id: conversation.id)
        )
        XCTAssertEqual(detail.turns.first?.status, .failed)
        XCTAssertEqual(detail.entries.map(\.body), [
            "Find papers", "search", "Durable partial",
        ])
        XCTAssertEqual(detail.entries[1].status, .failed)
    }

    func testScheduledLegacyImportAdmissionAndCommitAreExactlyOnce() throws {
        let database = try AppDatabase(DatabaseQueue())
        let run = try makeLegacyRun(database: database, sessionID: "thread-legacy")
        let keyHash = "legacy-alias"

        XCTAssertEqual(
            try database.admitScheduledAssistantImport(
                runID: run.id,
                aliasKeyHash: keyHash,
                isRetry: false
            ),
            .admitted
        )
        XCTAssertTrue(try database.deferScheduledAssistantImport(
            runID: run.id,
            isRetry: false
        ))
        XCTAssertEqual(
            try database.fetchScheduledJobRun(id: run.id)?.assistantTranscriptState,
            .legacyEligible
        )
        XCTAssertEqual(
            try database.admitScheduledAssistantImport(
                runID: run.id,
                aliasKeyHash: keyHash,
                isRetry: false
            ),
            .admitted
        )
        XCTAssertEqual(
            try database.admitScheduledAssistantImport(
                runID: run.id,
                aliasKeyHash: keyHash,
                isRetry: false
            ),
            .notEligible(state: .legacyAttempted)
        )

        let conversation = AssistantConversation(
            id: "legacy-conversation",
            provider: .codex,
            origin: .providerImport,
            workspaceIdentityHash: "workspace",
            contextKind: .library,
            scheduledJobRunId: run.id,
            latestProviderSessionId: "thread-legacy",
            latestSessionTurnOrdinal: 1,
            latestSessionEventOrdinal: 0
        )
        let turn = AssistantTurn(
            id: "legacy-turn",
            conversationId: conversation.id,
            ordinal: 1,
            status: .succeeded,
            finishedAt: Date()
        )
        let entry = AssistantTranscriptEntry(
            id: "legacy-entry",
            turnId: turn.id,
            sequence: 0,
            kind: .assistant,
            body: "Imported answer",
            status: .completed
        )
        XCTAssertEqual(
            try database.completeScheduledAssistantImport(
                runID: run.id,
                conversation: conversation,
                turns: [turn],
                entries: [entry],
                aliasKeyHash: keyHash
            ),
            .imported(conversationId: conversation.id)
        )
        XCTAssertEqual(
            try database.fetchScheduledJobRun(id: run.id)?.assistantTranscriptState,
            .available
        )
        XCTAssertEqual(
            try database.assistantSessionAliasSnapshot(keyHash: keyHash),
            .live(conversationId: conversation.id, ownerRevision: 1)
        )
        XCTAssertEqual(
            try database.fetchAssistantConversationDetail(
                scheduledJobRunID: run.id
            )?.entries.map(\.body),
            ["Imported answer"]
        )
    }

    func testScheduledLegacyRetryRequiresKnownRetryableStatus() throws {
        let database = try AppDatabase(DatabaseQueue())
        let run = try makeLegacyRun(database: database, sessionID: "future-status")
        try database.dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun
                    SET assistantTranscriptState = 'legacyAttempted',
                        assistantTranscriptStatusCode = 'future-status'
                    WHERE id = ?
                    """,
                arguments: [run.id]
            )
        }

        XCTAssertEqual(
            try database.admitScheduledAssistantImport(
                runID: run.id,
                aliasKeyHash: "future-status-alias",
                isRetry: true
            ),
            .notEligible(state: .legacyAttempted)
        )
        try database.dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun
                    SET assistantTranscriptStatusCode = NULL
                    WHERE id = ?
                    """,
                arguments: [run.id]
            )
        }
        XCTAssertEqual(
            try database.admitScheduledAssistantImport(
                runID: run.id,
                aliasKeyHash: "future-status-alias",
                isRetry: true
            ),
            .notEligible(state: .legacyAttempted)
        )
    }

    func testScheduledLegacyImportResolvesLiveOwnerAndTombstoneWithoutAdmission() throws {
        let database = try AppDatabase(DatabaseQueue())
        let existing = try database.createAssistantConversation(.init(
            id: "existing-conversation",
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        ))
        XCTAssertTrue(try database.recordAssistantSessionBinding(
            keyHash: "live-alias",
            provider: .codex,
            providerSessionID: "live-session",
            conversationID: existing.id,
            turnOrdinal: 1,
            identityEventOrdinal: 0
        ))
        let liveRun = try makeLegacyRun(database: database, sessionID: "live-session")
        XCTAssertEqual(
            try database.admitScheduledAssistantImport(
                runID: liveRun.id,
                aliasKeyHash: "live-alias",
                isRetry: false
            ),
            .existing(conversationId: existing.id)
        )
        XCTAssertEqual(
            try database.fetchScheduledJobRun(id: liveRun.id)?.assistantTranscriptStatusCode,
            .alreadyLocal
        )
        XCTAssertEqual(
            try database.admitScheduledAssistantImport(
                runID: liveRun.id,
                aliasKeyHash: "live-alias",
                isRetry: true
            ),
            .existing(conversationId: existing.id)
        )

        let deleted = try database.createAssistantConversation(.init(
            id: "deleted-conversation",
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        ))
        XCTAssertTrue(try database.recordAssistantSessionBinding(
            keyHash: "deleted-alias",
            provider: .codex,
            providerSessionID: "deleted-session",
            conversationID: deleted.id,
            turnOrdinal: 1,
            identityEventOrdinal: 0
        ))
        try database.deleteAssistantConversation(id: deleted.id)
        let deletedRun = try makeLegacyRun(
            database: database,
            sessionID: "deleted-session"
        )
        XCTAssertEqual(
            try database.admitScheduledAssistantImport(
                runID: deletedRun.id,
                aliasKeyHash: "deleted-alias",
                isRetry: false
            ),
            .deletedLocally
        )
        XCTAssertEqual(
            try database.fetchScheduledJobRun(id: deletedRun.id)?.assistantTranscriptStatusCode,
            .deletedLocal
        )
        XCTAssertEqual(
            try database.admitScheduledAssistantImport(
                runID: deletedRun.id,
                aliasKeyHash: "deleted-alias",
                isRetry: true
            ),
            .deletedLocally
        )
    }

    private func makeLegacyRun(
        database: AppDatabase,
        sessionID: String
    ) throws -> ScheduledJobRun {
        let job = try database.createScheduledJob(
            .init(
                name: "Legacy job \(sessionID)",
                prompt: "Find papers",
                recurrence: .init(weekdayMask: 127, localMinuteOfDay: 480),
                provider: .codex
            ),
            now: date("2026-07-22T07:00:00Z"),
            calendar: utcCalendar()
        )
        let claim = try database.claimManualScheduledJob(id: job.id)
        XCTAssertTrue(try database.finishScheduledJobRun(
            id: claim.run.id,
            status: .succeeded
        ))
        try database.dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE scheduledJobRun
                    SET assistantTranscriptState = 'legacyEligible',
                        assistantTranscriptStatusCode = NULL,
                        providerSessionId = ?
                    WHERE id = ?
                    """,
                arguments: [sessionID, claim.run.id]
            )
        }
        return try XCTUnwrap(database.fetchScheduledJobRun(id: claim.run.id))
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
