import Foundation

public enum ColorPalette {
    public static let `default`: [String] = [
        "#007AFF", "#34C759", "#FF9500", "#FF3B30", "#AF52DE",
        "#5AC8FA", "#FF2D55", "#FFCC00", "#00C7BE", "#8E8E93",
        "#30B0C7", "#A2845E", "#FF6482", "#64D2FF", "#BF5AF2",
    ]

    /// Prefer unused entries so new tags/options visually diverge until the
    /// palette is exhausted, then fall back to a random entry.
    public static func nextUnused(excluding used: Set<String>) -> String {
        `default`.first { !used.contains($0) }
            ?? `default`.randomElement()
            ?? `default`[0]
    }
}
