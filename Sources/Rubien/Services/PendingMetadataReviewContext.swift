#if os(macOS)
import Foundation
import RubienCore

@MainActor
final class PendingMetadataReviewContext: ImportReviewContext {
    typealias CandidateResolver = (
        MetadataCandidate,
        Reference?,
        MetadataResolutionSeed?
    ) async -> MetadataResolutionResult
    typealias RetryResolver = (MetadataIntake) async -> MetadataResolutionResult
    typealias Committer = (
        MetadataIntake,
        Reference?,
        EvidenceBundle?,
        String?,
        AppDatabase
    ) throws -> Reference

    let items: [ImportReviewItem]

    private struct Entry {
        var intake: MetadataIntake
        var stagedResult: MetadataResolutionResult?
        var stagedReference: Reference?
        var stagedEvidence: EvidenceBundle?
    }

    private let database: AppDatabase
    private let orderedIDs: [UUID]
    private let candidateResolver: CandidateResolver
    private let retryResolver: RetryResolver
    private let committer: Committer
    private let onConfirmed: ((Reference) -> Void)?
    private var entriesByID: [UUID: Entry]

    init(
        database: AppDatabase,
        resolver: MetadataResolver? = nil,
        intakes: [MetadataIntake],
        candidateResolver: CandidateResolver? = nil,
        retryResolver: RetryResolver? = nil,
        onConfirmed: ((Reference) -> Void)? = nil,
        committer: @escaping Committer = { intake, reference, evidence, reviewedBy, database in
            try database.confirmMetadataIntake(
                intake,
                stagedReference: reference,
                evidence: evidence,
                reviewedBy: reviewedBy
            )
        }
    ) {
        let resolver = resolver ?? MetadataResolver()
        let pairs = intakes.map { (UUID(), Entry(intake: $0)) }
        self.database = database
        self.orderedIDs = pairs.map(\.0)
        self.entriesByID = Dictionary(uniqueKeysWithValues: pairs)
        self.candidateResolver = candidateResolver ?? { candidate, fallback, seed in
            await resolver.resolveCandidate(
                candidate,
                fallback: fallback,
                seed: seed,
                treatingManualSelectionAsConfirmation: true,
                reviewedBy: "candidate-selection"
            )
        }
        self.retryResolver = retryResolver ?? { intake in
            await resolver.retryIntake(intake)
        }
        self.committer = committer
        self.onConfirmed = onConfirmed
        self.items = pairs.map { id, entry in
            Self.makeItem(id: id, entry: entry)
        }
    }

    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport {
        var succeeded: Set<UUID> = []
        var failures: [UUID: String] = [:]

        for id in orderedIDs where selectedIDs.contains(id) {
            guard let entry = entriesByID[id] else { continue }
            do {
                let reference = try committer(
                    entry.intake,
                    entry.stagedReference,
                    entry.stagedEvidence,
                    entry.stagedReference == nil ? "manual-queue" : "candidate-selection",
                    database
                )
                onConfirmed?(reference)
                succeeded.insert(id)
                entriesByID.removeValue(forKey: id)
            } catch {
                failures[id] = error.localizedDescription
            }
        }

        return ImportReviewCommitReport(succeededIDs: succeeded, failures: failures)
    }

    func resolveCandidate(
        itemID: UUID,
        candidate: MetadataCandidate
    ) async -> ImportReviewItem {
        guard var entry = entriesByID[itemID] else { return item(id: itemID) }
        let result = await candidateResolver(
            candidate,
            entry.intake.decodedFallbackReference ?? entry.intake.decodedCurrentReference,
            entry.intake.decodedSeed
        )
        stage(result, in: &entry)
        entriesByID[itemID] = entry
        return Self.makeItem(id: itemID, entry: entry)
    }

    func useProposedMetadata(itemID: UUID) -> ImportReviewItem {
        guard var entry = entriesByID[itemID],
              let reference = Self.project(entry).reference else {
            return item(id: itemID)
        }
        let evidence = Self.project(entry).evidence
        entry.stagedReference = MetadataVerifier.manuallyVerified(
            reference,
            evidence: evidence,
            reviewedBy: "manual-queue"
        )
        entry.stagedEvidence = evidence
        entry.stagedResult = nil
        entriesByID[itemID] = entry
        return Self.makeItem(id: itemID, entry: entry)
    }

