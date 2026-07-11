#if os(macOS)
import SwiftUI
import RubienCore

enum ImportSourceSheetSelectionSummary: Equatable {
    case filename(String)
    case count(Int)
}

/// Pure, panel-free state for the PDF/Markdown source sheet. Keeping the
/// mutually exclusive input modes here makes the interaction independently
/// testable and ensures a typed source can never be combined with a picker
/// selection by accident.
struct ImportSourceSheetState {
    private(set) var typedInput: String
    private(set) var stagedURLs: [URL]
    private(set) var isAcquiring: Bool

    init(typedInput: String = "", stagedURLs: [URL] = []) {
        self.typedInput = typedInput
        self.stagedURLs = stagedURLs
        self.isAcquiring = false
    }

    var canImport: Bool {
        normalizedTypedInput != nil || !stagedURLs.isEmpty
    }

    var canSubmit: Bool {
        canImport && !isAcquiring
    }

    mutating func beginSubmission() -> Bool {
        guard canSubmit else { return false }
        isAcquiring = true
        return true
    }

    mutating func finishSubmission() {
        isAcquiring = false
    }

    var normalizedTypedInput: String? {
        let trimmed = typedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var stagedSelectionSummary: ImportSourceSheetSelectionSummary? {
        switch stagedURLs.count {
        case 0:
            nil
        case 1:
            .filename(stagedURLs[0].lastPathComponent)
        default:
            .count(stagedURLs.count)
        }
    }

    mutating func setTypedInput(_ input: String) {
        guard !isAcquiring else { return }
        typedInput = input
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            stagedURLs = []
        }
    }

    mutating func setStagedURLs(_ urls: [URL]) {
        guard !isAcquiring else { return }
        stagedURLs = urls
        typedInput = ""
    }
}

struct ImportSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state = ImportSourceSheetState()
    @State private var acquisitionError: String?

    let onImport: ([MaterializedImportSource]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "importSourceSheet.title", bundle: .module))
                .font(.headline)

            TextField(
                String(localized: "importSourceSheet.field.placeholder", bundle: .module),
                text: Binding(
                    get: { state.typedInput },
                    set: { input in
                        state.setTypedInput(input)
                        acquisitionError = nil
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .disabled(state.isAcquiring)

            HStack(spacing: 10) {
                Button(String(localized: "importSourceSheet.button.choose", bundle: .module)) {
                    chooseFiles()
                }
                .buttonStyle(SLSecondaryButtonStyle())
                .disabled(state.isAcquiring)

                if let summary = state.stagedSelectionSummary {
                    stagedSelectionLabel(summary)
                }

                Spacer(minLength: 0)

                if state.isAcquiring {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "importSourceSheet.status.preparing", bundle: .module))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let acquisitionError {
                Label(
                    String(
                        format: String(localized: "importSourceSheet.error.acquisition", bundle: .module),
                        acquisitionError
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer()

                Button(String(localized: "common.cancel", bundle: .module)) {
                    dismiss()
                }
                .buttonStyle(SLSecondaryButtonStyle())
                .disabled(state.isAcquiring)

                Button(String(localized: "importSourceSheet.button.import", bundle: .module)) {
                    beginImport()
                }
                .buttonStyle(SLPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!state.canSubmit)
            }
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .interactiveDismissDisabled(state.isAcquiring)
    }

    @ViewBuilder
    private func stagedSelectionLabel(_ summary: ImportSourceSheetSelectionSummary) -> some View {
        switch summary {
        case .filename(let filename):
            Label(filename, systemImage: "doc")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        case .count(let count):
            Label(
                String(
                    format: String(localized: "importSourceSheet.selection.multiple", bundle: .module),
                    count
                ),
                systemImage: "doc.on.doc"
            )
            .foregroundStyle(.secondary)
        }
    }

    private func chooseFiles() {
        let urls = OpenPanelPicker.pickImportableFiles()
        // A cancelled panel must preserve the prior source mode and selection.
        guard !urls.isEmpty else { return }
        state.setStagedURLs(urls)
        acquisitionError = nil
    }

    private func beginImport() {
        guard state.beginSubmission() else { return }
        acquisitionError = nil

        Task { @MainActor in
            do {
                let sources = try await materializeSources()
                state.finishSubmission()
                onImport(sources)
                dismiss()
            } catch {
                state.finishSubmission()
                acquisitionError = error.localizedDescription
            }
        }
    }

    private func materializeSources() async throws -> [MaterializedImportSource] {
        if let typedInput = state.normalizedTypedInput {
            return [
                try await ImportSourceMaterializer.materialize(
                    typedInput,
                    localPathPolicy: .requireAbsolute
                )
            ]
        }

        var sources: [MaterializedImportSource] = []
        do {
            for url in state.stagedURLs {
                // The open panel grants scoped access to sandboxed builds. The
                // exact URL is retained so the batch coordinator can reacquire
                // that same scope while consuming the source.
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                sources.append(
                    try ImportSourceMaterializer.materialize(localFileURL: url)
                )
            }
            return sources
        } catch {
            sources.forEach { $0.cleanup() }
            throw error
        }
    }
}
#endif
