import SwiftUI
import RubienCore

struct ColumnConfigPopover: View {
    @Binding var columns: [ColumnConfig]
    @State private var searchText = ""

    private var visibleColumns: [ColumnConfig] {
        columns
            .filter(\.isVisible)
            .sorted { $0.displayOrder < $1.displayOrder }
            .filter { matchesSearch($0) }
    }

    private var hiddenColumns: [ColumnConfig] {
        columns
            .filter { !$0.isVisible }
            .sorted { $0.displayOrder < $1.displayOrder }
            .filter { matchesSearch($0) }
    }

    private func matchesSearch(_ config: ColumnConfig) -> Bool {
        guard !searchText.isEmpty else { return true }
        return config.columnId.header.localizedCaseInsensitiveContains(searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            scrollContent
        }
        .frame(width: 260, height: 380)
    }

    private var header: some View {
        HStack {
            Text("Properties")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search properties…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !visibleColumns.isEmpty {
                    sectionHeader("Visible")
                    ForEach(visibleColumns, id: \.columnId) { config in
                        columnRow(config)
                    }
                }

                if !hiddenColumns.isEmpty {
                    sectionHeader("Hidden")
                    ForEach(hiddenColumns, id: \.columnId) { config in
                        columnRow(config)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func columnRow(_ config: ColumnConfig) -> some View {
        let isTitle = config.columnId == .title
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(isTitle ? .quaternary : .tertiary)

            Text(config.columnId.header)
                .font(.system(size: 12))
                .foregroundStyle(isTitle ? .secondary : .primary)

            Spacer()

            if isTitle {
                Text("Locked")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            } else {
                Toggle("", isOn: Binding(
                    get: { config.isVisible },
                    set: { newValue in
                        toggleColumn(config.columnId, visible: newValue)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func toggleColumn(_ columnId: ColumnIdentifier, visible: Bool) {
        guard let idx = columns.firstIndex(where: { $0.columnId == columnId }) else { return }
        columns[idx].isVisible = visible
        if visible {
            let maxOrder = columns.filter(\.isVisible).map(\.displayOrder).max() ?? 0
            columns[idx].displayOrder = maxOrder + 1
        }
    }
}