    func retry(itemID: UUID) async -> ImportReviewItem {
        guard var entry = entriesByID[itemID] else { return item(id: itemID) }
        let result = await retryResolver(entry.intake)

        if case .verified = result {
            stage(result, in: &entry)
        } else {
            do {
                let persisted = try database.persistMetadataResolution(
                    result,
                    options: MetadataPersistenceOptions(
                        sourceKind: entry.intake.sourceKind,
                        originalInput: entry.intake.originalInput,
                        preferredPDFPath: entry.intake.pdfPath,
                        linkedReferenceId: entry.intake.linkedReferenceId,
                        existingIntakeId: entry.intake.id
                    )
                )
                if case .intake(let refreshed) = persisted {
                    entry.intake = refreshed
                }
                entry.stagedResult = nil
                entry.stagedReference = nil
                entry.stagedEvidence = nil
            } catch {
                var failed = Self.makeItem(id: itemID, entry: entry)
                failed.commitError = error.localizedDescription
                return failed
            }
        }

        entriesByID[itemID] = entry
        return Self.makeItem(id: itemID, entry: entry)
    }

    /// These rows predate the sheet and are durable. Closing review must not
    /// interpret deselection as deletion.
    func discard(remainingIDs _: Set<UUID>) {}

    func intake(for itemID: UUID) -> MetadataIntake? {
        entriesByID[itemID]?.intake
    }

    private func stage(_ result: MetadataResolutionResult, in entry: inout Entry) {
        entry.stagedResult = result
        switch result {
        case .verified(let envelope):
            entry.stagedReference = envelope.reference
            entry.stagedEvidence = envelope.evidence
        case .candidate, .blocked, .seedOnly, .rejected:
            entry.stagedReference = nil
            entry.stagedEvidence = nil
        }
    }

    private func item(id: UUID) -> ImportReviewItem {
        guard let entry = entriesByID[id] else {
            preconditionFailure("Pending metadata review received an unknown item id")
        }
        return Self.makeItem(id: id, entry: entry)
    }

    private static func makeItem(id: UUID, entry: Entry) -> ImportReviewItem {
        let projection = project(entry)
        let readiness: ImportReviewItem.Readiness
        if entry.stagedReference != nil {
            readiness = .ready
        } else if let result = entry.stagedResult {
            switch result {
            case .verified:
                readiness = .ready
            case .candidate(let envelope):
                readiness = envelope.candidates.isEmpty
                    ? (projection.reference == nil ? .blocked : .needsProposal)
                    : .needsCandidate
            case .blocked(let envelope):
                readiness = envelope.candidates.isEmpty
                    ? (projection.reference == nil ? .blocked : .needsProposal)
                    : .needsCandidate
            case .seedOnly:
                readiness = projection.reference == nil ? .blocked : .needsProposal
            case .rejected:
                readiness = projection.reference == nil ? .failed : .needsProposal
            }
        } else if !entry.intake.decodedCandidates.isEmpty {
            readiness = .needsCandidate
        } else if projection.reference != nil {
            readiness = .ready
        } else {
            readiness = entry.intake.verificationStatus == .rejectedAmbiguous ? .failed : .blocked
        }

        return ImportReviewItem(
            id: id,
            title: projection.reference?.title.rubien_nilIfBlank ?? entry.intake.title,
            subtitle: [
                projection.reference?.authors.displayString,
                projection.reference?.year.map(String.init),
                projection.reference?.journal ?? projection.reference?.publisher,
            ]
            .compactMap { $0?.rubien_nilIfBlank }
            .joined(separator: " · ")
            .rubien_nilIfBlank,
            message: projection.message ?? entry.intake.statusMessage,
            reference: projection.reference,
            candidates: projection.candidates,
            readiness: readiness,
            commitError: nil,
            isWorking: false
        )
    }

    private static func project(
        _ entry: Entry
    ) -> (
        reference: Reference?,
        candidates: [MetadataCandidate],
        message: String?,
        evidence: EvidenceBundle?
    ) {
        if let reference = entry.stagedReference {
            return (reference, [], nil, entry.stagedEvidence)
        }
        guard let result = entry.stagedResult else {
            return (
                entry.intake.bestAvailableReference,
                entry.intake.decodedCandidates,
                entry.intake.statusMessage,
                nil
            )
        }
        switch result {
        case .verified(let envelope):
            return (envelope.reference, [], nil, envelope.evidence)
        case .candidate(let envelope):
            return (
                envelope.currentReference ?? envelope.fallbackReference,
                envelope.candidates,
                envelope.message,
                envelope.evidence
            )
        case .blocked(let envelope):
            return (
                envelope.currentReference ?? envelope.fallbackReference,
                envelope.candidates,
                envelope.message,
                envelope.evidence
            )
        case .seedOnly(let envelope):
            return (
                envelope.currentReference ?? envelope.fallbackReference,
                [],
                envelope.message,
                envelope.evidence
            )
        case .rejected(let envelope):
            return (
                envelope.currentReference ?? envelope.fallbackReference,
                [],
                envelope.message,
                envelope.evidence
            )
        }
    }
}
#endif
