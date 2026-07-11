#if os(macOS)
import SwiftUI
import RubienCore

struct ImportReviewSheet: View {
    @ObservedObject var session: ImportReviewSession
    var onDelete: ((UUID) -> Bool)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var candidateContext: CandidateContext?

    private struct CandidateContext: Identifiable {
        let id: UUID
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List(session.items) { item in
                    reviewRow(item)
                }
                .listStyle(.inset)

                Divider()

                footer
                    .padding(16)
            }
            .navigationTitle(session.title)
        }
        .frame(minWidth: 760, minHeight: 520)
        .interactiveDismissDisabled(session.isBusy)
        .onDisappear { session.discardRemaining() }
        .sheet(item: $candidateContext) { context in
            if let item = session.items.first(where: { $0.id == context.id }) {
                candidatePicker(for: item)
            }
        }
    }

    @ViewBuilder
    private func reviewRow(_ item: ImportReviewItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                session.setSelected(!session.selectedIDs.contains(item.id), itemID: item.id)
            } label: {
                Image(systemName: session.selectedIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(item.isSelectable ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .buttonStyle(ImportReviewCheckboxButtonStyle())
            .disabled(!item.isSelectable || session.isBusy)
            .accessibilityLabel(
                session.selectedIDs.contains(item.id)
                    ? String(localized: "Deselect import item", bundle: .module)
                    : String(localized: "Select import item", bundle: .module)
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)

                if let subtitle = item.subtitle?.rubien_nilIfBlank {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let message = item.message?.rubien_nilIfBlank {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                if let error = item.commitError?.rubien_nilIfBlank {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 12)

            rowAction(item)
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func rowAction(_ item: ImportReviewItem) -> some View {
        HStack(spacing: 8) {
            if item.isWorking {
                ProgressView()
                    .controlSize(.small)
            } else {
                switch item.readiness {
                case .ready:
                    EmptyView()
                case .needsCandidate:
                    Button(String(localized: "Choose match…", bundle: .module)) {
                        candidateContext = CandidateContext(id: item.id)
                    }
                    .buttonStyle(SLSecondaryButtonStyle())
                    .controlSize(.small)
                    .disabled(session.isBusy)
                case .needsProposal:
                    Button(String(localized: "Use proposed metadata", bundle: .module)) {
                        session.useProposedMetadata(itemID: item.id)
                    }
                    .buttonStyle(SLSecondaryButtonStyle())
                    .controlSize(.small)
                    .disabled(session.isBusy)
                case .blocked, .failed:
                    if onDelete == nil {
                        Button(String(localized: "pendingQueue.button.retry", bundle: .module)) {
                            Task { await session.retry(itemID: item.id) }
                        }
                        .buttonStyle(SLSecondaryButtonStyle())
                        .controlSize(.small)
                        .disabled(session.isBusy)
                    }
                }
            }

            if let onDelete {
                Menu {
                    Button(String(localized: "pendingQueue.button.retry", bundle: .module)) {
                        Task { await session.retry(itemID: item.id) }
                    }
                    Divider()
                    Button(
                        String(localized: "pendingQueue.button.delete", bundle: .module),
                        role: .destructive
                    ) {
                        if onDelete(item.id) {
                            session.removeItem(itemID: item.id)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(session.isBusy)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(String(format: String(localized: "%d selected", bundle: .module), session.selectedIDs.count))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            Button(String(localized: "Select all ready", bundle: .module)) {
                session.selectAllReady()
            }
            .buttonStyle(SLSecondaryButtonStyle())
            .disabled(session.isBusy)

            Button(String(localized: "Select none", bundle: .module)) {
                session.selectNone()
            }
            .buttonStyle(SLSecondaryButtonStyle())
            .disabled(session.isBusy)

            Spacer()

            Button(String(localized: "common.close", bundle: .module)) {
                session.discardRemaining()
                dismiss()
            }
            .buttonStyle(SLSecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
            .disabled(session.isBusy)

            Button(
                String(
                    format: String(localized: "Confirm %d selected", bundle: .module),
                    session.selectedIDs.count
                )
            ) {
                Task {
                    await session.confirmSelected()
                    if session.items.isEmpty {
                        dismiss()
                    }
                }
            }
            .buttonStyle(SLPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(session.selectedIDs.isEmpty || session.isBusy)
        }
    }

    private func candidatePicker(for item: ImportReviewItem) -> some View {
        MetadataCandidatePickerView(
            title: String(localized: "candidatePicker.title", bundle: .module),
            message: String(localized: "Choose the metadata match for this import. Nothing is saved until you confirm the selected batch.", bundle: .module),
            skipLabel: String(localized: "common.cancel", bundle: .module),
            confirmLabel: String(localized: "Use selected match", bundle: .module),
            candidates: item.candidates,
            onImportSelected: { candidate in
                candidateContext = nil
                Task { await session.resolveCandidate(itemID: item.id, candidate: candidate) }
            },
            onSkip: { candidateContext = nil },
            onCancel: { candidateContext = nil }
        )
    }
}
#endif
