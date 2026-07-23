#if os(macOS)
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

final class AssistantExecutionOwnershipTests: XCTestCase {
    @MainActor
    func testFailedOwnershipAttemptCanRetryAfterOtherProcessReleasesLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let external = try XCTUnwrap(AssistantLibraryExecutionLock.tryAcquire(
            libraryRoot: root,
            ownerDescription: "other-process"
        ))
        let ownership = AssistantExecutionOwnership()
        XCTAssertFalse(ownership.acquireIfNeeded(
            libraryRoot: root,
            ownerDescription: "ownership-test"
        ))

        external.release()
        XCTAssertTrue(ownership.acquireIfNeeded(
            libraryRoot: root,
            ownerDescription: "ownership-test"
        ))
        ownership.release()
    }

    @MainActor
    func testPreparationRecoversOnlyWorkThatPredatesAdmission() throws {
        let database = try AppDatabase(DatabaseQueue())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ownership = AssistantExecutionOwnership()
        let first = try insertStartingTurn(in: database, conversationID: "before-recovery")

        XCTAssertTrue(ownership.prepareIfNeeded(
            database: database,
            libraryRoot: root,
            ownerDescription: "ownership-test",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        XCTAssertEqual(
            try database.fetchAssistantConversationDetail(id: first.conversationID)?
                .turns.first?.status,
            .interrupted
        )

        // A second admission on the same owned root must not rerun launch
        // recovery and classify newly-created work as interrupted.
        let second = try insertStartingTurn(in: database, conversationID: "after-recovery")
        XCTAssertTrue(ownership.prepareIfNeeded(
            database: database,
            libraryRoot: root,
            ownerDescription: "ownership-test"
        ))
        XCTAssertEqual(
            try database.fetchAssistantConversationDetail(id: second.conversationID)?
                .turns.first?.status,
            .starting
        )
        ownership.release()
    }

    @MainActor
    func testMaintenanceBlocksTurnPreparationUntilBackgroundWorkFinishes() throws {
        let database = try AppDatabase(DatabaseQueue())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ownership = AssistantExecutionOwnership()
        XCTAssertTrue(ownership.beginMaintenance(
            database: database,
            libraryRoot: root,
            ownerDescription: "ownership-test"
        ))
        XCTAssertFalse(ownership.prepareIfNeeded(
            database: database,
            libraryRoot: root,
            ownerDescription: "ownership-test"
        ))
        XCTAssertEqual(
            ownership.unavailableReason,
            "Assistant conversation maintenance is in progress."
        )

        ownership.finishMaintenance(libraryRoot: root, prepared: true)
        let turn = try insertStartingTurn(in: database, conversationID: "after-maintenance")
        XCTAssertTrue(ownership.prepareIfNeeded(
            database: database,
            libraryRoot: root,
            ownerDescription: "ownership-test"
        ))
        XCTAssertEqual(
            try database.fetchAssistantConversationDetail(id: turn.conversationID)?
                .turns.first?.status,
            .starting,
            "successful maintenance marks recovery complete instead of reclassifying new work"
        )
        ownership.release()
    }

    @MainActor
    func testMaintenanceRefusesLiveInProcessWorkWithoutRecoveringIt() throws {
        let database = try AppDatabase(DatabaseQueue())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ownership = AssistantExecutionOwnership()
        XCTAssertTrue(ownership.prepareIfNeeded(
            database: database,
            libraryRoot: root,
            ownerDescription: "ownership-test"
        ))
        let turn = try insertStartingTurn(in: database, conversationID: "live-work")
        let token = try XCTUnwrap(ownership.beginAssistantWork(libraryRoot: root))

        XCTAssertFalse(ownership.beginMaintenance(
            database: database,
            libraryRoot: root,
            ownerDescription: "ownership-test"
        ))
        XCTAssertEqual(
            try database.fetchAssistantConversationDetail(id: turn.conversationID)?
                .turns.first?.status,
            .starting,
            "maintenance refusal must not run crash recovery against live work"
        )

        ownership.finishAssistantWork(token)
        XCTAssertTrue(try database.finishAssistantTurn(
            id: turn.turnID,
            status: .interrupted
        ))
        XCTAssertTrue(ownership.beginMaintenance(
            database: database,
            libraryRoot: root,
            ownerDescription: "ownership-test"
        ))
        ownership.finishMaintenance(libraryRoot: root, prepared: true)
        ownership.release()
    }

    private func insertStartingTurn(
        in database: AppDatabase,
        conversationID: String
    ) throws -> (conversationID: String, turnID: String) {
        let turnID = "\(conversationID)-turn"
        let conversation = AssistantConversation(
            id: conversationID,
            provider: .codex,
            workspaceIdentityHash: "workspace",
            contextKind: .library
        )
        let turn = AssistantTurn(
            id: turnID,
            conversationId: conversationID,
            ordinal: 0,
            status: .starting
        )
        let user = AssistantTranscriptEntry(
            id: "\(conversationID)-user",
            turnId: turnID,
            sequence: 0,
            kind: .user,
            body: "Prompt"
        )
        _ = try database.beginInteractiveAssistantTurn(
            conversation: conversation,
            turn: turn,
            userEntry: user,
            allowConversationCreation: true
        )
        return (conversationID, turnID)
    }
}
#endif
