#if os(macOS)
import SwiftUI
import RubienCore

func orderedReferenceExportIDs(
    processed: [Reference],
    buckets: [GroupBucket]?
) -> [Int64] {
    let rows = buckets?.flatMap(\.references) ?? processed
    var seen = Set<Int64>()
    return rows.compactMap(\.id).filter { seen.insert($0).inserted }
}

struct ReferenceExportIntent: Sendable {
    let request: ReferenceExportRequest
    let suggestedBasename: String
}

enum ReferenceExportUIScope: String, CaseIterable, Identifiable {
    case selected
    case currentView
    case entireLibrary

    var id: String { rawValue }

    var label: String {
        switch self {
        case .selected: "Selected"
        case .currentView: "Current View"
        case .entireLibrary: "Entire Library"
        }
    }
}

struct ReferenceExportConfigurationContext: Identifiable, Sendable {
    let id = UUID()
    let selectedIDs: [Int64]
    let currentViewIDs: [Int64]
    let viewName: String?
    let hasEntireLibraryRows: Bool

    func intent(
        scope: ReferenceExportUIScope,
        format: ReferenceExportFormat
    ) -> ReferenceExportIntent? {
        let requestScope: ReferenceExportScope
        let basename: String
        switch scope {
        case .selected:
            guard !selectedIDs.isEmpty else { return nil }
            requestScope = .ids(selectedIDs)
            basename = "rubien-selected-\(selectedIDs.count)"
        case .currentView:
            guard !currentViewIDs.isEmpty else { return nil }
            requestScope = .ids(currentViewIDs)
            if let viewName, !viewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                basename = "rubien-\(ReferenceExportFilename.sanitize(viewName))"
            } else {
                basename = "rubien-current-view"
            }
        case .entireLibrary:
            guard hasEntireLibraryRows else { return nil }
            requestScope = .all
            basename = "rubien-library"
        }
        return ReferenceExportIntent(
            request: ReferenceExportRequest(format: format, scope: requestScope),
            suggestedBasename: basename
        )
    }
}

enum ReferenceExportFilename {
    static func sanitize(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        var result = ""
        var previousWasSeparator = false
        for scalar in normalized.unicodeScalars {
            let invalid = scalar == "/" || scalar == ":" || scalar.value == 0
                || CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            if invalid || scalar == "-" {
                if !previousWasSeparator, !result.isEmpty { result.append("-") }
                previousWasSeparator = true
            } else {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            }
        }
        let edgeCharacters = CharacterSet.punctuationCharacters
            .union(.whitespacesAndNewlines)
        result = result.trimmingCharacters(in: edgeCharacters)
        result = String(result.prefix(80))
            .trimmingCharacters(in: edgeCharacters)
        return result.isEmpty ? "current-view" : result
    }
}

struct ReferenceExportConfigurationAction {
    let perform: @MainActor () -> Void
}

private struct ReferenceExportConfigurationFocusedValueKey: FocusedValueKey {
    typealias Value = ReferenceExportConfigurationAction
}

extension FocusedValues {
    var referenceExportConfigurationAction: ReferenceExportConfigurationAction? {
        get { self[ReferenceExportConfigurationFocusedValueKey.self] }
        set { self[ReferenceExportConfigurationFocusedValueKey.self] = newValue }
    }
}

struct ReferenceExportMenuCommands: Commands {
    @FocusedValue(\.referenceExportConfigurationAction) private var action

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export References…") {
                action?.perform()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(action == nil)
        }
    }
}

struct ReferenceExportConfigurationSheet: View {
    let context: ReferenceExportConfigurationContext
    let onCancel: () -> Void
    let onContinue: (ReferenceExportIntent) -> Void

    @State private var scope: ReferenceExportUIScope
    @State private var format: ReferenceExportFormat = .bibtex

    init(
        context: ReferenceExportConfigurationContext,
        onCancel: @escaping () -> Void,
        onContinue: @escaping (ReferenceExportIntent) -> Void
    ) {
        self.context = context
        self.onCancel = onCancel
        self.onContinue = onContinue
        let initialScope: ReferenceExportUIScope
        if !context.selectedIDs.isEmpty {
            initialScope = .selected
        } else if !context.currentViewIDs.isEmpty {
            initialScope = .currentView
        } else {
            initialScope = .entireLibrary
        }
        _scope = State(initialValue: initialScope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export References")
                .font(.title2.weight(.semibold))

            Form {
                Picker("Scope", selection: $scope) {
                    ForEach(ReferenceExportUIScope.allCases) { choice in
                        Text(scopeLabel(choice)).tag(choice)
                            .disabled(!isAvailable(choice))
                    }
                }
                Picker("Format", selection: $format) {
                    ForEach(ReferenceExportFormat.presentationCases, id: \.self) { format in
                        Text(format.exportDisplayName).tag(format)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("PDFs and annotations are not included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    if let intent = context.intent(scope: scope, format: format) {
                        onContinue(intent)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(context.intent(scope: scope, format: format) == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func isAvailable(_ choice: ReferenceExportUIScope) -> Bool {
        switch choice {
        case .selected: !context.selectedIDs.isEmpty
        case .currentView: !context.currentViewIDs.isEmpty
        case .entireLibrary: context.hasEntireLibraryRows
        }
    }

    private func scopeLabel(_ choice: ReferenceExportUIScope) -> String {
        switch choice {
        case .selected: "Selected (\(context.selectedIDs.count))"
        case .currentView: "Current View (\(context.currentViewIDs.count))"
        case .entireLibrary: choice.label
        }
    }
}

extension ReferenceExportFormat {
    static var presentationCases: [ReferenceExportFormat] { [.bibtex, .ris, .json] }

    var exportDisplayName: String {
        switch self {
        case .bibtex: "BibTeX"
        case .ris: "RIS"
        case .json: "Rubien JSON"
        }
    }
}

struct ReferenceExportFormatButtons: View {
    let action: (ReferenceExportFormat) -> Void

    var body: some View {
        ForEach(ReferenceExportFormat.presentationCases, id: \.self) { format in
            Button("\(format.exportDisplayName)…") { action(format) }
        }
    }
}
#endif
