#if os(macOS)
import SwiftUI
import RubienCore

struct PendingMetadataQueueView: View {
    let intakes: [MetadataIntake]
    let resolver: MetadataResolver
    let onPersistResult: (MetadataResolutionResult, MetadataIntake) -> Void
    let onConfirmManual: (MetadataIntake) -> Void
    let onDelete: (MetadataIntake) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidateContext: CandidateContext?
    @State private var workingIntakeID: Int64?

    private struct CandidateContext: Identifiable {
        let id: Int64
    }

    var body: some View {
        NavigationStack {
            List(intakes) { intake in
                VStack(alignment: .leading, spacing: 6) {
                    Text(intake.title)
                        .font(.headline)
                        .lineLimit(2)

                    if let message = intake.statusMessage?.rubien_nilIfBlank {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let reference = intake.bestAvailableReference {
                        Text(
                            [
                                reference.authors.displayString,
                                reference.year.map(String.init),
                                reference.journal ?? reference.publisher
                            ]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    }

                    HStack(spacing: 10) {
                        if workingIntakeID == intake.id {
                            ProgressView()
                                .controlSize(.small)
                            Text("Processing…", bundle: .module)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !intake.decodedCandidates.isEmpty {
                            Button(String(localized: "Confirm & import", bundle: .module)) {
                                if let id = intake.id {
                                    candidateContext = CandidateContext(id: id)
                                }
                            }
                            .buttonStyle(SLPrimaryButtonStyle())
                            .controlSize(.small)
                        } else if intake.bestAvailableReference != nil {
                            Button(String(localized: "Confirm & import", bundle: .module)) {
                                onConfirmManual(intake)
                            }
                            .buttonStyle(SLPrimaryButtonStyle())
                            .controlSize(.small)
                        }

                        Spacer()

                        Menu {
                            Button(String(localized: "pendingQueue.button.retry", bundle: .module)) {
                                retry(intake)
                            }
                            Divider()
                            Button(String(localized: "pendingQueue.button.delete", bundle: .module), role: .destructive) {
                                onDelete(intake)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle(String(localized: "pendingQueue.title", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close", bundle: .module)) { dismiss() }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(item: $candidateContext) { context in
            if let intake = intakes.first(where: { $0.id == context.id }) {
                let fallbackReference = intake.decodedFallbackReference ?? intake.decodedCurrentReference
                let assessmentByCandidateID = intake.decodedCandidates.reduce(into: [MetadataCandidate.ID: ManualCandidateImportAssessment]()) {
                    partialResult,
                    candidate in
                    partialResult[candidate.id] = MetadataResolver.assessManuallyConfirmedCandidate(
                        candidate,
                        fallback: fallbackReference
                    )
                }
                MetadataCandidatePickerView(
                    title: String(localized: "Confirm candidate", bundle: .module),
                    message: String(localized: "If the selected candidate already has enough information, it will be imported as manually-verified. Otherwise Rubien will fetch the detail page to fill in the gaps.", bundle: .module),
                    skipLabel: String(localized: "common.cancel", bundle: .module),
                    candidates: intake.decodedCandidates,
                    assessmentByCandidateID: assessmentByCandidateID,
                    onImportSelected: { candidate in
                        candidateContext = nil
                        resolveCandidate(candidate, intake: intake)
                    },
                    onSkip: {
                        candidateContext = nil
                    },
                    onCancel: {
                        candidateContext = nil
                    }
                )
            }
        }
    }

    private func retry(_ intake: MetadataIntake) {
        workingIntakeID = intake.id
        Task { @MainActor in
            let result = await resolver.retryIntake(intake)
            onPersistResult(result, intake)
            workingIntakeID = nil
        }
    }

    private func resolveCandidate(_ candidate: MetadataCandidate, intake: MetadataIntake) {
        workingIntakeID = intake.id
        Task { @MainActor in
            let result = await resolver.resolveCandidate(
                candidate,
                fallback: intake.decodedFallbackReference ?? intake.decodedCurrentReference,
                seed: intake.decodedSeed,
                treatingManualSelectionAsConfirmation: true,
                reviewedBy: "candidate-selection"
            )
            onPersistResult(result, intake)
            workingIntakeID = nil
        }
    }
}
#endif
