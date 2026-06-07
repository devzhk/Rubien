import Foundation

/// Curated SF Symbol names offered in the per-view icon picker, in display order.
///
/// Pure string data — **no AppKit/SwiftUI** — because `RubienCore` compiles and
/// is tested on Linux. Symbol *rendering* lives in the app target (`ViewIconGrid`).
/// Mirrors `ColorPalette`: one flat curated list. The comment groups below are
/// for source readability only — the picker renders a single uniform grid.
public enum ViewIconCatalog {

    /// Default symbol for a newly created view (a stacked-collection glyph).
    public static let defaultIcon = "square.stack"

    /// Curated symbols in display order.
    public static let all: [String] = [
        // Collections / structure
        "square.stack", "rectangle.stack", "square.grid.2x2",
        "folder", "tray.full", "archivebox",
        // Reading / documents
        "books.vertical", "book", "text.book.closed",
        "doc.text", "newspaper", "bookmark",
        // Topics / research
        "graduationcap", "atom", "brain",
        "globe", "chart.xyaxis.line", "lightbulb",
        // Markers / status
        "star", "flag", "pin",
        "tag", "sparkles", "cube",
    ]
}
