#if canImport(CloudKit)
import Foundation
import CloudKit
import RubienCore

/// Bidirectional mapping between `Reference` (the local GRDB row) and
/// `CKRecord` (the CloudKit payload).
///
/// The record's stable identity is `CKRecord.ID.recordName` — the caller
/// supplies that externally. This decouples mapping from whether the local PK
/// is an Int64 (pre-A-pks) or a UUID string (post-A-pks). The Swift `id`
/// property is never written to or read from the CKRecord: it's a local rowID.
///
/// Per Apple's CKSyncEngine guidance (WWDC 2023 + Selig 2026), we `populate`
/// into an existing `CKRecord` rather than creating a fresh one — so when we
/// rehydrate a cached record (carrying server system fields for optimistic
/// concurrency) we preserve those fields and only overwrite scalars.
extension Reference {

    // MARK: - CKRecord field keys

    public enum RecordField {
        public static let title                 = "title"
        public static let authorsJSON           = "authorsJSON"
        public static let year                  = "year"
        public static let journal               = "journal"
        public static let volume                = "volume"
        public static let issue                 = "issue"
        public static let pages                 = "pages"
        public static let doi                   = "doi"
        public static let url                   = "url"
        public static let abstract              = "abstract"
        public static let dateAdded             = "dateAdded"
        public static let dateModified          = "dateModified"
        public static let notes                 = "notes"
        public static let webContent            = "webContent"
        public static let siteName              = "siteName"
        public static let favicon               = "favicon"
        public static let referenceType         = "referenceType"
        public static let metadataSource        = "metadataSource"
        public static let verificationStatus    = "verificationStatus"
        public static let acceptedByRuleID      = "acceptedByRuleID"
        public static let recordKey             = "recordKey"
        public static let verificationSourceURL = "verificationSourceURL"
        public static let evidenceBundleHash    = "evidenceBundleHash"
        public static let verifiedAt            = "verifiedAt"
        public static let reviewedBy            = "reviewedBy"
        public static let readingStatus         = "readingStatus"
        public static let lastReadAt            = "lastReadAt"
        public static let readCount             = "readCount"
        public static let publisher             = "publisher"
        public static let publisherPlace        = "publisherPlace"
        public static let edition               = "edition"
        public static let editorsJSON           = "editorsJSON"
        public static let isbn                  = "isbn"
        public static let issn                  = "issn"
        public static let accessedDate          = "accessedDate"
        public static let issuedMonth           = "issuedMonth"
        public static let issuedDay             = "issuedDay"
        public static let translatorsJSON       = "translatorsJSON"
        public static let eventTitle            = "eventTitle"
        public static let eventPlace            = "eventPlace"
        public static let genre                 = "genre"
        public static let institution           = "institution"
        public static let number                = "number"
        public static let collectionTitle       = "collectionTitle"
        public static let numberOfPages         = "numberOfPages"
        public static let language              = "language"
        public static let pmid                  = "pmid"
        public static let pmcid                 = "pmcid"
    }

    /// Schema-invariant test (Phase E) reads this. The list is the set of
    /// `reference` table columns this CKRecord schema covers — i.e. every
    /// column whose value is round-tripped through `populate(record:)` /
    /// `init(record:)`. Most entries match `RecordField.*` 1:1, but a few
    /// CloudKit field names diverge from DB column names (the `*JSON`
    /// wire-format keys for the parsed `authors`/`editors`/`translators`
    /// arrays); `allFieldNames` lists the DB column name in those cases so
    /// the schema-invariant diff against `pragma_table_info` works directly.
    ///
    /// Note: `pdfPath` is intentionally absent — per-device PDF state lives in
    /// the local-only `pdfCache` table, never in the Reference CKRecord.
    /// `authorsNormalized` is a computed Swift property recomputed on every
    /// encode and never written to CloudKit (it's in `neverInRecord`).
    public static let allFieldNames: [String] = [
        RecordField.title,
        "authors",            // wire: authorsJSON; column: authors
        RecordField.year,
        RecordField.journal,
        RecordField.volume,
        RecordField.issue,
        RecordField.pages,
        RecordField.doi,
        RecordField.url,
        RecordField.abstract,
        RecordField.dateAdded,
        RecordField.dateModified,
        RecordField.notes,
        RecordField.webContent,
        RecordField.siteName,
        RecordField.favicon,
        RecordField.referenceType,
        RecordField.metadataSource,
        RecordField.verificationStatus,
        RecordField.acceptedByRuleID,
        RecordField.recordKey,
        RecordField.verificationSourceURL,
        RecordField.evidenceBundleHash,
        RecordField.verifiedAt,
        RecordField.reviewedBy,
        RecordField.readingStatus,
        RecordField.lastReadAt,
        RecordField.readCount,
        RecordField.publisher,
        RecordField.publisherPlace,
        RecordField.edition,
        "editors",            // wire: editorsJSON; column: editors
        RecordField.isbn,
        RecordField.issn,
        RecordField.accessedDate,
        RecordField.issuedMonth,
        RecordField.issuedDay,
        "translators",        // wire: translatorsJSON; column: translators
        RecordField.eventTitle,
        RecordField.eventPlace,
        RecordField.genre,
        RecordField.institution,
        RecordField.number,
        RecordField.collectionTitle,
        RecordField.numberOfPages,
        RecordField.language,
        RecordField.pmid,
        RecordField.pmcid,
    ]

