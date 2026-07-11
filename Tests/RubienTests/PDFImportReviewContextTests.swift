#if os(macOS) && canImport(PDFKit)
import XCTest
import GRDB
@testable import RubienCore
import RubienPDFKit
@testable import Rubien

@MainActor
final class PDFImportReviewContextTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    func testVerifiedPreparationIsReadyWithoutPersistingUntilCommit() async throws {
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))
        let source = try makeRemoteSource(named: "ready.pdf")
        let prepared = PreparedPDFImport(
            sourceURL: source.fileURL,
            resolution: verifiedResolution(title: "Ready PDF")
        )
        let context = PDFImportReviewContext(
            database: database,
            entries: [(prepared: prepared, source: source)]
        )

        XCTAssertEqual(context.items.map(\.readiness), [.ready])
        XCTAssertEqual(try database.referenceCount(), 0)

        let report = await context.commit(selectedIDs: [context.items[0].id])

        XCTAssertEqual(report.succeededIDs, [context.items[0].id])
        XCTAssertEqual(try database.referenceCount(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.temporaryDirectoryURL!.path))
    }

    func testDiscardCleansUnselectedTemporarySourceWithoutPersisting() throws {
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))
        let source = try makeRemoteSource(named: "unselected.pdf")
        let prepared = PreparedPDFImport(
            sourceURL: source.fileURL,
            resolution: verifiedResolution(title: "Unselected PDF")
        )
        let context = PDFImportReviewContext(
            database: database,
            entries: [(prepared: prepared, source: source)]
        )

        context.discard(remainingIDs: [context.items[0].id])

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.temporaryDirectoryURL!.path))
        XCTAssertEqual(try database.referenceCount(), 0)
    }

    func testCommitCleansSelectedSourceAndRetainsUnselectedSourceUntilDiscard() async throws {
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))
        let first = try makeRemoteSource(named: "first.pdf")
        let second = try makeRemoteSource(named: "second.pdf")
        let context = PDFImportReviewContext(
            database: database,
            entries: [
                (
                    prepared: PreparedPDFImport(
                        sourceURL: first.fileURL,
                        resolution: verifiedResolution(title: "First PDF")
                    ),
                    source: first
                ),
                (
                    prepared: PreparedPDFImport(
                        sourceURL: second.fileURL,
                        resolution: verifiedResolution(title: "Second PDF")
                    ),
                    source: second
                ),
            ]
        )

        let firstID = context.items[0].id
        let secondID = context.items[1].id
        _ = await context.commit(selectedIDs: [firstID])

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.temporaryDirectoryURL!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.temporaryDirectoryURL!.path))
        XCTAssertEqual(try database.referenceCount(), 1)

        context.discard(remainingIDs: [secondID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.temporaryDirectoryURL!.path))
    }

    func testCandidateChoiceStagesReadyReferenceWithoutPersistence() async throws {
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))
        let source = try makeRemoteSource(named: "candidate.pdf")
        let candidate = MetadataCandidate(
            source: .translationServer,
            title: "Chosen PDF",
            authors: [AuthorName(given: "Ada", family: "Lovelace")],
            year: 1843,
            detailURL: "https://example.com/chosen",
            score: 0.9,
            workKind: .journalArticle
        )
        let resolution = MetadataResolutionResult.candidate(
            CandidateEnvelope(
                seed: MetadataResolutionSeed(fileName: "candidate.pdf", title: "Candidate"),
                fallbackReference: Reference(title: "Candidate"),
                candidates: [candidate],
                message: "Choose a match"
            )
        )
        let context = PDFImportReviewContext(
            database: database,
            entries: [(
                prepared: PreparedPDFImport(sourceURL: source.fileURL, resolution: resolution),
                source: source
            )]
        )

        XCTAssertEqual(context.items[0].readiness, .needsCandidate)
        let updated = await context.resolveCandidate(itemID: context.items[0].id, candidate: candidate)

        XCTAssertEqual(updated.readiness, .ready)
        XCTAssertEqual(updated.reference?.title, "Chosen PDF")
        XCTAssertEqual(try database.referenceCount(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.temporaryDirectoryURL!.path))
    }

    func testUseProposedMetadataStagesManualVerificationWithoutPersistence() throws {
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))
        let source = try makeRemoteSource(named: "proposal.pdf")
        let resolution = MetadataResolutionResult.seedOnly(
            IntakeEnvelope(
                seed: MetadataResolutionSeed(fileName: "proposal.pdf", title: "Proposed PDF"),
                fallbackReference: Reference(title: "Proposed PDF"),
                message: "No authoritative match"
            )
        )
        let context = PDFImportReviewContext(
            database: database,
            entries: [(
                prepared: PreparedPDFImport(sourceURL: source.fileURL, resolution: resolution),
                source: source
            )]
        )

        XCTAssertEqual(context.items[0].readiness, .needsProposal)
        let updated = context.useProposedMetadata(itemID: context.items[0].id)

        XCTAssertEqual(updated.readiness, .ready)
        XCTAssertEqual(updated.reference?.verificationStatus, .verifiedManual)
        XCTAssertEqual(try database.referenceCount(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.temporaryDirectoryURL!.path))
    }

    func testCompositeRoutesSelectionsAndRetainsFailedSibling() async {
        let first = RecordingReviewContext(title: "Markdown")
        let second = RecordingReviewContext(title: "PDF")
        let failed = ImportReviewItem(
            id: UUID(),
            title: "Unreadable markdown",
            subtitle: nil,
            message: "Could not read file",
            reference: nil,
            candidates: [],
            readiness: .failed,
            commitError: nil,
            isWorking: false
        )
        let composite = CompositeImportReviewContext(
            children: [first, second],
            additionalItems: [failed]
        )

        let report = await composite.commit(selectedIDs: [second.items[0].id])

        XCTAssertTrue(first.commitCalls.isEmpty)
        XCTAssertEqual(second.commitCalls, [[second.items[0].id]])
        XCTAssertEqual(report.succeededIDs, [second.items[0].id])
        XCTAssertTrue(composite.items.contains(where: { $0.id == failed.id }))
    }

    private func makeRemoteSource(named filename: String) throws -> MaterializedImportSource {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFImportReviewContextTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupURLs.append(directory)

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RubienPDFKitTests/Fixtures/PDFs/linear-3pages-text.pdf")
        let fileURL = directory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: fixtureURL, to: fileURL)
        return MaterializedImportSource(
            input: "https://example.com/\(filename)",
            fileURL: fileURL,
            kind: .pdf,
            temporaryDirectoryURL: directory
        )
    }

    private func verifiedResolution(title: String) -> MetadataResolutionResult {
        var reference = Reference(title: title, referenceType: .journalArticle)
        reference.verificationStatus = .verifiedAuto
        reference.acceptedByRuleID = AcceptedRuleID.j1DOIExact.rawValue
        reference.verifiedAt = Date()
        let evidence = EvidenceBundle(
            source: .translationServer,
            recordKey: title,
            fetchMode: .identifier,
            verificationHints: VerificationHints(
                hasStructuredTitle: true,
                hasStableRecordKey: true,
                usedIdentifierFetch: true,
                exactIdentifierMatch: true
            )
        )
        return .verified(VerifiedEnvelope(reference: reference, evidence: evidence))
    }
}

@MainActor
private final class RecordingReviewContext: ImportReviewContext {
    let items: [ImportReviewItem]
    private(set) var commitCalls: [Set<UUID>] = []

    init(title: String) {
        items = [ImportReviewItem(
            id: UUID(),
            title: title,
            subtitle: nil,
            message: nil,
            reference: Reference(title: title),
            candidates: [],
            readiness: .ready,
            commitError: nil,
            isWorking: false
        )]
    }

    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport {
        commitCalls.append(selectedIDs)
        return ImportReviewCommitReport(succeededIDs: selectedIDs, failures: [:])
    }

    func discard(remainingIDs: Set<UUID>) {}
}
#endif
