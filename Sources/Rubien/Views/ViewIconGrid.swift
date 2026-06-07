#if os(macOS)
import SwiftUI
import RubienCore

/// A compact grid of curated SF Symbols for choosing a view's icon.
/// Selection is two-way bound; the chosen cell is highlighted in the accent color.
struct ViewIconGrid: View {
    @Binding var selection: String

    private let columns = Array(
        repeating: GridItem(.fixed(34), spacing: 6),
        count: 6
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(ViewIconCatalog.all, id: \.self) { symbol in
                let isSelected = selection == symbol
                Button {
                    selection = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 34, height: 30)
                        .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.8))
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                        )
                        .contentShape(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help(symbol)
            }
        }
    }
}
#endif
