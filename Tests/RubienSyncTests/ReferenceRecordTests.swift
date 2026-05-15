#if os(macOS)
import XCTest
import CloudKit
@testable import RubienCore
@testable import RubienSync

final class ReferenceRecordTests: XCTestCase {

    // MARK: - Helpers

    private let recordName = "test-record-name"

    /// Dates round-trip through CloudKit to second precision in practice, but
    /// CKRecord preserves the full Date resolution locally, so round-trip
    /// through in-memory records is exact. Use a fixed Date fraction so the
    /// assertions are deterministic.
    private func fixedDate(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    private func makeFullReference() -> Reference {
        var ref = Reference(
            title: "Attention is All You Need",
            authors: [
                AuthorName(given: "Ashish", family: "Vaswani"),
                AuthorName(given: "Noam", family: "Shazeer"),
            ],
            year: 2017,
            journal: "NeurIPS",
            volume: "30",
            issue: "1",
            pages: "5998-6008",
            doi: "10.48550/arXiv.1706.03762",
            url: "https://arxiv.org/abs/1706.03762",
            abstract: "The dominant sequence transduction models ...",
            dateAdded: fixedDate(0),
            dateModified: fixedDate(3600),
            notes: "Foundational paper",
            webContent: "<p>cached</p>",
            siteName: "arXiv",
            favicon: "https://arxiv.org/favicon.ico",
            referenceType: .conferencePaper,
            metadataSource: .translationServer,
            verificationStatus: .verifiedManual,
            acceptedByRuleID: "j1DOIExact",
            recordKey: "crossref:10.48550/arxiv.1706.03762",
            verificationSourceURL: "https://api.crossref.org/...",
            evidenceBundleHash: "sha256:abcdef",
            verifiedAt: fixedDate(7200),
            reviewedBy: "alice",
            readingStatus: ReadingStatus.read,
            publisher: "ACM",
            publisherPlace: "New York",
            edition: "1st",
            editors: #"[{"given":"Ed","family":"Itor"}]"#,
            isbn: "978-0-262-04462-4",
            issn: "1234-5678",
            accessedDate: "2024-01-15",
            issuedMonth: 6,
            issuedDay: 12,
            translators: #"[{"given":"Tr","family":"Anslator"}]"#,
            eventTitle: "NeurIPS 2017",
            eventPlace: "Long Beach, CA",
            genre: "conference",
            institution: "Google Brain",
            number: "TR-2017-01",
            collectionTitle: "Advances in Neural Information Processing Systems",
            numberOfPages: "11",
            language: "en",
            pmid: "12345678",
            pmcid: "PMC1234567"
        )
        ref.id = 42  // local rowID, must NOT be encoded into the CKRecord
        ref.lastReadAt = fixedDate(10_800)
        ref.readCount = 7
        return ref
    }

    // MARK: - Round trip

    func testFullFieldRoundTrip() {
        let original = makeFullReference()
        let record = Reference.makeRecord(recordName: recordName, reference: original)

        XCTAssertEqual(record.recordType, SyncConstants.RecordType.reference)
        XCTAssertEqual(record.recordID.recordName, recordName)
        XCTAssertEqual(record.recordID.zoneID, SyncConstants.libraryZoneID)

        var decoded = Reference(record: record)
        // Decoded reference has no local rowID; set it manually to match
        // original for the equality assertion.
        decoded.id = original.id

        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.authors, original.authors)
        XCTAssertEqual(decoded.year, original.year)
        XCTAssertEqual(decoded.journal, original.journal)
        XCTAssertEqual(decoded.volume, original.volume)
        XCTAssertEqual(decoded.issue, original.issue)
        XCTAssertEqual(decoded.pages, original.pages)
        XCTAssertEqual(decoded.doi, original.doi)
        XCTAssertEqual(decoded.url, original.url)
        XCTAssertEqual(decoded.abstract, original.abstract)
        XCTAssertEqual(decoded.dateAdded, original.dateAdded)
        XCTAssertEqual(decoded.dateModified, original.dateModified)
        XCTAssertEqual(decoded.notes, original.notes)
        XCTAssertEqual(decoded.webContent, original.webContent)
        XCTAssertEqual(decoded.siteName, original.siteName)
        XCTAssertEqual(decoded.favicon, original.favicon)
        XCTAssertEqual(decoded.referenceType, original.referenceType)
        XCTAssertEqual(decoded.metadataSource, original.metadataSource)
        XCTAssertEqual(decoded.verificationStatus, original.verificationStatus)
        XCTAssertEqual(decoded.acceptedByRuleID, original.acceptedByRuleID)
        XCTAssertEqual(decoded.recordKey, original.recordKey)
        XCTAssertEqual(decoded.verificationSourceURL, original.verificationSourceURL)
        XCTAssertEqual(decoded.evidenceBundleHash, original.evidenceBundleHash)
        XCTAssertEqual(decoded.verifiedAt, original.verifiedAt)
        XCTAssertEqual(decoded.reviewedBy, original.reviewedBy)
        XCTAssertEqual(decoded.readingStatus, original.readingStatus)
        XCTAssertEqual(decoded.lastReadAt, original.lastReadAt)
        XCTAssertEqual(decoded.readCount, original.readCount)
        XCTAssertEqual(decoded.publisher, original.publisher)
        XCTAssertEqual(decoded.publisherPlace, original.publisherPlace)
        XCTAssertEqual(decoded.edition, original.edition)
        XCTAssertEqual(decoded.editors, original.editors)
        XCTAssertEqual(decoded.isbn, original.isbn)
        XCTAssertEqual(decoded.issn, original.issn)
        XCTAssertEqual(decoded.accessedDate, original.accessedDate)
        XCTAssertEqual(decoded.issuedMonth, original.issuedMonth)
        XCTAssertEqual(decoded.issuedDay, original.issuedDay)
        XCTAssertEqual(decoded.translators, original.translators)
        XCTAssertEqual(decoded.eventTitle, original.eventTitle)
        XCTAssertEqual(decoded.eventPlace, original.eventPlace)
        XCTAssertEqual(decoded.genre, original.genre)
        XCTAssertEqual(decoded.institution, original.institution)
        XCTAssertEqual(decoded.number, original.number)
        XCTAssertEqual(decoded.collectionTitle, original.collectionTitle)
        XCTAssertEqual(decoded.numberOfPages, original.numberOfPages)
        XCTAssertEqual(decoded.language, original.language)
        XCTAssertEqual(decoded.pmid, original.pmid)
        XCTAssertEqual(decoded.pmcid, original.pmcid)
    }

