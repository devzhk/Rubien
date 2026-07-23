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

    func testDeleteJobConfirmationDisclosesTranscriptCascadeAndSurvivors() {
        let message = ScheduledJobFormatting.deleteJobConfirmation(jobName: "Morning papers")

        XCTAssertTrue(message.contains("Morning papers"))
        XCTAssertTrue(message.contains("run transcripts and attachments"))
        XCTAssertTrue(message.contains("Continuation chats"))
        XCTAssertTrue(message.contains("provider History"))
    }

    func testDeleteRunConfirmationDisclosesLocalDeletionAndProviderSurvivor() {
        let message = ScheduledJobFormatting.deleteRunConfirmation(
            jobName: "Morning papers",
            runDetail: "Finished today"
        )

        XCTAssertTrue(message.contains("Morning papers"))
        XCTAssertTrue(message.contains("Finished today"))
        XCTAssertTrue(message.contains("locally saved transcript and attachments"))
        XCTAssertTrue(message.contains("provider conversation"))
        XCTAssertTrue(message.contains("not deleted"))
    }

    func testTranscriptOpenRoutingKeepsNonLegacyStatesLocal() {
        for state in [
            AssistantTranscriptState.none,
            .capturing,
            .available,
            .deleted,
            .unknown("future-state"),
        ] {
            var (_, run) = fixture()
            run.assistantTranscriptState = state
            run.providerSessionId = "provider-session-that-must-not-be-read"
            XCTAssertEqual(
                ScheduledJobFormatting.transcriptOpenAction(for: run),
                .presentLocal,
                "state \(state.rawValue) must never trigger an implicit provider read"
            )
        }
    }

    func testTranscriptOpenRoutingImportsOnlyExplicitLegacyStates() {
        var (_, eligible) = fixture()
        eligible.assistantTranscriptState = .legacyEligible
        XCTAssertEqual(
            ScheduledJobFormatting.transcriptOpenAction(for: eligible),
            .importLegacy(isRetry: false)
        )

        var attempted = eligible
        attempted.assistantTranscriptState = .legacyAttempted
        attempted.assistantTranscriptStatusCode = .deletedLocal
        XCTAssertEqual(
            ScheduledJobFormatting.transcriptOpenAction(for: attempted),
            .importLegacy(isRetry: true)
        )

        attempted.assistantTranscriptStatusCode = .notFound
        XCTAssertEqual(
            ScheduledJobFormatting.transcriptOpenAction(for: attempted),
            .presentLocal
        )
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
