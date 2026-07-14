import Foundation

/// Per-item result of an import route, threaded through the batch/PDF/Zotero
/// pipelines so a unified `create_reference` envelope can report one entry per
/// parsed input (spec §5.3). This is the RubienCore-side domain value: it
/// carries a `Reference` (never the CLI-private `ReferenceDTO`) that the CLI
/// maps to a full DTO after commit. Item cardinality is per parsed input, not
/// per distinct reference — an intra-batch duplicate yields two items pointing
/// at the same `Reference`, the later one `.existing`.
public struct ItemOutcome: Sendable, Equatable {
    /// What happened to this input. Exactly the four dispositions the envelope
    /// distinguishes:
    /// - `created`: a fresh row was inserted.
    /// - `existing`: the input deduped into an already-present row (merge).
    /// - `queued`: persisted as a pending `MetadataIntake` awaiting verification.
    /// - `failed`: the input could not be persisted (`error` carries the cause).
    public enum Disposition: String, Sendable, Equatable, Codable, CaseIterable {
        case created
        case existing
        case queued
        case failed
    }

    /// The resolved/merged reference for a successful item. Absent for `queued`
    /// items that have no linked reference yet and for `failed` items.
    public var reference: Reference?
    public var disposition: Disposition
    /// The `MetadataIntake` row id for a `queued` item (a queued intake may have
    /// no reference yet). Nil otherwise.
    public var intakeId: Int64?
    /// Provenance: the source entry / file path / locator this item came from.
    /// Always present. See spec §5.3 for the per-route format
    /// (e.g. `"<file path>#bibtex[<ordinal>]"` for a BibTeX entry).
    public var input: String
    /// The failure cause for a `failed` item; nil otherwise.
    public var error: String?

    public init(
        reference: Reference? = nil,
        disposition: Disposition,
        intakeId: Int64? = nil,
        input: String,
        error: String? = nil
    ) {
        self.reference = reference
        self.disposition = disposition
        self.intakeId = intakeId
        self.input = input
        self.error = error
    }
}
