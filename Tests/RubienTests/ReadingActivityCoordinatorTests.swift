#if os(macOS)
import AppKit
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

final class ReadingActivityCoordinatorTests: XCTestCase {
    private func databaseAndReference() throws -> (AppDatabase, Int64) {
        let database = try AppDatabase(DatabaseQueue())
        var reference = Reference(title: "Activity timer test")
        try database.saveReference(&reference)
        return (database, try XCTUnwrap(reference.id))
    }

    func testInAppClearRestartsEligibleReaderAtTheResetBoundary() async throws {
        let (database, referenceId) = try databaseAndReference()
        let coordinator = ReadingActivityCoordinator()
        let tick = ContinuousClock().now
        let wallDate = Date(timeIntervalSince1970: 1_768_435_200)

        await coordinator.setActiveReader(
            referenceId: referenceId,
            database: database,
            wallDate: wallDate,
            sequence: 1,
            monotonicTick: tick
        )
        await coordinator.setActiveReader(
            referenceId: referenceId,
            database: database,
            wallDate: wallDate.addingTimeInterval(30),
            sequence: 2,
            monotonicTick: tick.advanced(by: .seconds(30))
        )

        try await coordinator.clearReadingActivity(
            in: database,
            restartReferenceId: referenceId,
            restartDatabase: database,
            wallDate: wallDate.addingTimeInterval(30),
            sequence: 3,
            monotonicTick: tick.advanced(by: .seconds(30))
        )
        await coordinator.setActiveReader(
            referenceId: referenceId,
            database: database,
            wallDate: wallDate.addingTimeInterval(90),
            sequence: 4,
            monotonicTick: tick.advanced(by: .seconds(90))
        )

        let context = try database.activityCaptureContext(for: .reading)
        let row = try database.readingActivityComponent(
            installationId: RubienPreferences.activityInstallationId,
            referenceId: referenceId,
            localDay: LocalDay(date: wallDate, calendar: AppDatabase.activityCalendar()),
            context: context
        )
        XCTAssertEqual(row?.activeSeconds, 60)
    }

    func testExternalClearDiscardsOldEpochAndRestartsPromptly() async throws {
        let (database, referenceId) = try databaseAndReference()
        let coordinator = ReadingActivityCoordinator()
        let tick = ContinuousClock().now
        let wallDate = Date(timeIntervalSince1970: 1_768_435_200)

        await coordinator.setActiveReader(
            referenceId: referenceId,
            database: database,
            wallDate: wallDate,
            sequence: 1,
            monotonicTick: tick
        )
        await coordinator.setActiveReader(
            referenceId: referenceId,
            database: database,
            wallDate: wallDate.addingTimeInterval(30),
            sequence: 2,
            monotonicTick: tick.advanced(by: .seconds(30))
        )

        try database.clearActivity(kind: .reading, now: wallDate.addingTimeInterval(30))
        await coordinator.setActiveReader(
            referenceId: referenceId,
            database: database,
            wallDate: wallDate.addingTimeInterval(30),
            sequence: 3,
            monotonicTick: tick.advanced(by: .seconds(30))
        )
        await coordinator.setActiveReader(
            referenceId: referenceId,
            database: database,
            wallDate: wallDate.addingTimeInterval(90),
            sequence: 4,
            monotonicTick: tick.advanced(by: .seconds(90))
        )

        let context = try database.activityCaptureContext(for: .reading)
        let row = try database.readingActivityComponent(
            installationId: RubienPreferences.activityInstallationId,
            referenceId: referenceId,
            localDay: LocalDay(date: wallDate, calendar: AppDatabase.activityCalendar()),
            context: context
        )
        XCTAssertEqual(row?.activeSeconds, 60)
    }

    func testSameIntentRebaseCarriesUnflushedPostClearDelta() async throws {
        let (database, referenceId) = try databaseAndReference()
        try database.clearActivity(kind: .reading)
        let originalContext = try database.activityCaptureContext(for: .reading)
        let intentId = try XCTUnwrap(originalContext.pendingClearIntentId)
        let coordinator = ReadingActivityCoordinator()
        let tick = ContinuousClock().now
        let wallDate = Date(timeIntervalSince1970: 1_768_435_200)

        await coordinator.setActiveReader(
            referenceId: referenceId,
            database: database,
            wallDate: wallDate,
            sequence: 1,
            monotonicTick: tick
        )
        await coordinator.setActiveReader(
            referenceId: referenceId,
            database: database,
            wallDate: wallDate.addingTimeInterval(30),
            sequence: 2,
            monotonicTick: tick.advanced(by: .seconds(30))
        )

        let rebasedGeneration = "rebased-generation"
        let rebasedRevision = originalContext.revision + 1
        try await database.dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE activityEpoch
                    SET revision = ?, generation = ?, dateModified = ?
                    WHERE kind = 'reading'
                    """,
                arguments: [rebasedRevision, rebasedGeneration, wallDate]
            )
            try db.execute(
                sql: """
                    UPDATE activityPendingClear
                    SET revision = ?, generation = ?, dateModified = ?
                    WHERE kind = 'reading' AND intentId = ?
                    """,
                arguments: [rebasedRevision, rebasedGeneration, wallDate, intentId]
            )
        }

        await coordinator.setActiveReader(
            referenceId: referenceId,
            database: database,
            wallDate: wallDate.addingTimeInterval(31),
            sequence: 3,
            monotonicTick: tick.advanced(by: .seconds(31))
        )

        let rebasedContext = try database.activityCaptureContext(for: .reading)
        XCTAssertEqual(rebasedContext.generation, rebasedGeneration)
        let row = try database.readingActivityComponent(
            installationId: RubienPreferences.activityInstallationId,
            referenceId: referenceId,
            localDay: LocalDay(date: wallDate, calendar: AppDatabase.activityCalendar()),
            context: rebasedContext
        )
        XCTAssertEqual(row?.activeSeconds, 31)
    }

    @MainActor
    func testPollingTimerLivesOnlyWhileAReaderIsRegistered() throws {
        let (database, referenceId) = try databaseAndReference()
        let monitor = ReadingActivityWindowMonitor.shared
        let window = NSWindow()
        monitor.register(window: window, referenceId: referenceId, database: database)
        XCTAssertTrue(monitor.isPollingForActivity)

        monitor.unregister(window: window)
        XCTAssertFalse(monitor.isPollingForActivity)
    }
}
#endif
