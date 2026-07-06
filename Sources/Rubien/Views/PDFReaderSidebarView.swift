#if os(macOS)
import SwiftUI
import PDFKit
import RubienCore

struct PDFReaderSidebarView: View {
    let reference: Reference
    @ObservedObject var viewModel: PDFReaderViewModel
    @Binding var selectedTab: PDFSidebarTab

    var body: some View {
        VStack(spacing: 0) {
            DraggableSegmentedControl(
                selection: $selectedTab,
                items: [
                    (String(localized: "Outline", bundle: .module), .outline),
                    (String(localized: "Search", bundle: .module), .search),
                    (String(localized: "Notes", bundle: .module), .annotations),
                    (String(localized: "Info", bundle: .module), .info),
                ]
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            switch selectedTab {
            case .outline:
                PDFOutlineSidebarView(reference: reference, pdfURL: viewModel.pdfURL)
            case .search:
                PDFSearchSidebarView(viewModel: viewModel)
            case .annotations:
                AnnotationSidebarView(viewModel: viewModel)
            case .info:
                PDFInfoSidebarView(reference: reference)
            }
        }
        .legacyBackground(Color(nsColor: NSColor(name: nil) { trait in
            trait.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.15, alpha: 1.0)
                : NSColor(calibratedWhite: 0.90, alpha: 1.0)
        }))
        .navigationTitle("")
    }
}
#endif
