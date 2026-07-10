#if canImport(PDFKit)
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienPDFKit

final class PDFImportCoordinatorTests: XCTestCase {
    private var copiedPDFPaths: [String] = []
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for path in copiedPDFPaths {
            try? FileManager.default.removeItem(at: PDFService.pdfURL(for: path))
        }
        copiedPDFPaths.removeAll()

        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testImportPDFPersistsVerifiedReferenceAndAttachesCopiedPDF() async throws {
        let database = try makeDatabase()
        let sourceURL = try makeSourcePDF()
        let resolution = verifiedResolution()

        let outcome = try await PDFImportCoordinator.importPDF(
            from: sourceURL,
            database: database,
            resolver: { _, _ in resolution }
        )

        guard case .imported(let reference) = outcome else {
            return XCTFail("A verified resolution should import a library reference")
        }
        let referenceID = try XCTUnwrap(reference.id)
        let copiedPath = try XCTUnwrap(try database.pdfFilename(for: referenceID))
        copiedPDFPaths.append(copiedPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: PDFService.pdfURL(for: copiedPath).path))
        XCTAssertEqual(try database.referenceCount(), 1)
    }

    func testImportPDFQueuesUnverifiedResolutionWhileRetainingCopiedPDFForIntake() async throws {
        let database = try makeDatabase()
        let sourceURL = try makeSourcePDF()
        let resolution = queuedResolution(for: sourceURL)

        let outcome = try await PDFImportCoordinator.importPDF(
            from: sourceURL,
            database: database,
            resolver: { _, _ in resolution }
        )

        guard case .queued(let intake) = outcome else {
            return XCTFail("An unverified resolution should be queued for review")
        }
        let copiedPath = try XCTUnwrap(intake.pdfPath)
        copiedPDFPaths.append(copiedPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: PDFService.pdfURL(for: copiedPath).path))
        XCTAssertEqual(try database.referenceCount(), 0)
        XCTAssertEqual(try database.fetchPendingMetadataIntakes().map(\.id), [intake.id])
    }

    func testImportPDFRemovesUnattachedCopyWhenReferenceAlreadyHasPDF() async throws {
        let database = try makeDatabase()
        let resolution = verifiedResolution()
        let firstSourceURL = try makeSourcePDF()

        let firstOutcome = try await PDFImportCoordinator.importPDF(
            from: firstSourceURL,
            database: database,
            resolver: { _, _ in resolution }
        )
        guard case .imported(let firstReference) = firstOutcome else {
            return XCTFail("The first verified resolution should import a library reference")
        }
        let firstID = try XCTUnwrap(firstReference.id)
        let attachedPath = try XCTUnwrap(try database.pdfFilename(for: firstID))
        copiedPDFPaths.append(attachedPath)

        let secondSourceURL = try makeSourcePDF()
        let secondOutcome = try await PDFImportCoordinator.importPDF(
            from: secondSourceURL,
            database: database,
            resolver: { _, _ in resolution }
        )
        guard case .imported(let secondReference) = secondOutcome else {
            return XCTFail("A duplicate verified resolution should merge into the existing reference")
        }
        let secondID = try XCTUnwrap(secondReference.id)
        let duplicateCopySuffix = "_\(secondSourceURL.lastPathComponent)"
        let duplicateCopies = try FileManager.default.contentsOfDirectory(
            at: AppDatabase.pdfStorageURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(duplicateCopySuffix) }

        XCTAssertEqual(secondID, firstID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstSourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondSourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: PDFService.pdfURL(for: attachedPath).path))
        XCTAssertTrue(duplicateCopies.isEmpty, "A merged reference must not leave an unattached copied PDF behind")
    }

    func testImportPDFRemovesUnattachedCopyWhenDuplicateHasNonMaterializedCachePlaceholder() async throws {
        let database = try makeDatabase()
        let resolution = verifiedResolution()
        guard case .verified(let envelope) = resolution else {
            return XCTFail("Test setup requires a verified resolution")
        }
        var existingReference = envelope.reference
        try database.saveReference(&existingReference)
        let existingID = try XCTUnwrap(existingReference.id)
        let placeholderFilename = "remote-placeholder.pdf"

        try await database.dbWriter.write { db in
            try db.execute(
                sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(?, ?, 'remote-hash', 2, NULL, ?)
                """,
                arguments: [existingID, placeholderFilename, Date()]
            )
        }

        let sourceURL = try makeSourcePDF()
        let outcome = try await PDFImportCoordinator.importPDF(
            from: sourceURL,
            database: database,
            resolver: { _, _ in resolution }
        )

        guard case .imported(let importedReference) = outcome else {
            return XCTFail("A duplicate verified resolution should merge into the placeholder reference")
        }
        let importedID = try XCTUnwrap(importedReference.id)
        let copiedFileSuffix = "_\(sourceURL.lastPathComponent)"
        let duplicateCopies = try FileManager.default.contentsOfDirectory(
            at: AppDatabase.pdfStorageURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(copiedFileSuffix) }
        let placeholder = try XCTUnwrap(try database.pdfCacheStatus(for: existingID))

        XCTAssertEqual(importedID, existingID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(duplicateCopies.isEmpty, "A sync placeholder must not leave the fresh copied PDF unowned")
        XCTAssertEqual(placeholder.localFilename, placeholderFilename)
        XCTAssertNil(placeholder.materializedAt, "The existing sync placeholder must be preserved")
    }

    func testImportPDFDeletesOnlyCopiedPDFWhenPersistenceFails() async throws {
        let database = try makeDatabase()
        let sourceURL = try makeSourcePDF()
        let copiedFileSuffix = "_\(sourceURL.lastPathComponent)"
        let resolution = verifiedResolution()

        try await database.dbWriter.write { db in
            try db.execute(sql: "DROP TABLE reference")
        }

        do {
            _ = try await PDFImportCoordinator.importPDF(
                from: sourceURL,
                database: database,
                resolver: { _, _ in resolution }
            )
            XCTFail("A persistence failure should be surfaced to the caller")
        } catch {
            // Expected: the intentionally removed reference table makes persistence fail.
        }

        let remainingCopies = try FileManager.default.contentsOfDirectory(
            at: AppDatabase.pdfStorageURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(copiedFileSuffix) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(remainingCopies.isEmpty, "A failed import must remove only its copied library PDF")
    }

    func testPipelineReturnsSeedOnlyForPDFWithoutResolvableMetadata() async {
        let seed = MetadataResolutionSeed(fileName: "unresolved.pdf", workKindHint: .unknown)
        let fallback = Reference(title: "Unresolved PDF")

        let result = await MetadataResolutionPipeline.resolve(seed: seed, fallback: fallback)

        guard case .seedOnly(let intake) = result else {
            return XCTFail("An unresolved PDF should retain its metadata seed")
        }
        XCTAssertEqual(intake.seed, seed)
        XCTAssertEqual(intake.fallbackReference, fallback)
        XCTAssertEqual(intake.message, "No authoritative metadata matched; keeping local attachment and seed only.")
    }

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    private func makeSourcePDF() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RubienPDFImportCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RubienPDFKitTests/Fixtures/PDFs/linear-3pages-text.pdf")
        let sourceURL = directory.appendingPathComponent("coordinator-\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: fixtureURL, to: sourceURL)
        return sourceURL
    }

    private func verifiedResolution() -> MetadataResolutionResult {
        var reference = Reference(
            title: "Verified coordinator import",
            authors: [AuthorName(given: "Ada", family: "Lovelace")],
            year: 1843,
            journal: "Analytical Engine Notes",
            doi: "10.1000/coordinator-import",
            referenceType: .journalArticle,
            metadataSource: .translationServer
        )
        reference.verificationStatus = .verifiedAuto
        reference.acceptedByRuleID = AcceptedRuleID.j1DOIExact.rawValue
        reference.verifiedAt = Date()

        let evidence = EvidenceBundle(
            source: .translationServer,
            recordKey: reference.doi,
            sourceURL: "https://example.com/coordinator-import",
            fetchMode: .identifier,
            fieldEvidence: [
                FieldEvidence(field: "title", value: reference.title, origin: .identifierAPI),
                FieldEvidence(field: "doi", value: reference.doi ?? "", origin: .identifierAPI),
            ],
            verificationHints: VerificationHints(
                hasStructuredTitle: true,
                hasStructuredAuthors: true,
                hasStableRecordKey: true,
                usedIdentifierFetch: true,
                exactIdentifierMatch: true
            )
        )
        return .verified(VerifiedEnvelope(reference: reference, evidence: evidence))
    }

    private func queuedResolution(for sourceURL: URL) -> MetadataResolutionResult {
        let seed = MetadataResolutionSeed(
            fileName: sourceURL.deletingPathExtension().lastPathComponent,
            title: "Needs review",
            workKindHint: .journalArticle
        )
        return .seedOnly(
            IntakeEnvelope(
                seed: seed,
                fallbackReference: Reference(title: "Needs review"),
                message: "No authoritative metadata matched; keeping local attachment and seed only."
            )
        )
    }
}
#endif