    // MARK: - ID / attachment boundaries

    func testLocalIDIsNotEncodedInRecord() {
        let original = makeFullReference()
        let record = Reference.makeRecord(recordName: recordName, reference: original)
        XCTAssertNil(record["id"], "local rowID must not leak into the CKRecord")
    }

    func testPdfPathIsNotEncodedInRecord() {
        // Post-B8: Reference.pdfPath is gone, so the encoder couldn't write it
        // even if it tried. The CKRecord invariant remains worth asserting:
        // CDReference must never carry a `pdfPath` field — attachments live
        // on the sibling CDReferencePDF record (still to land in Phase B).
        let record = Reference.makeRecord(recordName: recordName, reference: makeFullReference())
        XCTAssertNil(
            record["pdfPath"],
            "pdfPath belongs on the sibling CDReferencePDF record, not on CDReference"
        )
    }

    func testDecodedReferenceHasNilLocalID() {
        let record = Reference.makeRecord(recordName: recordName, reference: makeFullReference())
        let decoded = Reference(record: record)
        XCTAssertNil(decoded.id, "decode must leave local rowID nil; caller resolves it")
    }

    // MARK: - Minimal reference (most fields nil)

    func testMinimalReferenceRoundTrip() {
        let minimal = Reference(
            title: "Minimal",
            dateAdded: fixedDate(0),
            dateModified: fixedDate(0)
        )
        let record = Reference.makeRecord(recordName: recordName, reference: minimal)
        var decoded = Reference(record: record)
        decoded.id = minimal.id

        XCTAssertEqual(decoded.title, "Minimal")
        XCTAssertEqual(decoded.authors, [])
        XCTAssertNil(decoded.year)
        XCTAssertNil(decoded.journal)
        XCTAssertNil(decoded.doi)
        XCTAssertEqual(decoded.referenceType, .journalArticle, "default type round-trips")
        XCTAssertEqual(decoded.readingStatus, ReadingStatus.unread)
        XCTAssertEqual(decoded.verificationStatus, .legacy)
        XCTAssertNil(decoded.lastReadAt, "fresh reference has never been read")
        XCTAssertEqual(decoded.readCount, 0)
    }

