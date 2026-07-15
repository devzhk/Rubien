import Foundation

extension AppDatabase {
    /// Import parsed entries with **per-entry continuation** (spec §5.3 inline-
    /// BibTeX / manual-title semantics): each entry is persisted in its own
    /// `saveReference` transaction, and a failure records one `.failed`
    /// `ItemOutcome` while the remaining entries are still attempted. Returns
    /// exactly one outcome per input entry, in input order (1:1 provenance).
    ///
    /// This is the deliberate §5.3 behavior change for the inline BibTeX route:
    /// the legacy loop stopped on the first failure with earlier entries already
    /// committed; here every entry is attempted and each failure is a visible
    /// `.failed` item.
    ///
    /// Contrast `batchImportReferencesDetailed`, which persists the whole batch
    /// in one transaction and *throws* on failure (file/folder routes whose spec
    /// semantics are batch-atomic). Same dedup/merge behavior as `saveReference`.
    public func importEntriesContinuingPastFailures(
        _ entries: [DetailedImportEntry]
    ) -> [ItemOutcome] {
        entries.map { entry in
            var ref = entry.reference
            do {
                let result = try saveReference(&ref)
                return ItemOutcome(
                    reference: ref,
                    disposition: result == .existing ? .existing : .created,
                    input: entry.input
                )
            } catch {
                return ItemOutcome(
                    disposition: .failed,
                    input: entry.input,
                    error: error.localizedDescription
                )
            }
        }
    }
}
