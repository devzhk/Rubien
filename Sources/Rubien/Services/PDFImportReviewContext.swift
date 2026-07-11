#if os(macOS)
import Foundation
import RubienCore
import RubienPDFKit

@MainActor
final class PDFImportReviewContext: ImportReviewContext {
    typealias Entry = (prepared: PreparedPDFImport, source: MaterializedImportSource)
    typealias Committer = @Sendable (PreparedPDFImport, AppDatabase) throws -> PDFImportOutcome

    let items: [ImportReviewItem]

    private struct Payload {
        var prepared: PreparedPDFImport
        let source: MaterializedImportSource
    }

    private let database: AppDatabase
    private let resolver: MetadataResolver
    private let onImported: (Reference) -> Void
    private let committer: Committer
    private var payloads: [UUID: Payload]

    init(
        database: AppDatabase,
        entries: [Entry],
        resolver: MetadataResolver? = nil,
        onImported: @escaping (Reference) -> Void = { _ in },
        committer: @escaping Committer = { prepared, database in
            try PDFImportCoordinator.commitPreparedPDF(prepared, database: database)
        }
    ) {
        self.database = database
        self.resolver = resolver ?? MetadataResolver()
        self.onImported = onImported
        self.committer = committer

        var payloads: [UUID: Payload] = [:]
        var items: [ImportReviewItem] = []
        for entry in entries {
            let id = UUID()
            payloads[id] = Payload(prepared: entry.prepared, source: entry.source)
            items.append(Self.makeItem(id: id, payload: payloads[id]!))
        }
        self.payloads = payloads
        self.items = items
    }

    func commit(selectedIDs: Set<UUID>) async -> ImportReviewCommitReport {
        var succeeded: Set<UUID> = []
        var failures: [UUID: String] = [:]

        for item in items where selectedIDs.contains(item.id) {
            guard let payload = payloads[item.id] else { continue }
            guard case .verified = payload.prepared.resolution else {
                failures[item.id] = "Choose or confirm metadata before importing this PDF."
                continue
            }

            let database = database
            let committer = committer
            let commitResult = await Task.detached(priority: .userInitiated) {
                do {
                    return DetachedPDFCommitResult.success(
                        try committer(payload.prepared, database)
                    )
                } catch {
                    return DetachedPDFCommitResult.failure(error.localizedDescription)
                }
            }.value

            switch commitResult {
            case .success(let outcome):
                switch outcome {
                case .imported(let reference):
                    succeeded.insert(item.id)
                    payload.source.cleanup()
                    payloads.removeValue(forKey: item.id)
                    onImported(reference)
                case .queued:
                    failures[item.id] = "Metadata must be confirmed before importing this PDF."
                }
            case .failure(let message):
                failures[item.id] = message
            }
        }

        return ImportReviewCommitReport(succeededIDs: succeeded, failures: failures)
    }

    func resolveCandidate(
        itemID: UUID,
        candidate: MetadataCandidate
    ) async -> ImportReviewItem {
        guard var payload = payloads[itemID] else { return item(id: itemID) }
        let context = Self.resolutionContext(payload.prepared.resolution)
        payload.prepared.resolution = await resolver.resolveCandidate(
            candidate,
            fallback: context.reference,
            seed: context.seed,
            treatingManualSelectionAsConfirmation: true,
            reviewedBy: "pdf-import-review"
        )
        payloads[itemID] = payload
        return Self.makeItem(id: itemID, payload: payload)
    }

    func useProposedMetadata(itemID: UUID) -> ImportReviewItem {
        guard var payload = payloads[itemID] else { return item(id: itemID) }
        let context = Self.resolutionContext(payload.prepared.resolution)
        guard let reference = context.reference else { return item(id: itemID) }

        let evidence = context.evidence ?? EvidenceBundle(
            source: .translationServer,
            recordKey: reference.recordKey,
            sourceURL: reference.url,
            fetchMode: .manual,
            fieldEvidence: [
                FieldEvidence(field: "title", value: reference.title, origin: .manual),
            ]
        )
        let manual = MetadataVerifier.manuallyVerified(
            reference,
            evidence: evidence,
            reviewedBy: "pdf-import-review"
        )
        payload.prepared.resolution = .verified(
            VerifiedEnvelope(reference: manual, evidence: evidence)
        )
        payloads[itemID] = payload
        return Self.makeItem(id: itemID, payload: payload)
    }

