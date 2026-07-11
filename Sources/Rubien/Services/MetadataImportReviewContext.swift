#if os(macOS)
import Foundation
import RubienCore

struct PreparedMetadataImport: Identifiable, Sendable {
    let id: UUID
    let input: String
    var result: MetadataResolutionResult

    init(id: UUID = UUID(), input: String, result: MetadataResolutionResult) {
        self.id = id
        self.input = input
        self.result = result
    }
}

@MainActor
final class MetadataImportReviewContext: ImportReviewContext {
    let items: [ImportReviewItem]

    private let database: AppDatabase
    private let resolver: MetadataResolver
    private var entriesByID: [UUID: PreparedMetadataImport]

    init(
        database: AppDatabase,
        resolver: MetadataResolver? = nil,
        entries: [PreparedMetadataImport]
    ) {
        self.database = database
        self.resolver = resolver ?? MetadataResolver()
        self.entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        self.items = entries.map(Self.makeItem)
    }

    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport {
        let selected = selectedIDs.compactMap { entriesByID[$0] }
        let references = selected.compactMap { entry -> Reference? in
            guard case .verified(let envelope) = entry.result else { return nil }
            return envelope.reference
        }

        guard references.count == selected.count else {
            let message = "Choose or confirm metadata before importing this reference."
            return ImportReviewCommitReport(
                succeededIDs: [],
                failures: Dictionary(uniqueKeysWithValues: selectedIDs.map { ($0, message) })
            )
        }

        do {
            _ = try database.batchImportReferences(references, mergePolicy: .standard)
            for id in selectedIDs {
                entriesByID.removeValue(forKey: id)
            }
            return ImportReviewCommitReport(succeededIDs: selectedIDs, failures: [:])
        } catch {
            return ImportReviewCommitReport(
                succeededIDs: [],
                failures: Dictionary(
                    uniqueKeysWithValues: selectedIDs.map { ($0, error.localizedDescription) }
                )
            )
        }
    }

    func resolveCandidate(
        itemID: UUID,
        candidate: MetadataCandidate
    ) async -> ImportReviewItem {
        guard var entry = entriesByID[itemID] else { return item(id: itemID) }
        let projection = Self.project(entry.result)
        entry.result = await resolver.resolveCandidate(
            candidate,
            fallback: projection.reference,
            seed: projection.seed,
            treatingManualSelectionAsConfirmation: true,
            reviewedBy: "batch-identifier-review"
        )
        entriesByID[itemID] = entry
        return Self.makeItem(entry)
    }

    func useProposedMetadata(itemID: UUID) -> ImportReviewItem {
        guard var entry = entriesByID[itemID] else { return item(id: itemID) }
        let projection = Self.project(entry.result)
        guard let reference = projection.reference else { return Self.makeItem(entry) }

        let evidence = projection.evidence ?? EvidenceBundle(
            source: reference.metadataSource ?? .translationServer,
            recordKey: reference.recordKey,
            sourceURL: reference.verificationSourceURL ?? reference.url,
            fetchMode: .manual,
            fieldEvidence: [
                FieldEvidence(field: "title", value: reference.title, origin: .manual),
            ]
        )
        let manual = MetadataVerifier.manuallyVerified(
            reference,
            evidence: evidence,
            reviewedBy: "batch-identifier-review"
        )
        entry.result = .verified(VerifiedEnvelope(reference: manual, evidence: evidence))
        entriesByID[itemID] = entry
        return Self.makeItem(entry)
    }

    func retry(itemID: UUID) async -> ImportReviewItem {
        guard var entry = entriesByID[itemID] else { return item(id: itemID) }
        entry.result = await resolver.resolveManualEntry(entry.input).result
        entriesByID[itemID] = entry
        return Self.makeItem(entry)
    }

    func discard(remainingIDs: Set<UUID>) {
        for id in remainingIDs {
            entriesByID.removeValue(forKey: id)
        }
    }

    private func item(id: UUID) -> ImportReviewItem {
        guard let entry = entriesByID[id] else {
            preconditionFailure("Metadata import review received an unknown item id")
        }
        return Self.makeItem(entry)
    }

    private static func makeItem(_ entry: PreparedMetadataImport) -> ImportReviewItem {
        let projection = project(entry.result)
        let readiness: ImportReviewItem.Readiness
        switch entry.result {
        case .verified:
            readiness = .ready
        case .candidate:
            if !projection.candidates.isEmpty {
                readiness = .needsCandidate
            } else if projection.reference != nil {
                readiness = .needsProposal
            } else {
                readiness = .blocked
            }
        case .blocked:
            if !projection.candidates.isEmpty {
                readiness = .needsCandidate
            } else if projection.reference != nil {
                readiness = .needsProposal
            } else {
                readiness = .blocked
            }
        case .seedOnly:
            readiness = projection.reference == nil ? .blocked : .needsProposal
        case .rejected:
            readiness = projection.reference == nil ? .failed : .needsProposal
        }

        return ImportReviewItem(
            id: entry.id,
            title: projection.reference?.title.rubien_nilIfBlank ?? entry.input,
            subtitle: entry.input,
            message: projection.message,
            reference: projection.reference,
            candidates: projection.candidates,
            readiness: readiness,
            commitError: nil,
            isWorking: false
        )
    }

    private static func project(
        _ result: MetadataResolutionResult
    ) -> (
        seed: MetadataResolutionSeed?,
        reference: Reference?,
        candidates: [MetadataCandidate],
        message: String?,
        evidence: EvidenceBundle?
    ) {
        switch result {
        case .verified(let envelope):
            return (nil, envelope.reference, [], nil, envelope.evidence)
        case .candidate(let envelope):
            return (
                envelope.seed,
                envelope.currentReference ?? envelope.fallbackReference,
                envelope.candidates,
                envelope.message,
                envelope.evidence
            )
        case .blocked(let envelope):
            return (
                envelope.seed,
                envelope.currentReference ?? envelope.fallbackReference,
                envelope.candidates,
                envelope.message,
                envelope.evidence
            )
        case .seedOnly(let envelope):
            return (
                envelope.seed,
                envelope.currentReference ?? envelope.fallbackReference,
                [],
                envelope.message,
                envelope.evidence
            )
        case .rejected(let envelope):
            return (
                envelope.seed,
                envelope.currentReference ?? envelope.fallbackReference,
                [],
                envelope.message,
                envelope.evidence
            )
        }
    }
}
#endif
