import Foundation

/// Curated SF Symbol names offered in the per-view icon picker.
///
/// Pure string data — **no AppKit/SwiftUI** — because `RubienCore` compiles and
/// is tested on Linux. Symbol *rendering* lives in the app target (`ViewIconGrid`).
public enum ViewIconCatalog {

    /// Default symbol for a newly created view (a stacked-collection glyph).
    public static let defaultIcon = "square.stack"

    /// Collections / structure.
    public static let collections = [
        "square.stack", "rectangle.stack", "square.grid.2x2",
        "folder", "tray.full", "archivebox",
    ]

    /// Reading / documents.
    public static let readingDocs = [
        "books.vertical", "book", "text.book.closed",
        "doc.text", "newspaper", "bookmark",
    ]

    /// Topics / research.
    public static let topicsResearch = [
        "graduationcap", "atom", "brain",
        "globe", "chart.xyaxis.line", "lightbulb",
    ]

    /// Markers / status.
    public static let markersStatus = [
        "star", "flag", "pin",
        "tag", "sparkles", "cube",
    ]

    /// Ordered groups for sectioned rendering.
    public static let groups: [[String]] = [
        collections, readingDocs, topicsResearch, markersStatus,
    ]

    /// Flattened catalog in display order.
    public static let all: [String] = groups.flatMap { $0 }
}