    // MARK: - Encode

    /// Write every syncable scalar into `record`. Does not write the local `id`
    /// (that lives in `record.recordID.recordName`, set by the caller) and
    /// does not write `pdfPath` (attachments live on sibling `CDReferencePDF`).
    public func populate(record: CKRecord) {
        record[RecordField.title]                 = title
        record[RecordField.authorsJSON]           = Self.encodeAuthorsJSON(authors)
        record[RecordField.year]                  = year.map { Int64($0) }
        record[RecordField.journal]               = journal
        record[RecordField.volume]                = volume
        record[RecordField.issue]                 = issue
        record[RecordField.pages]                 = pages
        record[RecordField.doi]                   = doi
        record[RecordField.url]                   = url
        record[RecordField.abstract]              = abstract
        record[RecordField.dateAdded]             = dateAdded
        record[RecordField.dateModified]          = dateModified
        record[RecordField.notes]                 = notes
        record[RecordField.webContent]            = webContent
        record[RecordField.siteName]              = siteName
        record[RecordField.favicon]               = favicon
        record[RecordField.referenceType]         = referenceType.rawValue
        record[RecordField.metadataSource]        = metadataSource?.rawValue
        record[RecordField.verificationStatus]    = verificationStatus.rawValue
        record[RecordField.acceptedByRuleID]      = acceptedByRuleID
        record[RecordField.recordKey]             = recordKey
        record[RecordField.verificationSourceURL] = verificationSourceURL
        record[RecordField.evidenceBundleHash]    = evidenceBundleHash
        record[RecordField.verifiedAt]            = verifiedAt
        record[RecordField.reviewedBy]            = reviewedBy
        record[RecordField.readingStatus]         = readingStatus
        record[RecordField.lastReadAt]            = lastReadAt
        record[RecordField.readCount]             = Int64(readCount)
        record[RecordField.publisher]             = publisher
        record[RecordField.publisherPlace]        = publisherPlace
        record[RecordField.edition]               = edition
        record[RecordField.editorsJSON]           = editors
        record[RecordField.isbn]                  = isbn
        record[RecordField.issn]                  = issn
        record[RecordField.accessedDate]          = accessedDate
        record[RecordField.issuedMonth]           = issuedMonth.map { Int64($0) }
        record[RecordField.issuedDay]             = issuedDay.map { Int64($0) }
        record[RecordField.translatorsJSON]       = translators
        record[RecordField.eventTitle]            = eventTitle
        record[RecordField.eventPlace]            = eventPlace
        record[RecordField.genre]                 = genre
        record[RecordField.institution]           = institution
        record[RecordField.number]                = number
        record[RecordField.collectionTitle]       = collectionTitle
        record[RecordField.numberOfPages]         = numberOfPages
        record[RecordField.language]              = language
        record[RecordField.pmid]                  = pmid
        record[RecordField.pmcid]                 = pmcid
    }

