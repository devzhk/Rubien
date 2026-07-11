#if os(macOS)
import SwiftUI
import RubienCore

struct MetadataCandidatePickerView: View {
    var title: String = String(localized: "candidatePicker.title", bundle: .module)
    var message: String = String(localized: "candidatePicker.subtitle", bundle: .module)
    var skipLabel: String = String(localized: "candidatePicker.button.skip", bundle: .module)
    var confirmLabel: String = String(localized: "Import selected", bundle: .module)
    let candidates: [MetadataCandidate]
    var assessmentByCandidateID: [MetadataCandidate.ID: ManualCandidateImportAssessment] = [:]
    let onImportSelected: (MetadataCandidate) -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void

    @State private var selectedCandidateID: MetadataCandidate.ID?

    private var selectedCandidate: MetadataCandidate? {
        candidates.first { $0.id == selectedCandidateID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)

            List(candidates, selection: $selectedCandidateID) { candidate in
                VStack(alignment: .leading, spacing: 6) {
                    let assessment = assessmentByCandidateID[candidate.id]
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(candidate.title)
                            .font(.headline)
                        Spacer(minLength: 0)
                        if candidate.id == candidates.first?.id {
                            Text("Best match", bundle: .module)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.12), in: Capsule())
                        }
                        if candidate.score > 0 {
                            Text("\(Int(candidate.score * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(candidate.source.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !candidate.authors.isEmpty {
                        Text(candidate.authors.displayString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    let detailLine = [candidate.journal, candidate.year.map(String.init)]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    let publisherLine = [candidate.publisher, candidate.isbn, candidate.issn]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    if !detailLine.isEmpty {
                        Text(detailLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    let type = candidate.referenceType?.rawValue
                        ?? (candidate.workKind == .unknown ? "" : candidate.workKind.referenceType.rawValue)
                    if !type.isEmpty {
                        Text(type)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !publisherLine.isEmpty {
                        Text(publisherLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let snippet = candidate.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let assessment {
                        VStack(alignment: .leading, spacing: 3) {
                            let readyText = String(localized: "Complete — ready to import", bundle: .module)
                            let missingFmt = String(localized: "Missing: %@", bundle: .module)
                            Text(
                                assessment.canImportDirectly
                                    ? readyText
                                    : String(format: missingFmt, assessment.missingFields.joined(separator: " / "))
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(assessment.canImportDirectly ? .green : .orange)

                            if !assessment.presentFields.isEmpty {
                                let haveFmt = String(localized: "Have: %@", bundle: .module)
                                Text(String(format: haveFmt, assessment.presentFields.joined(separator: " / ")))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        if !candidate.matchedBy.isEmpty {
                            let matchFmt = String(localized: "Matched: %@", bundle: .module)
                            Text(String(format: matchFmt, candidate.matchedBy.joined(separator: " / ")))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button(String(localized: "Use this one", bundle: .module)) {
                            onImportSelected(candidate)
                        }
                        .buttonStyle(SLPrimaryButtonStyle())
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
                .tag(candidate.id)
            }
            .frame(minWidth: 640, minHeight: 320)

            HStack {
                Button(String(localized: "common.cancel", bundle: .module), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(skipLabel, action: onSkip)

                Button(confirmLabel) {
                    guard let selectedCandidate else { return }
                    onImportSelected(selectedCandidate)
                }
                .buttonStyle(SLPrimaryButtonStyle())
                .disabled(selectedCandidate == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            selectedCandidateID = candidates.first?.id
        }
    }
}
#endif
