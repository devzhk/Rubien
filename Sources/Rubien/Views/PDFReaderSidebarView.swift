import SwiftUI
import PDFKit
import RubienCore

struct PDFReaderSidebarView: View {
    let reference: Reference
    @Binding var selectedTab: PDFSidebarTab

    var body: some View {
        VStack(spacing: 0) {
            DraggableSegmentedControl(
                selection: $selectedTab,
                items: [
                    (String(localized: "Outline", bundle: .module), .outline),
                    (String(localized: "Info", bundle: .module), .info),
                ]
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            switch selectedTab {
            case .outline:
                PDFOutlineSidebarView(reference: reference)
            case .info:
                PDFInfoSidebarView(reference: reference)
            case .annotations:
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
