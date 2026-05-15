import XCTest
import GRDB
@testable import RubienCore

final class AppDatabaseTests: XCTestCase {

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    private func makeEvidence(
        source: MetadataSource = .translationServer,
        recordKey: String? = "record-1",
        sourceURL: String? = "https://example.com/reference",
        fetchMode: FetchMode = .identifier
    ) -> EvidenceBundle {
        EvidenceBundle(
            source: source,
            recordKey: recordKey,
            sourceURL: sourceURL,
            fetchMode: fetchMode,
            fieldEvidence: [
                FieldEvidence(field: "title", value: "Evidence Title", origin: .identifierAPI),
                FieldEvidence(field: "year", value: "2024", origin: .identifierAPI)
            ],
            verificationHints: VerificationHints(
                hasStructuredTitle: true,
                hasStableRecordKey: recordKey != nil,
                usedIdentifierFetch: fetchMode == .identifier,
                exactIdentifierMatch: fetchMode == .identifier
            )
        )
    }

    // MARK: - Reference CRUD

    func testSaveAndFetchReference() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "DB Test Reference")
        ref.year = 2023
        ref.journal = "Test Journal"

        try db.saveReference(&ref)
        XCTAssertNotNil(ref.id, "After save, reference should have an ID")

        let fetched = try db.fetchReferences(ids: [ref.id!])
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].title, "DB Test Reference")
        XCTAssertEqual(fetched[0].year, 2023)
    }

    func testUpdateReference() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "Original Title")
        try db.saveReference(&ref)
        let id = ref.id!

        ref.title = "Updated Title"
        ref.year = 2024
        try db.saveReference(&ref)

        let fetched = try db.fetchReferences(ids: [id])
        XCTAssertEqual(fetched[0].title, "Updated Title")
        XCTAssertEqual(fetched[0].year, 2024)
    }

    func testDeleteReference() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "To Delete")
        try db.saveReference(&ref)
        let id = ref.id!

        try db.deleteReferences(ids: [id])
        let fetched = try db.fetchReferences(ids: [id])
        XCTAssertTrue(fetched.isEmpty, "Deleted reference should not be fetchable")
    }

    func testDeleteMultipleReferences() throws {
        let db = try makeDatabase()
        var ref1 = Reference(title: "Delete Multi 1")
        var ref2 = Reference(title: "Delete Multi 2")
        try db.saveReference(&ref1)
        try db.saveReference(&ref2)

        try db.deleteReferences(ids: [ref1.id!, ref2.id!])
        let fetched = try db.fetchReferences(ids: [ref1.id!, ref2.id!])
        XCTAssertTrue(fetched.isEmpty)
    }

    func testDeleteReferencesReturningPDFPathsDeletesDatabaseRowsAtomically() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "Delete With PDF")
        try db.saveReference(&ref)
        let id = try XCTUnwrap(ref.id)
        // Post-B8: PDF presence lives in pdfCache, not on Reference.
        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(?, 'PDFs/example.pdf', 'h', 1, ?, ?)
            """, arguments: [id, Date(), Date()])
        }

        let pdfPaths = try db.deleteReferencesReturningPDFPaths(ids: [id])

        XCTAssertEqual(pdfPaths, ["PDFs/example.pdf"])
        XCTAssertTrue(try db.fetchReferences(ids: [id]).isEmpty)
    }

    func testSaveReferenceWithPDFPathIsTreatedAsManualDirectSave() throws {
        // The original test asserted that setting `Reference.pdfPath` flipped
        // the row to `verifiedManual` via `normalizeForDirectLibrarySave`.
        // Post-B8 the pdfPath property is gone, but the same direct-save path
        // still flips to `verifiedManual` for any reference inserted without
        // `metadataSource` set — the trigger is the lifecycle, not the PDF.
        let db = try makeDatabase()
        var ref = Reference(title: "Manual Entry")

        try db.saveReference(&ref)

        let id = try XCTUnwrap(ref.id)
        let stored = try XCTUnwrap(try db.fetchReferences(ids: [id]).first)
        XCTAssertEqual(stored.verificationStatus, .verifiedManual)
        XCTAssertEqual(stored.reviewedBy, "direct-save")
    }

    func testSaveReferenceMergesDuplicateDOIAndKeepsBestMetadata() throws {
        let db = try makeDatabase()

        var original = Reference(title: "Original Title")
        original.doi = "10.1000/example"
        original.notes = "short"
        try db.saveReference(&original)

        var duplicate = Reference(title: "Better Title")
        duplicate.doi = "10.1000/example"
        duplicate.abstract = "A much longer abstract than before"
        try db.saveReference(&duplicate)

        let all = try db.fetchAllReferences()
        XCTAssertEqual(all.count, 1)
        let merged = try XCTUnwrap(all.first)
        XCTAssertEqual(merged.title, "Better Title")
        XCTAssertEqual(merged.abstract, "A much longer abstract than before")
        XCTAssertEqual(duplicate.id, merged.id)
    }

    func testSaveReferenceAllowsUpdatingExistingLegacyEntry() throws {
        let db = try makeDatabase()

        var ref = Reference(title: "Legacy Entry")
        try db.saveReference(&ref)
        ref.verificationStatus = .legacy
        try db.saveReference(&ref)

        ref.title = "Updated Legacy Entry"
        ref.notes = "Edited after migration"
        try db.saveReference(&ref)

        let stored = try XCTUnwrap(try db.fetchReferences(ids: [try XCTUnwrap(ref.id)]).first)
        XCTAssertEqual(stored.title, "Updated Legacy Entry")
        XCTAssertEqual(stored.notes, "Edited after migration")
        XCTAssertEqual(stored.verificationStatus, .legacy)
    }

    func testBatchImportDeduplicatesByPMID() throws {
        let db = try makeDatabase()
        let refs = [
            Reference(title: "First Import", pmid: "123456"),
            Reference(title: "Second Import", abstract: "Merged abstract", pmid: "123456")
        ]

        let count = try db.batchImportReferences(refs)
        let all = try db.fetchAllReferences()

        XCTAssertEqual(count, 2)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].pmid, "123456")
        XCTAssertEqual(all[0].abstract, "Merged abstract")
    }

    func testPersistCandidateResolutionCreatesPendingIntake() throws {
        let db = try makeDatabase()
        let evidence = makeEvidence(source: .translationServer, recordKey: "CJFD-2024-001", sourceURL: "https://kns.cnki.net/detail")
        let candidate = MetadataCandidate(
            source: .translationServer,
            title: "候选论文",
            authors: [AuthorName(given: "小明", family: "张")],
            journal: "测试期刊",
            year: 2024,
            detailURL: "https://kns.cnki.net/detail",
            score: 0.91
        )

        let result = try db.persistMetadataResolution(
            .candidate(
                CandidateEnvelope(
                    seed: MetadataResolutionSeed(fileName: "candidate.pdf", title: "候选论文", workKindHint: .journalArticle),
                    fallbackReference: Reference(title: "候选论文"),
                    currentReference: Reference(title: "候选论文"),
                    candidates: [candidate],
                    message: "需要人工确认。",
                    evidence: evidence
                )
            ),
            options: MetadataPersistenceOptions(sourceKind: .manualEntry, originalInput: "候选论文")
        )

        guard case .intake(let intake) = result else {
            return XCTFail("candidate 结果应当持久化为 MetadataIntake")
        }
        XCTAssertEqual(intake.verificationStatus, .candidate)
        XCTAssertEqual(intake.decodedCandidates.count, 1)
        XCTAssertEqual(try db.fetchPendingMetadataIntakes().count, 1)
    }

    func testPersistVerifiedResolutionWritesReference() throws {
        let db = try makeDatabase()
        let evidence = makeEvidence(recordKey: "doi:10.1000/example", sourceURL: "https://doi.org/10.1000/example")
        var verified = Reference(
            title: "Verified Entry",
            authors: [AuthorName(given: "Ada", family: "Lovelace")],
            year: 2024,
            doi: "10.1000/example"
        )
        verified.verificationStatus = .verifiedAuto
        verified.acceptedByRuleID = AcceptedRuleID.j1DOIExact.rawValue
        verified.recordKey = evidence.recordKey
        verified.verificationSourceURL = evidence.sourceURL
        verified.evidenceBundleHash = evidence.bundleHash
        verified.verifiedAt = Date()
        verified.metadataSource = evidence.source

        let result = try db.persistMetadataResolution(
            .verified(VerifiedEnvelope(reference: verified, evidence: evidence)),
            options: MetadataPersistenceOptions(sourceKind: .manualEntry, originalInput: "10.1000/example")
        )

        guard case .verified(let stored) = result else {
            return XCTFail("verified 结果应当直接写入资料库")
        }
        XCTAssertNotNil(stored.id)
        XCTAssertEqual(stored.verificationStatus, .verifiedAuto)
        XCTAssertEqual(try db.referenceCount(), 1)
        XCTAssertTrue(try db.fetchPendingMetadataIntakes().isEmpty)
    }

    func testPersistVerifiedResolutionUpdatesLinkedReferenceInsteadOfCreatingDuplicate() throws {
        let db = try makeDatabase()

        var original = Reference(title: "原始条目")
        original.notes = "旧备注"
        try db.saveReference(&original)

        let evidence = makeEvidence(
            source: .translationServer,
            recordKey: "CJFD-2024-009",
            sourceURL: "https://kns.cnki.net/detail/example",
            fetchMode: .detail
        )
        var verified = Reference(
            title: "刷新后的权威条目",
            authors: [AuthorName(given: "明", family: "李")],
            year: 2024,
            journal: "知网测试期刊"
        )
        verified.verificationStatus = .verifiedManual
        verified.metadataSource = .translationServer
        verified.recordKey = evidence.recordKey
        verified.verificationSourceURL = evidence.sourceURL
        verified.evidenceBundleHash = evidence.bundleHash
        verified.reviewedBy = "candidate-selection"
        verified.verifiedAt = Date()

        let result = try db.persistMetadataResolution(
            .verified(VerifiedEnvelope(reference: verified, evidence: evidence)),
            options: MetadataPersistenceOptions(
                sourceKind: .refresh,
                originalInput: "原始条目",
                linkedReferenceId: original.id
            )
        )

        guard case .verified(let stored) = result else {
            return XCTFail("verified 结果应当直接写入原始关联条目")
        }

        XCTAssertEqual(stored.id, original.id)
        XCTAssertEqual(try db.referenceCount(), 1)

        let refreshed = try XCTUnwrap(try db.fetchReferences(ids: [try XCTUnwrap(original.id)]).first)
        XCTAssertEqual(refreshed.id, original.id)
        XCTAssertEqual(refreshed.title, "刷新后的权威条目")
        XCTAssertEqual(refreshed.journal, "知网测试期刊")
        XCTAssertEqual(refreshed.verificationStatus, .verifiedManual)
        XCTAssertEqual(refreshed.metadataSource, .translationServer)
        XCTAssertEqual(refreshed.recordKey, "CJFD-2024-009")
    }

    func testConfirmMetadataIntakePromotesToVerifiedManualReference() throws {
        let db = try makeDatabase()
        let evidence = makeEvidence(source: .translationServer, recordKey: "CJFD-2024-002", sourceURL: "https://kns.cnki.net/detail")
        let unresolved = Reference(
            title: "待人工确认的条目",
            authors: [AuthorName(given: "华", family: "李")],
            year: 2024,
            journal: "工业验证期刊"
        )

        let persisted = try db.persistMetadataResolution(
            .rejected(
                RejectedEnvelope(
                    seed: MetadataResolutionSeed(fileName: "queued.pdf", title: unresolved.title, firstAuthor: "李华", year: 2024, journal: unresolved.journal, workKindHint: .journalArticle),
                    fallbackReference: unresolved,
                    currentReference: unresolved,
                    reason: .verifierRuleNotSatisfied,
                    message: "需要人工确认。",
                    evidence: evidence
                )
            ),
            options: MetadataPersistenceOptions(sourceKind: .importedPDF, originalInput: "queued.pdf", preferredPDFPath: "PDFs/queued.pdf")
        )

        guard case .intake(let intake) = persisted else {
            return XCTFail("rejected 结果应当进入待验证队列")
        }

        let confirmed = try db.confirmMetadataIntake(intake, reviewedBy: "unit-test")
        XCTAssertEqual(confirmed.verificationStatus, .verifiedManual)
        XCTAssertEqual(confirmed.reviewedBy, "unit-test")
        // Post-B8: confirm promotes the intake's pdfPath into a pdfCache row
        // tied to the new Reference id.
        let confirmedId = try XCTUnwrap(confirmed.id)
        XCTAssertEqual(try db.pdfFilename(for: confirmedId), "PDFs/queued.pdf")
        XCTAssertEqual(try db.referenceCount(), 1)
        XCTAssertTrue(try db.fetchPendingMetadataIntakes().isEmpty)
    }

    func testConfirmMetadataIntakeUpdatesLinkedReferenceWhenSnapshotHasNoID() throws {
        let db = try makeDatabase()

        var original = Reference(title: "待刷新原条目")
        try db.saveReference(&original)

        let snapshot = Reference(
            title: "人工确认后的条目",
            authors: [AuthorName(given: "华", family: "张")],
            year: 2025,
            journal: "人工确认期刊"
        )
        var intake = MetadataIntake(
            sourceKind: .refresh,
            verificationStatus: .rejectedAmbiguous,
            title: "人工确认后的条目",
            currentReferenceJSON: MetadataVerificationCodec.encodeToJSONString(snapshot),
            linkedReferenceId: original.id
        )
        try db.saveMetadataIntake(&intake)

        let confirmed = try db.confirmMetadataIntake(intake, reviewedBy: "unit-test")

        XCTAssertEqual(confirmed.id, original.id)
        XCTAssertEqual(confirmed.verificationStatus, .verifiedManual)
        XCTAssertEqual(confirmed.reviewedBy, "unit-test")
        XCTAssertEqual(try db.referenceCount(), 1)

        let refreshed = try XCTUnwrap(try db.fetchReferences(ids: [try XCTUnwrap(original.id)]).first)
        XCTAssertEqual(refreshed.title, "人工确认后的条目")
        XCTAssertEqual(refreshed.journal, "人工确认期刊")
        XCTAssertEqual(refreshed.verificationStatus, .verifiedManual)
    }

    // MARK: - Fetch All

    func testFetchAllReferences() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "FetchAll Test")
        try db.saveReference(&ref)

        let all = try db.fetchAllReferences()
        XCTAssertTrue(all.count >= 1, "Should have at least one reference")
    }

    func testFetchAllReferencesWithLimit() throws {
        let db = try makeDatabase()
        for i in 0..<5 {
            var ref = Reference(title: "Limit Test \(i)")
            try db.saveReference(&ref)
        }

        let limited = try db.fetchAllReferences(limit: 3)
        XCTAssertEqual(limited.count, 3)
    }

    // MARK: - Search

    func testSearchReferences() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "Quantum Computing Advances")
        try db.saveReference(&ref)

        let results = try db.searchReferences(query: "Quantum")
        XCTAssertTrue(results.count >= 1,
                      "Search should find the reference with 'Quantum' in title")
    }

    func testSearchReferencesNoResults() throws {
        let db = try makeDatabase()
        let results = try db.searchReferences(query: "zzzNonExistentTermXYZ")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Tag CRUD

    func testSaveAndFetchTag() throws {
        let db = try makeDatabase()
        var tag = Tag(name: "Test Tag", color: "#FF0000")
        try db.saveTag(&tag)
        XCTAssertNotNil(tag.id)

        let all = try db.fetchAllTags()
        XCTAssertTrue(all.contains(where: { $0.id == tag.id }))
    }

    func testDeleteTag() throws {
        let db = try makeDatabase()
        var tag = Tag(name: "To Delete")
        try db.saveTag(&tag)
        let id = tag.id!

        try db.deleteTag(id: id)
        let all = try db.fetchAllTags()
        XCTAssertFalse(all.contains(where: { $0.id == id }))
    }

    // MARK: - Tag Assignment

    func testSetTagsForReference() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "Tag Assignment Test")
        try db.saveReference(&ref)
        var tag1 = Tag(name: "Tag A")
        var tag2 = Tag(name: "Tag B")
        try db.saveTag(&tag1)
        try db.saveTag(&tag2)

        try db.setTags(forReference: ref.id!, tagIds: [tag1.id!, tag2.id!])
        let tags = try db.fetchTags(forReference: ref.id!)
        XCTAssertEqual(tags.count, 2)
    }

    func testFetchReferencesByTag() throws {
        let db = try makeDatabase()
        var tag = Tag(name: "Filter Tag")
        try db.saveTag(&tag)
        var ref = Reference(title: "Tagged Reference")
        try db.saveReference(&ref)
        try db.setTags(forReference: ref.id!, tagIds: [tag.id!])

        let results = try db.fetchReferences(tagId: tag.id!)
        XCTAssertTrue(results.contains(where: { $0.id == ref.id }))
    }

    // MARK: - Batch Import

    func testBatchImportReferences() throws {
        let db = try makeDatabase()
        let refs = [
            Reference(title: "Batch 1"),
            Reference(title: "Batch 2"),
            Reference(title: "Batch 3"),
        ]

        let count = try db.batchImportReferences(refs)
        XCTAssertEqual(count, 3)

        let all = try db.fetchAllReferences()
        XCTAssertEqual(all.count, 3)
    }

    func testBatchImportEmptyArray() throws {
        let db = try makeDatabase()
        let count = try db.batchImportReferences([])
        XCTAssertEqual(count, 0)
    }

    // MARK: - Reference Count

    func testReferenceCount() throws {
        let db = try makeDatabase()
        var ref1 = Reference(title: "Count 1")
        var ref2 = Reference(title: "Count 2")
        try db.saveReference(&ref1)
        try db.saveReference(&ref2)

        let count = try db.referenceCount()
        XCTAssertEqual(count, 2)
    }

    // MARK: - PDF Annotation CRUD

    func testSaveAndFetchAnnotation() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "Annotation Test Ref")
        try db.saveReference(&ref)

        var annotation = PDFAnnotationRecord(
            referenceId: ref.id!,
            type: .highlight,
            selectedText: "Highlighted text",
            pageIndex: 3,
            rects: [CGRect(x: 10, y: 20, width: 100, height: 15)]
        )
        try db.saveAnnotation(&annotation)
        XCTAssertNotNil(annotation.id)

        let annotations = try db.fetchAnnotations(referenceId: ref.id!)
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].selectedText, "Highlighted text")
    }

    func testDeleteAnnotation() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "Delete Annotation Ref")
        try db.saveReference(&ref)

        var annotation = PDFAnnotationRecord(
            referenceId: ref.id!,
            type: .note,
            noteText: "A note",
            pageIndex: 1,
            rects: [CGRect(x: 0, y: 0, width: 50, height: 10)]
        )
        try db.saveAnnotation(&annotation)
        let id = annotation.id!

        try db.deleteAnnotation(id: id)
        let annotations = try db.fetchAnnotations(referenceId: ref.id!)
        XCTAssertTrue(annotations.isEmpty)
    }

    func testAnnotationCount() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "Annotation Count Ref")
        try db.saveReference(&ref)

        for i in 0..<3 {
            var a = PDFAnnotationRecord(
                referenceId: ref.id!,
                type: .highlight,
                pageIndex: i,
                rects: [CGRect(x: 0, y: 0, width: 50, height: 10)]
            )
            try db.saveAnnotation(&a)
        }

        let count = try db.annotationCount(referenceId: ref.id!)
        XCTAssertEqual(count, 3)
    }

    // MARK: - Web Annotation CRUD

    func testSaveAndFetchWebAnnotation() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "Web Annotation Test")
        ref.url = "https://example.com/article"
        try db.saveReference(&ref)

        var annotation = WebAnnotationRecord(
            referenceId: ref.id!,
            type: .highlight,
            anchorText: "Important"
        )
        try db.saveWebAnnotation(&annotation)
        XCTAssertNotNil(annotation.id)

        let annotations = try db.fetchWebAnnotations(referenceId: ref.id!)
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].anchorText, "Important")
    }

    func testDeleteWebAnnotation() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "Delete Web Annotation")
        try db.saveReference(&ref)

        var annotation = WebAnnotationRecord(
            referenceId: ref.id!,
            type: .note,
            noteText: "My note",
            anchorText: "Selected"
        )
        try db.saveWebAnnotation(&annotation)
        let id = annotation.id!

        try db.deleteWebAnnotation(id: id)
        let annotations = try db.fetchWebAnnotations(referenceId: ref.id!)
        XCTAssertTrue(annotations.isEmpty)
    }

    func testWebAnnotationCount() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "Web Annotation Count")
        try db.saveReference(&ref)

        for i in 0..<2 {
            var a = WebAnnotationRecord(
                referenceId: ref.id!,
                type: .highlight,
                anchorText: "Text \(i)"
            )
            try db.saveWebAnnotation(&a)
        }

        let count = try db.webAnnotationCount(referenceId: ref.id!)
        XCTAssertEqual(count, 2)
    }

    // MARK: - fetchWebContent
    //
    // The CLI's `web get` subcommand currently uses `fetchReferences(ids:)`
    // (not `fetchWebContent`) so it can disambiguate "row missing" from
    // "row exists but webContent NULL". These tests pin the lower-level
    // helper's behavior so callers can rely on it: nil for both missing-row
    // and NULL-content, populated string when set.

    func testFetchWebContentReturnsNilForMissingReference() throws {
        let db = try makeDatabase()
        XCTAssertNil(try db.fetchWebContent(id: 999_999))
    }

    func testFetchWebContentReturnsNilWhenColumnIsNull() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "PDF-only ref")
        try db.saveReference(&ref)
        XCTAssertNil(try db.fetchWebContent(id: ref.id!))
    }

    func testFetchWebContentReturnsStoredBody() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "Web-clipped ref")
        try db.saveReference(&ref)
        let body = "# Hello\n\nSome extracted body."
        try db.updateReferenceWebContent(id: ref.id!, webContent: body)

        XCTAssertEqual(try db.fetchWebContent(id: ref.id!), body)
    }

    // MARK: - referencePDF tombstone propagation on Reference delete

    /// Local delete of a Reference with a cached PDF must emit a
    /// `referencePDF` tombstone so peers tear down the sibling
    /// CDReferencePDF record (and its asset bytes against quota).
    func testDeleteReferencesEmitsReferencePDFTombstoneWhenCacheRowExists() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "with PDF")
        try db.saveReference(&ref)
        let id = ref.id!
        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(?, 'paper.pdf', 'h', 1, ?, ?)
            """, arguments: [id, Date(), Date()])
        }

        try db.deleteReferences(ids: [id])

        try db.dbWriter.read { db in
            // Parent reference tombstone (from v1 trigger).
            let refTomb = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM tombstone WHERE entityType='reference' AND entityId=?",
                arguments: [String(id)]) ?? -1
            XCTAssertEqual(refTomb, 1, "parent reference tombstone from trigger")

            // Sibling referencePDF tombstone (from the new Swift emit).
            let pdfTomb = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM tombstone WHERE entityType='referencePDF' AND entityId=?",
                arguments: [String(id)]) ?? -1
            XCTAssertEqual(pdfTomb, 1, "sibling referencePDF tombstone must propagate the delete to peers")

            // pdfCache row dropped via FK cascade.
            let cache = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM pdfCache WHERE referenceId=?",
                arguments: [id]) ?? -1
            XCTAssertEqual(cache, 0)
        }
    }

    /// Don't emit spurious tombstones for references that never had a PDF —
    /// peers would receive a CDReferencePDF tombstone for a record that
    /// never existed.
    func testDeleteReferencesSkipsReferencePDFTombstoneWhenNoCacheRow() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "no PDF")
        try db.saveReference(&ref)
        let id = ref.id!

        try db.deleteReferences(ids: [id])

        try db.dbWriter.read { db in
            let pdfTomb = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM tombstone WHERE entityType='referencePDF' AND entityId=?",
                arguments: [String(id)]) ?? -1
            XCTAssertEqual(pdfTomb, 0, "no pdfCache row → no referencePDF tombstone")
        }
    }

    /// Same coverage for the production-used variant — the app and CLI
    /// delete via `deleteReferencesReturningPDFPaths`, not the simpler
    /// `deleteReferences`. Both must emit the sibling tombstone.
    func testDeleteReferencesReturningPDFPathsEmitsReferencePDFTombstone() throws {
        let db = try makeDatabase()
        var ref = Reference(title: "with PDF for return-paths variant")
        try db.saveReference(&ref)
        let id = ref.id!
        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(?, 'returned-name.pdf', 'h', 1, ?, ?)
            """, arguments: [id, Date(), Date()])
        }

        let returned = try db.deleteReferencesReturningPDFPaths(ids: [id])
        XCTAssertEqual(returned, ["returned-name.pdf"])

        try db.dbWriter.read { db in
            let pdfTomb = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM tombstone WHERE entityType='referencePDF' AND entityId=?",
                arguments: [String(id)]) ?? -1
            XCTAssertEqual(pdfTomb, 1)
        }
    }

    // MARK: - dirtyReferencePDFCount

    func testDirtyReferencePDFCountIsZeroOnFreshDB() throws {
        let db = try makeDatabase()
        XCTAssertEqual(try db.dirtyReferencePDFCount(), 0)
    }

    func testDirtyReferencePDFCountOnlyCountsDirtyReferencePDFRows() throws {
        let db = try makeDatabase()
        try db.dbWriter.write { db in
            // Two dirty referencePDF rows — should be counted.
            try db.execute(sql: """
                INSERT INTO syncState(entityType, entityId, isDirty, pushInFlight)
                VALUES('referencePDF', '1', 1, 0), ('referencePDF', '2', 1, 0)
            """)
            // Clean referencePDF row — must NOT count.
            try db.execute(sql: """
                INSERT INTO syncState(entityType, entityId, isDirty, pushInFlight)
                VALUES('referencePDF', '3', 0, 0)
            """)
            // Dirty row of a different entityType — must NOT count.
            try db.execute(sql: """
                INSERT INTO syncState(entityType, entityId, isDirty, pushInFlight)
                VALUES('reference', '99', 1, 0)
            """)
        }
        XCTAssertEqual(try db.dirtyReferencePDFCount(), 2)
    }
}
