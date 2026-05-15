import SwiftUI
import RubienCore

struct AddByIdentifierView: View {
    let resolver: MetadataResolver
    let onSave: (Reference, _ downloadPDF: Bool) -> Void
    let onQueueResult: (MetadataResolutionResult, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""
    @State private var isFetching = false
    @State private var fetchedReference: Reference?
    @State private var pendingResolution: MetadataResolutionResult?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var downloadPDFOnImport: Bool = true

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

            Text("Supports DOI · arXiv · PMID · PMCID · ISBN · paper title")
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
                verifiedCard(
                    title: String(localized: "Verified:", bundle: .module),
                    reference: ref
                )

                Toggle(
                    String(localized: "addByIdentifier.downloadPDFOnImport", bundle: .module),
                    isOn: $downloadPDFOnImport
                )
                .toggleStyle(.checkbox)
                .disabled(!ref.canDownloadPDF)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let pendingResolution {
                pendingCard(
                    title: pendingResolutionCardTitle(pendingResolution),
                    paperTitle: pendingResolutionTitle(pendingResolution),
                    message: pendingResolutionMessage(pendingResolution)
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
                        let shouldDownload = downloadPDFOnImport && ref.canDownloadPDF
                        onSave(ref, shouldDownload)
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
        .liquidGlassPresentation()
    }

    @ViewBuilder
    private func verifiedCard(title: String, reference: Reference) -> some View {
        resolutionCard {
            Text(title)

            Text(reference.title)
                .font(.body.bold())
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.tail)

            if !reference.authors.displayString.isEmpty {
                Text(reference.authors.displayString)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            if let pub = publicationLine(for: reference) {
                Text(pub)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let ids = identifierLine(for: reference) {
                Text(ids)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let abstract = reference.abstract?.rubien_nilIfBlank {
                Text(abstract)
                    .lineLimit(4)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private func pendingCard(title: String, paperTitle: String, message: String) -> some View {
        resolutionCard {
            Text(title)

            Text(paperTitle)
                .font(.body.bold())
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.tail)

            if !message.isEmpty {
                Text(message)
                    .lineLimit(8)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private func resolutionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Divider()

        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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

    private func publicationLine(for reference: Reference) -> String? {
        let parts = [reference.journal, reference.publisher]
            .compactMap { $0?.rubien_nilIfBlank }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func identifierLine(for reference: Reference) -> String? {
        let parts = [
            reference.doi.map { "DOI: \($0)" },
            reference.isbn.map { "ISBN: \($0)" },
            reference.issn.map { "ISSN: \($0)" },
        ].compactMap { $0?.rubien_nilIfBlank }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            if isLookupFailure(envelope) {
                return String(localized: "addByIdentifier.lookupFailed.placeholder", bundle: .module)
            }
            return envelope.currentReference?.title
                ?? envelope.fallbackReference?.title
                ?? envelope.seed?.title
                ?? placeholder
        case .verified(let envelope):
            return envelope.reference.title
        }
    }

    private func pendingResolutionCardTitle(_ result: MetadataResolutionResult) -> String {
        if case .rejected(let envelope) = result, isLookupFailure(envelope) {
            return String(localized: "addByIdentifier.lookupFailed.cardTitle", bundle: .module)
        }
        return String(localized: "Needs review:", bundle: .module)
    }

    /// Network failures are the only producer of fully-empty rejected envelopes:
    /// real verification rejections always carry a `currentReference` (the unverified
    /// record) or a `seed` (from title search).
    private func isLookupFailure(_ envelope: RejectedEnvelope) -> Bool {
        envelope.currentReference == nil
            && envelope.fallbackReference == nil
            && envelope.seed == nil
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
