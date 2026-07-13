#if os(macOS)
import SwiftUI
import RubienCore

/// A compact grid of curated SF Symbols for choosing a view's icon.
/// Selection is two-way bound; the chosen cell is highlighted in the accent color.
struct ViewIconGrid: View {
    @Binding var selection: String

    private static let columnCount = 9
    private static let cellWidth: CGFloat = 34
    private static let spacing: CGFloat = 6

    static let preferredWidth = (
        CGFloat(columnCount) * cellWidth
        + CGFloat(columnCount - 1) * spacing
    )

    private static let columns = Array(
        repeating: GridItem(.fixed(Self.cellWidth), spacing: Self.spacing),
        count: Self.columnCount
    )

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: Self.spacing) {
            ForEach(ViewIconCatalog.options, id: \.value) { option in
                let isSelected = selection == option.value
                ViewIconButton(
                    option: option,
                    isSelected: isSelected,
                    width: Self.cellWidth
                ) {
                    selection = option.value
                }
            }
        }
    }
}

private struct ViewIconButton: View {
    let option: ViewIconCatalog.Option
    let isSelected: Bool
    let width: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: option.value)
                .font(.system(size: 15, weight: .regular))
                .frame(width: width, height: 30)
                .foregroundStyle(foregroundColor)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(Text(option.label))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var foregroundColor: Color {
        if isSelected { return .white }
        return Color.primary.opacity(isHovered ? 1 : 0.8)
    }

    private var backgroundColor: Color {
        if isSelected { return .accentColor }
        return Color.primary.opacity(isHovered ? 0.12 : 0.06)
    }
}
#endif
