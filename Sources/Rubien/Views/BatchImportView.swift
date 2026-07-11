#if os(macOS)
import AppKit
import SwiftUI
import RubienCore

enum BatchImportPresentation {
    enum CompletionRoute: Equatable {
        case awaitVerifiedSingleConfirmation
        case persistQueuedSingleInPlace
        case deliverImmediately
    }

    static func shouldReview(requestedInputCount: Int) -> Bool {
        requestedInputCount > 1
    }

    static func completionRoute(
        requestedInputCount: Int,
        results: [MetadataResolutionResult]
    ) -> CompletionRoute {
        guard requestedInputCount == 1, results.count == 1 else {
            return .deliverImmediately
        }
        if case .verified = results[0] {
            return .awaitVerifiedSingleConfirmation
        }
        return .persistQueuedSingleInPlace
    }
}

@MainActor
final class BatchImportDeliveryGate {
    private var generation = 0

    func begin() -> Int {
        generation += 1
        return generation
    }

    func cancel() {
        generation += 1
    }

    func shouldDeliver(_ token: Int) -> Bool {
        token == generation
    }
}

struct BatchImportView: View {
    let resolver: MetadataResolver
    let onPrepared: ([PreparedMetadataImport]) -> Void
    let onQueueResult: (MetadataResolutionResult, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""
    @State private var isProcessing = false
    @State private var results: [ImportResult] = []
    @State private var progress = 0
    @State private var total = 0
    @State private var statusMessage: String?
    @State private var preparedForConfirmation: [PreparedMetadataImport] = []
    @State private var pendingDeliveryToken: Int?
    @State private var resolutionTask: Task<Void, Never>?
    @State private var deliveryGate = BatchImportDeliveryGate()

    struct ImportResult: Identifiable {
        enum Outcome {
            case imported(Reference)
            case queued(String)
            case failed(String)
        }

        let id = UUID()
        let identifier: String
        let outcome: Outcome

        var isSuccess: Bool {
            if case .imported = outcome { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(String(localized: "common.cancel", bundle: .module)) {
                    cancelResolutionAndDismiss()
                }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("batchImport.title", bundle: .module)
                    .font(.headline)
                Spacer()
                if preparedForConfirmation.isEmpty {
                    Button(String(localized: "batchImport.button.start", bundle: .module)) { startBatchFetch() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(identifiers.isEmpty || isProcessing || !results.isEmpty)
                } else {
                    Button(
                        String(
                            format: String(localized: "Import %d to library", bundle: .module),
                            preparedForConfirmation.count
                        )
                    ) {
                        deliverVerifiedSingle()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()

            Divider()

            if results.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("batchImport.field.placeholder", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $inputText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                        .border(Color.secondary.opacity(0.3))

                    HStack {
                        Text(String(format: String(localized: "%d identifiers recognized", bundle: .module), identifiers.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Paste from clipboard", bundle: .module)) {
                            if let text = NSPasteboard.general.string(forType: .string) {
                                inputText = text
                            }
                        }
                        .font(.caption)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Example (one per line):")
                                .font(.caption.bold())
                            Text("""
                            10.1038/nature12373
                            9780262035613
                            arXiv:1706.03762
                            PMID: 25719670
                            PMC4587766
                            Attention Is All You Need
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            } else {
                VStack(spacing: 8) {
                    if isProcessing {
                        HStack {
                            ProgressView(value: Double(progress), total: Double(total))
                            Text("\(progress)/\(total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)

                        if let statusMessage {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                    }

                    let succeeded = results.filter(\.isSuccess).count
                    let queued = results.filter {
                        if case .queued = $0.outcome { return true }
                        return false
                    }.count
                    let failed = results.filter {
                        if case .failed = $0.outcome { return true }
                        return false
                    }.count
                    HStack {
                        Label(String(format: String(localized: "%d verified", bundle: .module), succeeded), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if queued > 0 {
                            Label(String(format: String(localized: "%d queued", bundle: .module), queued), systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                        if failed > 0 {
                            Label(String(format: String(localized: "%d failed", bundle: .module), failed), systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal)

                    List(results) { result in
                        HStack(spacing: 8) {
                            Image(systemName: iconName(for: result.outcome))
                                .foregroundStyle(iconColor(for: result.outcome))
                                .font(.caption)

                            VStack(alignment: .leading, spacing: 2) {
                                switch result.outcome {
                                case .imported(let ref):
                                    Text(ref.title)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text(
                                        [
                                            ref.authors.displayString,
                                            ref.year.map(String.init),
                                            ref.publisher ?? ref.journal
                                        ]
                                        .compactMap { $0 }
                                        .joined(separator: " · ")
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                case .queued(let message):
                                    Text(result.identifier)
                                        .font(.callout)
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                case .failed(let error):
                                    Text(result.identifier)
                                        .font(.callout)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .frame(width: 680, height: 540)
        .interactiveDismissDisabled(isProcessing)
        .onDisappear {
            cancelResolution()
        }
    }

    private var identifiers: [String] {
        inputText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func startBatchFetch() {
        let inputs = identifiers
        total = inputs.count
        progress = 0
        results = []
        preparedForConfirmation = []
        pendingDeliveryToken = nil
        isProcessing = !inputs.isEmpty

        guard isProcessing else { return }

        resolutionTask?.cancel()
        let deliveryToken = deliveryGate.begin()
        resolutionTask = Task { @MainActor in
            let maxConcurrency = 3
            var prepared = Array<PreparedMetadataImport?>(repeating: nil, count: inputs.count)

            await withTaskGroup(of: (Int, String, MetadataResolutionResult).self) { group in
                var nextIndex = 0

                // Seed initial batch
                while nextIndex < min(maxConcurrency, inputs.count) {
                    let index = nextIndex
                    let identifier = inputs[index]
                    nextIndex += 1
                    group.addTask {
                        let outcome = await resolver.resolveManualEntry(identifier)
                        let result = outcome.result
                        // Note: outcome.preferredPDFURL is intentionally discarded — batch import
                        // doesn't auto-download URL-derived PDFs.
                        return (index, identifier, result)
                    }
                }

                // Process results as they arrive, enqueue more work
                for await (index, identifier, result) in group {
                    guard !Task.isCancelled, deliveryGate.shouldDeliver(deliveryToken) else {
                        group.cancelAll()
                        return
                    }
                    prepared[index] = PreparedMetadataImport(input: identifier, result: result)
                    switch result {
                    case .verified(let envelope):
                        appendResult(identifier: identifier, outcome: .imported(envelope.reference))
                    case .candidate, .blocked, .seedOnly, .rejected:
                        appendResult(
                            identifier: identifier,
                            outcome: .queued(String(localized: "Ready for review", bundle: .module))
                        )
                    }

                    if nextIndex < inputs.count {
                        let nextIndexToResolve = nextIndex
                        let nextIdentifier = inputs[nextIndexToResolve]
                        nextIndex += 1
                        group.addTask {
                            let outcome = await resolver.resolveManualEntry(nextIdentifier)
                            let result = outcome.result
                            // Note: outcome.preferredPDFURL is intentionally discarded — batch import
                            // doesn't auto-download URL-derived PDFs.
                            return (nextIndexToResolve, nextIdentifier, result)
                        }
                    }
                }
            }

            guard !Task.isCancelled, deliveryGate.shouldDeliver(deliveryToken) else { return }
            let completed = prepared.compactMap { $0 }
            isProcessing = false
            statusMessage = nil
            resolutionTask = nil

            switch BatchImportPresentation.completionRoute(
                requestedInputCount: inputs.count,
                results: completed.map(\.result)
            ) {
            case .awaitVerifiedSingleConfirmation:
                preparedForConfirmation = completed
                pendingDeliveryToken = deliveryToken
            case .persistQueuedSingleInPlace:
                guard let entry = completed.first else { return }
                onQueueResult(entry.result, entry.input)
            case .deliverImmediately:
                onPrepared(completed)
                dismiss()
            }
        }
    }

    private func deliverVerifiedSingle() {
        guard let pendingDeliveryToken,
              deliveryGate.shouldDeliver(pendingDeliveryToken),
              !preparedForConfirmation.isEmpty
        else { return }

        let prepared = preparedForConfirmation
        preparedForConfirmation = []
        self.pendingDeliveryToken = nil
        onPrepared(prepared)
        dismiss()
    }

    private func cancelResolutionAndDismiss() {
        cancelResolution()
        dismiss()
    }

    private func cancelResolution() {
        deliveryGate.cancel()
        resolutionTask?.cancel()
        resolutionTask = nil
        isProcessing = false
        preparedForConfirmation = []
        pendingDeliveryToken = nil
    }

    private func appendResult(identifier: String, outcome: ImportResult.Outcome) {
        results.append(ImportResult(identifier: identifier, outcome: outcome))
        progress += 1
        if progress >= total {
            statusMessage = nil
        }
    }

    private func statusMessage(for input: String) -> String {
        if let url = URL(string: input), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            _ = url
            return String(localized: "addByIdentifier.status.validating", bundle: .module)
        }
        if MetadataFetcher.extractIdentifier(from: input) != nil {
            return String(localized: "addByIdentifier.status.resolvingIdentifier", bundle: .module)
        }
        return String(localized: "addByIdentifier.status.queryingMetadata", bundle: .module)
    }

    private func iconName(for outcome: ImportResult.Outcome) -> String {
        switch outcome {
        case .imported:
            return "checkmark.circle.fill"
        case .queued:
            return "clock.badge.exclamationmark"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    private func iconColor(for outcome: ImportResult.Outcome) -> Color {
        switch outcome {
        case .imported:
            return .green
        case .queued:
            return .orange
        case .failed:
            return .red
        }
    }
}
#endif
