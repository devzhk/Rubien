import SwiftUI
import RubienCore

struct AddByIdentifierView: View {
    let resolver: MetadataResolver
    let onSave: (Reference) -> Void
    let onQueueResult: (MetadataResolutionResult, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""
    @State private var isFetching = false
    @State private var fetchedReference: Reference?
    @State private var pendingResolution: MetadataResolutionResult?
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("addByIdentifier.title", bundle: .module)
                .font(.headline)

            HStack {
                TextField(
                    String(localized: "addByIdentifier.field.placeholder", bundle: .module),
                    text: $inputText
                )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { fetchMetadata() }

                Button(action: fetchMetadata) {
                    if isFetching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetching)
            }

            Text("Supports DOI · arXiv · PMID · ISBN · paper title")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if isFetching, let statusMessage {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let ref = fetchedReference {
                resolutionCard(
                    title: String(localized: "Verified:", bundle: .module),
                    titleText: ref.title,
                    bodyText: verifiedSummary(for: ref)
                )
            } else if let pendingResolution {
                resolutionCard(
                    title: String(localized: "Needs review:", bundle: .module),
                    titleText: pendingResolutionTitle(pendingResolution),
                    bodyText: pendingResolutionMessage(pendingResolution)
                )
            }

            Spacer()

            HStack {
                Button(String(localized: "common.cancel", bundle: .module)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SLSecondaryButtonStyle())
                Spacer()
                if let pendingResolution {
                    Button(String(localized: "Queue for review", bundle: .module)) {
                        onQueueResult(pendingResolution, inputText.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(isFetching)
                    .buttonStyle(SLSecondaryButtonStyle())
                }
                Button(String(localized: "Import to library", bundle: .module)) {
                    if let ref = fetchedReference {
                        onSave(ref)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fetchedReference == nil)
                .buttonStyle(SLPrimaryButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 440)
        .frame(minHeight: 280)
    }

    @ViewBuilder
    private func resolutionCard(title: String, titleText: String, bodyText: String) -> some View {
        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(titleText)
                .font(.body.bold())

            Text(bodyText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fetchMetadata() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isFetching = true
        errorMessage = nil
        fetchedReference = nil
        pendingResolution = nil
        statusMessage = statusMessage(for: text)

        Task { @MainActor in
            let result = await resolver.resolveManualEntry(text)
            switch result {
            case .verified(let envelope):
                fetchedReference = envelope.reference
            case .candidate, .blocked, .seedOnly, .rejected:
                pendingResolution = result
            }
            isFetching = false
            statusMessage = nil
        }
    }

    private func statusMessage(for text: String) -> String {
        if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            _ = url
            return String(localized: "addByIdentifier.status.validating", bundle: .module)
        }
        if MetadataFetcher.extractIdentifier(from: text) != nil {
            return String(localized: "addByIdentifier.status.resolvingIdentifier", bundle: .module)
        }
        return String(localized: "addByIdentifier.status.queryingMetadata", bundle: .module)
    }

    private func verifiedSummary(for reference: Reference) -> String {
        let publicationLine = [reference.journal, reference.publisher, reference.year.map(String.init)]
            .compactMap { $0 }
            .joined(separator: " · ")
        let identifierLine = [
            reference.doi.map { "DOI: \($0)" },
            reference.isbn.map { "ISBN: \($0)" },
            reference.issn.map { "ISSN: \($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        let abstract = reference.abstract?.rubien_nilIfBlank ?? ""
        return [reference.authors.displayString, publicationLine, identifierLine, abstract]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func pendingResolutionTitle(_ result: MetadataResolutionResult) -> String {
        let placeholder = String(localized: "Unresolved entry", bundle: .module)
        switch result {
        case .candidate(let envelope):
            return envelope.currentReference?.title
                ?? envelope.fallbackReference?.title
                ?? envelope.seed?.title
                ?? placeholder
        case .blocked(let envelope):
            return envelope.currentReference?.title
                ?? envelope.fallbackReference?.title
                ?? envelope.seed?.title
                ?? placeholder
        case .seedOnly(let envelope):
            return envelope.currentReference?.title
                ?? envelope.fallbackReference?.title
                ?? envelope.seed?.title
                ?? placeholder
        case .rejected(let envelope):
            return envelope.currentReference?.title
                ?? envelope.fallbackReference?.title
                ?? envelope.seed?.title
                ?? placeholder
        case .verified(let envelope):
            return envelope.reference.title
        }
    }

    private func pendingResolutionMessage(_ result: MetadataResolutionResult) -> String {
        switch result {
        case .candidate(let envelope):
            return envelope.message
        case .blocked(let envelope):
            return envelope.message
        case .seedOnly(let envelope):
            return envelope.message
        case .rejected(let envelope):
            return envelope.message
        case .verified:
            return ""
        }
    }
}
