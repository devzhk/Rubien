import Foundation

/// The unified `create_reference` / `add --source` output envelope (spec §5.4):
/// one shape for every route, carrying everything today's `add` / `import`
/// outputs carry with no information loss. Assembled in RubienCore so its
/// summary/ordering/field-omission machinery is unit-tested here (portable,
/// Linux-covered); the CLI supplies the concrete DTO types.
///
/// Generic over the reference DTO (`Ref`) and PDF-download DTO (`PDF`) because
/// both are CLI-private (`ReferenceDTO` / `PDFDownloadStatusDTO`) — RubienCore
/// owns the *shape*, the CLI maps `Reference` outcomes to full DTOs post-commit
/// (§5.3 type boundary: `ItemOutcome` never references `ReferenceDTO`).
public struct CreateReferenceEnvelope<Ref: Encodable & Sendable, PDF: Encodable & Sendable>: Encodable, Sendable {
    public var items: [CreateReferenceItem<Ref, PDF>]
    public var summary: ImportSummary
    /// Route-specific diagnostics; omitted entirely when the route produced
    /// none (§5.4 "present when the route produces them").
    public var diagnostics: CreateReferenceDiagnostics?

    public init(
        items: [CreateReferenceItem<Ref, PDF>],
        summary: ImportSummary,
        diagnostics: CreateReferenceDiagnostics? = nil
    ) {
        self.items = items
        self.summary = summary
        self.diagnostics = diagnostics
    }
}

/// One item in the unified envelope — a single parsed input's outcome (§5.4).
/// Nil optionals are omitted by Swift's synthesized `Encodable` (`encodeIfPresent`),
/// which is exactly the spec's shape: `reference` absent for queued-unlinked /
/// failed items, `intakeId` only for queued, `pdfDownload` only when a fetch was
/// attempted, `error` only for failed. `status` and `input` are always present.
public struct CreateReferenceItem<Ref: Encodable & Sendable, PDF: Encodable & Sendable>: Encodable, Sendable {
    public var reference: Ref?
    public var status: ItemOutcome.Disposition
    public var intakeId: Int64?
    public var input: String
    public var pdfDownload: PDF?
    public var error: String?

    public init(
        reference: Ref? = nil,
        status: ItemOutcome.Disposition,
        intakeId: Int64? = nil,
        input: String,
        pdfDownload: PDF? = nil,
        error: String? = nil
    ) {
        self.reference = reference
        self.status = status
        self.intakeId = intakeId
        self.input = input
        self.pdfDownload = pdfDownload
        self.error = error
    }
}

/// Per-disposition input counts (§5.4). Counts *inputs*, not distinct
/// references — an intra-batch duplicate contributes two items (one `created`,
/// one `existing`).
public struct ImportSummary: Encodable, Sendable, Equatable {
    public var created: Int
    public var existing: Int
    public var queued: Int
    public var failed: Int

    public init(created: Int = 0, existing: Int = 0, queued: Int = 0, failed: Int = 0) {
        self.created = created
        self.existing = existing
        self.queued = queued
        self.failed = failed
    }

    /// Tally a disposition list into a summary.
    public init(dispositions: [ItemOutcome.Disposition]) {
        var c = 0, e = 0, q = 0, f = 0
        for d in dispositions {
            switch d {
            case .created: c += 1
            case .existing: e += 1
            case .queued: q += 1
            case .failed: f += 1
            }
        }
        self.init(created: c, existing: e, queued: q, failed: f)
    }

    /// A succeeded input is created / existing / queued (§5.3).
    public var succeeded: Int { created + existing + queued }

    /// Exit is a failure iff **zero** items succeeded (spec §5.3). Partial
    /// success (some succeeded, some failed) exits 0 with failures visible in
    /// `items`. An empty item list (no inputs) is also a failure.
    public var isFailure: Bool { succeeded == 0 }
}

/// Route-specific diagnostics (§5.4). Every field is optional and omitted when
/// nil, so a route contributes only the diagnostics it produces:
/// `file` for single-file / URL routes; `property`/`value` for folder stamping;
/// `attached`/`duplicatesSkipped`/`missingPDFs` for Zotero.
public struct CreateReferenceDiagnostics: Encodable, Sendable, Equatable {
    public var file: String?
    public var property: String?
    public var value: String?
    public var attached: Int?
    public var duplicatesSkipped: Int?
    public var missingPDFs: [String]?

    public init(
        file: String? = nil,
        property: String? = nil,
        value: String? = nil,
        attached: Int? = nil,
        duplicatesSkipped: Int? = nil,
        missingPDFs: [String]? = nil
    ) {
        self.file = file
        self.property = property
        self.value = value
        self.attached = attached
        self.duplicatesSkipped = duplicatesSkipped
        self.missingPDFs = missingPDFs
    }

    /// True when the route produced no diagnostics — the CLI omits the whole
    /// `diagnostics` object in that case.
    public var isEmpty: Bool {
        file == nil && property == nil && value == nil
            && attached == nil && duplicatesSkipped == nil && missingPDFs == nil
    }
}
