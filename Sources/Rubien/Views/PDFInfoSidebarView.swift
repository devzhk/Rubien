import SwiftUI
import RubienCore

struct PDFInfoSidebarView: View {
    let reference: Reference
    @State private var expandedRows: Set<String> = []

    var body: some View {
        OverlayScrollView {
            VStack(alignment: .leading, spacing: 16) {
                infoSection(String(localized: "Basics", bundle: .module)) {
                    infoRow(String(localized: "Title", bundle: .module), value: reference.title)
                    infoRow(String(localized: "Authors", bundle: .module), value: reference.authors.map { $0.displayName }.joined(separator: ", "))
                    infoRow(String(localized: "Year", bundle: .module), value: reference.year.map { String($0) })
                    infoRow(String(localized: "Type", bundle: .module), value: reference.referenceType.rawValue)
                }

                infoSection(String(localized: "Publication", bundle: .module)) {
                    infoRow(String(localized: "Journal", bundle: .module), value: reference.journal)
                    infoRow(String(localized: "Volume", bundle: .module), value: reference.volume)
                    infoRow(String(localized: "Issue", bundle: .module), value: reference.issue)
                    infoRow(String(localized: "Pages", bundle: .module), value: reference.pages)
                    infoRow(String(localized: "Publisher", bundle: .module), value: reference.publisher)
                    infoRow(String(localized: "Place", bundle: .module), value: reference.publisherPlace)
                    infoRow(String(localized: "Edition", bundle: .module), value: reference.edition)
                    infoRow(String(localized: "Institution", bundle: .module), value: reference.institution)
                    infoRow(String(localized: "Language", bundle: .module), value: reference.language)
                    infoRow(String(localized: "Page count", bundle: .module), value: reference.numberOfPages)
                }

                infoSection(String(localized: "Identifiers", bundle: .module)) {
                    infoRow("DOI", value: reference.doi)
                    infoRow("ISBN", value: reference.isbn)
                    infoRow("ISSN", value: reference.issn)
                    if let url = reference.url {
                        infoRow("URL", value: url)
                    }
                }

                if let abstract = reference.abstract, !abstract.isEmpty {
                    infoSection(String(localized: "Abstract", bundle: .module)) {
                        Text(abstract)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
        }
    }

    private func infoSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            let isExpanded = expandedRows.contains(label)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded {
                        expandedRows.remove(label)
                    } else {
                        expandedRows.insert(label)
                    }
                }
            }) {
                HStack(alignment: .top, spacing: 8) {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 45, alignment: .trailing)
                        .padding(.top, 1)
                    Text(value)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }
}
