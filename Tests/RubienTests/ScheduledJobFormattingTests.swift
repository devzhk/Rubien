#if os(macOS)
import XCTest
@testable import Rubien
@testable import RubienCore

final class ScheduledJobFormattingTests: XCTestCase {
    func testRunSearchMatchesMultipleTermsAcrossJobAndRunMetadata() {
        let (job, run) = fixture()

        XCTAssertTrue(ScheduledJobFormatting.runMatchesSearch(
            run,
            job: job,
            query: "resume codex permission"
        ))
        XCTAssertTrue(ScheduledJobFormatting.runMatchesSearch(
            run,
            job: job,
            query: "citation gpt-5.6"
        ))
    }

    func testRunSearchIsDiacriticInsensitiveAndRejectsMissingTerms() {
        let (job, run) = fixture()

        XCTAssertTrue(ScheduledJobFormatting.runMatchesSearch(
            run,
            job: job,
            query: "resume"
        ))
        XCTAssertFalse(ScheduledJobFormatting.runMatchesSearch(
            run,
            job: job,
            query: "resume claude"
        ))
    }

    func testBlankRunSearchShowsEveryRun() {
        let (job, run) = fixture()

        XCTAssertTrue(ScheduledJobFormatting.runMatchesSearch(
            run,
            job: job,
            query: "  \n "
        ))
    }

    private func fixture() -> (ScheduledJob, ScheduledJobRun) {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let job = ScheduledJob(
            id: "job-1",
            definition: ScheduledJobDefinition(
                name: "Résumé monitor",
                prompt: "Check citation updates",
                recurrence: ScheduledRecurrence(weekdayMask: 127, localMinuteOfDay: 480),
                provider: .codex,
                model: "gpt-5.6"
            ),
            nextRunAt: nil,
            createdAt: date,
            dateModified: date
        )
        let run = ScheduledJobRun(
            id: "run-1",
            jobId: job.id,
            trigger: .manual,
            occurrenceKey: "manual:run-1",
            scheduledFor: date,
            startedAt: date,
            finishedAt: date,
            status: .failed,
            provider: .codex,
            providerSessionId: "session-1",
            failureKind: .permissionDenied,
            isUnread: true
        )
        return (job, run)
    }
}
#endif
