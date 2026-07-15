#if os(macOS)
import SwiftUI
import RubienCore

enum AddReferenceSourceSelectionSummary: Equatable {
    case filename(String)
    case count(Int)
}

enum AddReferenceSourceRoute {
    case metadata(String)
    case website(String)
    case files([MaterializedImportSource])
}

/// Pure, panel-free state for the unified Add Reference sheet. Keeping the
/// mutually exclusive input modes here makes the interaction independently
/// testable and ensures typed input can never be combined with a picker
/// selection by accident.
struct AddReferenceSourceSheetState {
    private(set) var typedInput: String
    private(set) var stagedURLs: [URL]
    private(set) var isAcquiring: Bool
    private(set) var submittedInvalidReason: AddReferenceInputRouter.InvalidReason?

    init(typedInput: String = "", stagedURLs: [URL] = []) {
        self.typedInput = typedInput
        self.stagedURLs = stagedURLs
        self.isAcquiring = false
        self.submittedInvalidReason = nil
    }

    var hasSource: Bool {
        normalizedTypedInput != nil || !stagedURLs.isEmpty
    }

    var canSubmit: Bool {
        hasSource && !isAcquiring
    }

    func canSubmit(previewRoute: AddReferenceInputRouter.Route?) -> Bool {
        guard canSubmit, submittedInvalidReason == nil else { return false }
        if case .invalid = previewRoute { return false }
        return true
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

    var stagedSelectionSummary: AddReferenceSourceSelectionSummary? {
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
        submittedInvalidReason = nil
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            stagedURLs = []
        }
    }

    mutating func setStagedURLs(_ urls: [URL]) {
        guard !isAcquiring else { return }
        stagedURLs = urls
        typedInput = ""
        submittedInvalidReason = nil
    }

    mutating func recordSubmittedInvalidReason(_ reason: AddReferenceInputRouter.InvalidReason) {
        submittedInvalidReason = reason
    }
}