    /// Records written by a pre-v4 peer don't carry `lastReadAt` / `readCount`.
    /// Our decoder must fall back to the "never read" defaults rather than
    /// throwing or producing garbage values.
    func testPreV4RecordDecodesToNeverReadDefaults() {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(recordType: SyncConstants.RecordType.reference, recordID: id)
        record[Reference.RecordField.title] = "t"
        record[Reference.RecordField.dateAdded] = fixedDate(0)
        record[Reference.RecordField.dateModified] = fixedDate(0)
        // Deliberately do NOT set lastReadAt or readCount — simulates a peer
        // that has not yet upgraded to v4.

        let decoded = Reference(record: record)
        XCTAssertNil(decoded.lastReadAt, "missing lastReadAt must decode to nil")
        XCTAssertEqual(decoded.readCount, 0, "missing readCount must decode to 0")
    }

    // MARK: - Enum fallback

    func testUnknownReferenceTypeFallsBackToOther() {
        let record = CKRecord(
            recordType: SyncConstants.RecordType.reference,
            recordID: CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        )
        record[Reference.RecordField.title] = "t"
        record[Reference.RecordField.dateAdded] = fixedDate(0)
        record[Reference.RecordField.dateModified] = fixedDate(0)
        record[Reference.RecordField.referenceType] = "SomeFutureType"  // unknown rawValue
        record[Reference.RecordField.readingStatus] = "obsessed"         // user-added status
        record[Reference.RecordField.verificationStatus] = "quantum"      // unknown

        let decoded = Reference(record: record)
        XCTAssertEqual(decoded.referenceType, .other, "unknown type falls back to .other")
        // Post-Phase-2: readingStatus is free-form String, so user-added
        // values pass through unchanged (no enum coercion). Sync forward-compat
        // is now structurally trivial — peers see whatever the writer wrote.
        XCTAssertEqual(decoded.readingStatus, "obsessed", "free-form readingStatus passes through unchanged")
        XCTAssertEqual(decoded.verificationStatus, .legacy, "unknown verificationStatus falls back to .legacy")
    }

    // MARK: - Authors JSON

    func testEmptyAuthorsEncodedAsJSONEmptyArray() {
        var ref = Reference(title: "x")
        ref.authors = []
        let record = Reference.makeRecord(recordName: recordName, reference: ref)
        XCTAssertEqual(
            record[Reference.RecordField.authorsJSON] as? String,
            "[]",
            "empty authors array must still produce a parseable JSON '[]'"
        )
    }

    func testAuthorsRoundTripPreservesOrderAndFields() {
        var ref = Reference(title: "x")
        ref.authors = [
            AuthorName(given: "Ada", family: "Lovelace"),
            AuthorName(given: "Alan", family: "Turing"),
            AuthorName(given: "",    family: "Anonymous"),  // edge: given may be empty
        ]
        let record = Reference.makeRecord(recordName: recordName, reference: ref)
        let decoded = Reference(record: record)
        XCTAssertEqual(decoded.authors, ref.authors)
    }

    // MARK: - Populate preserves existing system-fields semantics

    func testPopulateMutatesProvidedRecord() {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let existing = CKRecord(recordType: SyncConstants.RecordType.reference, recordID: id)
        var ref = Reference(title: "Initial", dateAdded: fixedDate(0), dateModified: fixedDate(0))

        ref.populate(record: existing)
        XCTAssertEqual(existing[Reference.RecordField.title] as? String, "Initial")

        ref.title = "Updated"
        ref.populate(record: existing)
        XCTAssertEqual(
            existing[Reference.RecordField.title] as? String,
            "Updated",
            "populate must mutate the provided record, not allocate a fresh one"
        )
        // recordID stays the same (caller-controlled).
        XCTAssertEqual(existing.recordID, id)
    }
}
#endif