    /// Create a fresh record in the library zone and populate it. Used when a
    /// local row has no cached server state yet (first push).
    public static func makeRecord(recordName: String, reference: Reference) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
        let record = CKRecord(recordType: SyncConstants.RecordType.reference, recordID: id)
        reference.populate(record: record)
        return record
    }

    // MARK: - Decode

    /// Build a Reference from a `CKRecord`. The resulting Reference's local
    /// `id` is always `nil` — the caller resolves the local rowID (via the
    /// record's `recordName` + local mapping) before persisting.
    ///
    /// Unknown enum rawValues fall back to safe defaults (`.other`,
    /// `.unread`, `.legacy`) rather than throwing — per CKSyncEngine guidance
    /// on forward/backward compatibility: never crash when a newer device
    /// writes a case this version doesn't know about.
    public init(record: CKRecord) {
        self.init(title: (record[RecordField.title] as? String) ?? "")

        self.authors = Self.decodeAuthorsJSON(record[RecordField.authorsJSON] as? String)

        self.year         = (record[RecordField.year] as? Int64).map { Int($0) }
        self.journal      = record[RecordField.journal] as? String
        self.volume       = record[RecordField.volume] as? String
        self.issue        = record[RecordField.issue] as? String
        self.pages        = record[RecordField.pages] as? String
        self.doi          = record[RecordField.doi] as? String
        self.url          = record[RecordField.url] as? String
        self.abstract     = record[RecordField.abstract] as? String
        self.dateAdded    = (record[RecordField.dateAdded] as? Date) ?? Date()
        self.dateModified = (record[RecordField.dateModified] as? Date) ?? self.dateAdded
        self.notes        = record[RecordField.notes] as? String
        self.webContent   = record[RecordField.webContent] as? String
        self.siteName     = record[RecordField.siteName] as? String
        self.favicon      = record[RecordField.favicon] as? String

        self.referenceType = (record[RecordField.referenceType] as? String)
            .flatMap(ReferenceType.init(rawValue:)) ?? .other
        self.metadataSource = (record[RecordField.metadataSource] as? String)
            .flatMap(MetadataSource.init(rawValue:))
        self.verificationStatus = (record[RecordField.verificationStatus] as? String)
            .flatMap(VerificationStatus.init(rawValue:)) ?? .legacy
        // Post-Phase-2: readingStatus is a free-form String. Pass through the
        // CKRecord value unchanged; if missing, fall back to the seeded
        // built-in "Unread".
        self.readingStatus = (record[RecordField.readingStatus] as? String) ?? ReadingStatus.unread

        // v4: reader activity. Both fields are absent on records written by
        // pre-v4 peers — fall back to "never read" semantics rather than
        // throwing, per the same forward-compat rule as the enums above.
        self.lastReadAt = record[RecordField.lastReadAt] as? Date
        self.readCount = (record[RecordField.readCount] as? Int64).map(Int.init) ?? 0

        self.acceptedByRuleID      = record[RecordField.acceptedByRuleID] as? String
        self.recordKey             = record[RecordField.recordKey] as? String
        self.verificationSourceURL = record[RecordField.verificationSourceURL] as? String
        self.evidenceBundleHash    = record[RecordField.evidenceBundleHash] as? String
        self.verifiedAt            = record[RecordField.verifiedAt] as? Date
        self.reviewedBy            = record[RecordField.reviewedBy] as? String

        self.publisher       = record[RecordField.publisher] as? String
        self.publisherPlace  = record[RecordField.publisherPlace] as? String
        self.edition         = record[RecordField.edition] as? String
        self.editors         = record[RecordField.editorsJSON] as? String
        self.isbn            = record[RecordField.isbn] as? String
        self.issn            = record[RecordField.issn] as? String
        self.accessedDate    = record[RecordField.accessedDate] as? String
        self.issuedMonth     = (record[RecordField.issuedMonth] as? Int64).map { Int($0) }
        self.issuedDay       = (record[RecordField.issuedDay] as? Int64).map { Int($0) }
        self.translators     = record[RecordField.translatorsJSON] as? String
        self.eventTitle      = record[RecordField.eventTitle] as? String
        self.eventPlace      = record[RecordField.eventPlace] as? String
        self.genre           = record[RecordField.genre] as? String
        self.institution     = record[RecordField.institution] as? String
        self.number          = record[RecordField.number] as? String
        self.collectionTitle = record[RecordField.collectionTitle] as? String
        self.numberOfPages   = record[RecordField.numberOfPages] as? String
        self.language        = record[RecordField.language] as? String
        self.pmid            = record[RecordField.pmid] as? String
        self.pmcid           = record[RecordField.pmcid] as? String
    }

    // MARK: - Author array codec
    // DB stores `authors` as JSON too; we reuse the same shape in CKRecord for
    // consistency and to avoid lossy re-splitting of parsed names.

    private static func encodeAuthorsJSON(_ names: [AuthorName]) -> String {
        guard let data = try? JSONEncoder().encode(names),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func decodeAuthorsJSON(_ json: String?) -> [AuthorName] {
        guard let json,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([AuthorName].self, from: data) else {
            return []
        }
        return decoded
    }
}
#endif