    func retry(itemID: UUID) async -> ImportReviewItem {
        guard var payload = payloads[itemID] else { return item(id: itemID) }
        payload.prepared = await PDFImportCoordinator.preparePDF(
            from: payload.source.fileURL,
            resolver: { [resolver] url, extracted in
                await resolver.resolveImportedPDF(url: url, extracted: extracted)
            }
        )
        payloads[itemID] = payload
        return Self.makeItem(id: itemID, payload: payload)
    }

    func discard(remainingIDs: Set<UUID>) {
        for id in remainingIDs {
            payloads.removeValue(forKey: id)?.source.cleanup()
        }
    }

    private func item(id: UUID) -> ImportReviewItem {
        items.first(where: { $0.id == id })!
    }

    private static func makeItem(id: UUID, payload: Payload) -> ImportReviewItem {
        let sourceLabel = payload.source.fileURL.lastPathComponent
        switch payload.prepared.resolution {
        case .verified(let envelope):
            return ImportReviewItem(
                id: id,
                title: envelope.reference.title,
                subtitle: sourceLabel,
                message: nil,
                reference: envelope.reference,
                candidates: [],
                readiness: .ready,
                commitError: nil,
                isWorking: false
            )
        case .candidate(let envelope):
            return ImportReviewItem(
                id: id,
                title: displayTitle(envelope.currentReference ?? envelope.fallbackReference, sourceLabel: sourceLabel),
                subtitle: sourceLabel,
                message: envelope.message,
                reference: envelope.currentReference ?? envelope.fallbackReference,
                candidates: envelope.candidates,
                readiness: .needsCandidate,
                commitError: nil,
                isWorking: false
            )
        case .seedOnly(let envelope):
            let reference = envelope.currentReference ?? envelope.fallbackReference
            return ImportReviewItem(
                id: id,
                title: displayTitle(reference, sourceLabel: sourceLabel),
                subtitle: sourceLabel,
                message: envelope.message,
                reference: reference,
                candidates: [],
                readiness: reference == nil ? .blocked : .needsProposal,
                commitError: nil,
                isWorking: false
            )
        case .blocked(let envelope):
            let reference = envelope.currentReference ?? envelope.fallbackReference
            let readiness: ImportReviewItem.Readiness
            if !envelope.candidates.isEmpty {
                readiness = .needsCandidate
            } else if reference?.title.rubien_nilIfBlank != nil {
                readiness = .needsProposal
            } else {
                readiness = .blocked
            }
            return ImportReviewItem(
                id: id,
                title: displayTitle(reference, sourceLabel: sourceLabel),
                subtitle: sourceLabel,
                message: envelope.message,
                reference: reference,
                candidates: envelope.candidates,
                readiness: readiness,
                commitError: nil,
                isWorking: false
            )
        case .rejected(let envelope):
            let reference = envelope.currentReference ?? envelope.fallbackReference
            return ImportReviewItem(
                id: id,
                title: displayTitle(reference, sourceLabel: sourceLabel),
                subtitle: sourceLabel,
                message: envelope.message,
                reference: reference,
                candidates: [],
                readiness: reference?.title.rubien_nilIfBlank == nil ? .failed : .needsProposal,
                commitError: nil,
                isWorking: false
            )
        }
    }

    private static func displayTitle(_ reference: Reference?, sourceLabel: String) -> String {
        reference?.title.rubien_nilIfBlank ?? sourceLabel
    }

    private static func resolutionContext(
        _ result: MetadataResolutionResult
    ) -> (seed: MetadataResolutionSeed?, reference: Reference?, evidence: EvidenceBundle?) {
        switch result {
        case .verified(let envelope):
            return (nil, envelope.reference, envelope.evidence)
        case .candidate(let envelope):
            return (envelope.seed, envelope.currentReference ?? envelope.fallbackReference, envelope.evidence)
        case .blocked(let envelope):
            return (envelope.seed, envelope.currentReference ?? envelope.fallbackReference, envelope.evidence)
        case .seedOnly(let envelope):
            return (envelope.seed, envelope.currentReference ?? envelope.fallbackReference, envelope.evidence)
        case .rejected(let envelope):
            return (envelope.seed, envelope.currentReference ?? envelope.fallbackReference, envelope.evidence)
        }
    }
}

private enum DetachedPDFCommitResult: Sendable {
    case success(PDFImportOutcome)
    case failure(String)
}
#endif
