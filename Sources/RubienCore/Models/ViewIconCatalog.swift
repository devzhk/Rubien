import Foundation

/// Curated icon choices offered in the per-view icon picker, in display order.
///
/// Pure string data — **no AppKit/SwiftUI** — because `RubienCore` compiles and
/// is tested on Linux. Symbol *rendering* lives in the app target (`ViewIconGrid`).
/// Mirrors `ColorPalette`: one flat curated list. The comment groups below are
/// for source readability only — the picker renders a single uniform grid.
public enum ViewIconCatalog {

    /// One picker choice. `value` is the SF Symbol name persisted in `DatabaseView.icon`.
    public struct Option: Hashable, Sendable {
        public let value: String
        public let label: String

        fileprivate init(systemName: String, label: String) {
            value = systemName
            self.label = label
        }
    }

    /// Default symbol for a newly created view.
    public static let defaultIcon = "folder"

    /// Curated choices in display order. Thirty-six entries fill the app's
    /// four-row, nine-column picker without a partial row.
    public static let options: [Option] = [
        // Collections / structure
        Option(systemName: "folder", label: "Folder"),
        Option(systemName: "music.note", label: "Music"),
        Option(systemName: "gamecontroller", label: "Game Controller"),
        Option(systemName: "tray.full", label: "Tray"),
        // Reading / documents
        Option(systemName: "books.vertical", label: "Books"),
        Option(systemName: "book", label: "Book"),
        Option(systemName: "doc.text", label: "Document"),
        Option(systemName: "newspaper", label: "Newspaper"),
        Option(systemName: "bookmark", label: "Bookmark"),
        // Topics / research
        Option(systemName: "graduationcap", label: "Education"),
        Option(systemName: "atom", label: "Science"),
        Option(systemName: "brain", label: "Ideas"),
        Option(systemName: "globe", label: "World"),
        Option(systemName: "chart.xyaxis.line", label: "Chart"),
        Option(systemName: "lightbulb", label: "Insight"),
        // Markers / status
        Option(systemName: "star", label: "Star"),
        Option(systemName: "flag", label: "Flag"),
        Option(systemName: "pin", label: "Pin"),
        Option(systemName: "tag", label: "Tag"),
        Option(systemName: "sparkles", label: "Sparkles"),
        Option(systemName: "cube", label: "Cube"),
        // Playful native alternatives for the requested travel / animal / fruit set
        Option(systemName: "paperplane", label: "Paper Plane"),
        Option(systemName: "sailboat", label: "Sailboat"),
        Option(systemName: "alarm", label: "Alarm"),
        Option(systemName: "leaf", label: "Leaf"),
        Option(systemName: "carrot", label: "Carrot"),
        Option(systemName: "fish", label: "Fish"),
        // Additional topics / activities
        Option(systemName: "heart", label: "Heart"),
        Option(systemName: "bolt.square", label: "Energy"),
        Option(systemName: "globe.americas", label: "Americas"),
        Option(systemName: "tornado", label: "Tornado"),
        Option(systemName: "lizard", label: "Lizard"),
        Option(systemName: "tree", label: "Tree"),
        Option(systemName: "figure.skiing.downhill", label: "Skiing"),
        Option(systemName: "hands.and.sparkles", label: "Care"),
        Option(systemName: "apple.terminal.on.rectangle", label: "Terminal"),
    ]

    /// Stable persisted values, retained as the simple catalog API used by models/tests.
    public static let all: [String] = options.map(\.value)
}
