#if os(macOS)
import SwiftUI
import RubienCore

/// Presentation state for the unified Add Reference flow. Metadata and website
/// confirmation replace the intake content in the same sheet, avoiding a
/// fragile dismiss-then-present transition between separate SwiftUI sheets.
struct AddReferenceFlowState {
    enum Step: Equatable {
        case source
        case metadata(String)
        case website(String)
    }

    private(set) var step: Step = .source

    mutating func advance(
        using route: AddReferenceSourceRoute
    ) -> [MaterializedImportSource]? {
        switch route {
        case .metadata(let input):
            step = .metadata(input)
            return nil
        case .website(let url):
            step = .website(url)
            return nil
        case .files(let sources):
            return sources
        }
    }
}

struct AddReferenceFlowSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state = AddReferenceFlowState()

    let allowsFileImports: Bool
    let resolver: MetadataResolver
    let onSaveMetadata: (Reference, _ downloadPDF: Bool, _ pdfURLOverride: String?) -> Void
    let onQueueMetadata: (MetadataResolutionResult, String) -> Void
    let onSaveWebsite: (Reference) -> Void
    let onFiles: ([MaterializedImportSource]) -> Void

    var body: some View {
        Group {
            switch state.step {
            case .source:
                AddReferenceSourceSheet(allowsFileImports: allowsFileImports) { route in
                    if let sources = state.advance(using: route) {
                        onFiles(sources)
                        dismiss()
                    }
                }
            case .metadata(let input):
                AddByIdentifierView(
                    resolver: resolver,
                    initialInput: input,
                    onSave: onSaveMetadata,
                    onQueueResult: onQueueMetadata
                )
            case .website(let url):
                WebImportView(initialURL: url, onSave: onSaveWebsite)
            }
        }
    }
}
#endif