struct AddReferenceSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state = AddReferenceSourceSheetState()
    @State private var acquisitionError: String?
    @State private var routingTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    let allowsFileImports: Bool
    let onRoute: (AddReferenceSourceRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "addReferenceSourceSheet.title", bundle: .module))
                .font(.headline)

            TextField(
                String(localized: "addReferenceSourceSheet.field.placeholder", bundle: .module),
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
            .focused($inputFocused)
            .onSubmit(beginRouting)

            Text(String(localized: "addReferenceSourceSheet.hint", bundle: .module))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let input = state.normalizedTypedInput {
                detectedSourceLabel(for: input)
                    .font(.caption)
            }

            if !state.stagedURLs.isEmpty {
                Label(
                    String(localized: "addReferenceSourceSheet.detected.file", bundle: .module),
                    systemImage: "doc.badge.plus"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(String(localized: "addReferenceSourceSheet.button.choose", bundle: .module)) {
                    chooseFiles()
                }
                .buttonStyle(SLSecondaryButtonStyle())
                .disabled(state.isAcquiring || !allowsFileImports)

                if let summary = state.stagedSelectionSummary {
                    stagedSelectionLabel(summary)
                }

                Spacer(minLength: 0)

                if state.isAcquiring {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "addReferenceSourceSheet.status.preparing", bundle: .module))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let acquisitionError {
                Label(
                    String(
                        format: String(localized: "addReferenceSourceSheet.error.acquisition", bundle: .module),
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

                Button(String(localized: "addReferenceSourceSheet.button.continue", bundle: .module)) {
                    beginRouting()
                }
                .buttonStyle(SLPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canRouteSubmission)
            }
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .interactiveDismissDisabled(state.isAcquiring)
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            inputFocused = true
        }
        .onDisappear {
            routingTask?.cancel()
            routingTask = nil
        }
    }

    @ViewBuilder
    private func detectedSourceLabel(for input: String) -> some View {
        if let reason = state.submittedInvalidReason {
            Label(invalidInputMessage(for: reason), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else {
            switch previewRoute(for: input) {
            case .metadata:
                Label(
                    String(localized: "addReferenceSourceSheet.detected.metadata", bundle: .module),
                    systemImage: "text.magnifyingglass"
                )
                .foregroundStyle(.secondary)
            case .website:
                Label(
                    String(localized: "addReferenceSourceSheet.detected.website", bundle: .module),
                    systemImage: "globe"
                )
                .foregroundStyle(.secondary)
            case .file:
                Label(
                    String(localized: "addReferenceSourceSheet.detected.file", bundle: .module),
                    systemImage: "doc.badge.plus"
                )
                .foregroundStyle(.secondary)
            case .invalid(let reason):
                Label(invalidInputMessage(for: reason), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var canRouteSubmission: Bool {
        let route = state.normalizedTypedInput.map(previewRoute(for:))
        return state.canSubmit(previewRoute: route)
    }

    private func previewRoute(for input: String) -> AddReferenceInputRouter.Route {
        AddReferenceInputRouter.classify(input, probe: { _ in
            ImportRouter.PathProbe(exists: false, isDirectory: false)
        })
    }

    private func invalidInputMessage(for reason: AddReferenceInputRouter.InvalidReason) -> String {
        switch reason {
        case .emptyInput:
            String(localized: "addReferenceSourceSheet.error.empty", bundle: .module)
        case .directory:
            String(localized: "addReferenceSourceSheet.error.directory", bundle: .module)
        case .invalidHTTPURL:
            String(localized: "addReferenceSourceSheet.error.invalidURL", bundle: .module)
        case .unsupportedURLScheme:
            String(localized: "addReferenceSourceSheet.error.urlScheme", bundle: .module)
        case .unsupportedFileType(let pathExtension):
            if let pathExtension {
                String(
                    format: String(localized: "addReferenceSourceSheet.error.fileType", bundle: .module),
                    pathExtension
                )
            } else {
                String(localized: "addReferenceSourceSheet.error.fileTypeUnknown", bundle: .module)
            }
        case .relativeFilePath:
            String(localized: "addReferenceSourceSheet.error.relativePath", bundle: .module)
        }
    }

    @ViewBuilder
    private func stagedSelectionLabel(_ summary: AddReferenceSourceSelectionSummary) -> some View {
        switch summary {
        case .filename(let filename):
            Label(filename, systemImage: "doc")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        case .count(let count):
            Label(
                String(
                    format: String(localized: "addReferenceSourceSheet.selection.multiple", bundle: .module),
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

    private func beginRouting() {
        guard canRouteSubmission, state.beginSubmission() else { return }
        acquisitionError = nil
        routingTask?.cancel()
        routingTask = Task { @MainActor in
            await routeSubmission()
        }
    }

    @MainActor
    private func routeSubmission() async {
        defer {
            state.finishSubmission()
            routingTask = nil
        }

        let routedFileInput: String?
        if let typedInput = state.normalizedTypedInput {
            switch AddReferenceInputRouter.classify(typedInput) {
            case .metadata(let input):
                onRoute(.metadata(input))
                dismiss()
                return
            case .website(let url):
                onRoute(.website(url))
                dismiss()
                return
            case .invalid(let reason):
                state.recordSubmittedInvalidReason(reason)
                return
            case .file(let input):
                routedFileInput = input
            }
        } else {
            routedFileInput = nil
        }

        guard allowsFileImports else {
            acquisitionError = String(
                localized: "addReferenceSourceSheet.error.importInProgress",
                bundle: .module
            )
            return
        }

        do {
            let sources = try await materializeSources(typedInput: routedFileInput)
            guard !Task.isCancelled else {
                sources.forEach { $0.cleanup() }
                return
            }
            onRoute(.files(sources))
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            acquisitionError = error.localizedDescription
        }
    }

    private func materializeSources(typedInput: String?) async throws -> [MaterializedImportSource] {
        if let typedInput {
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
                try Task.checkCancellation()
                sources.append(try await Self.materializePickedFile(url))
            }
            return sources
        } catch {
            sources.forEach { $0.cleanup() }
            throw error
        }
    }

    private static func materializePickedFile(_ url: URL) async throws -> MaterializedImportSource {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()

            // The open panel grants scoped access to sandboxed builds. Keep
            // that access around the off-main validation and retain the exact
            // URL for the import coordinator to reacquire later.
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let source = try ImportSourceMaterializer.materialize(localFileURL: url)
            guard !Task.isCancelled else {
                source.cleanup()
                throw CancellationError()
            }
            return source
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
#endif
