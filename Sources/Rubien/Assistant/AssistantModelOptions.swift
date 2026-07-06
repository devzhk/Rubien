import Foundation

// MARK: - Assistant model & effort choices (Phase 2c)
//
// One source of truth for the sidebar's per-conversation pickers and the
// Settings ▸ Assistant defaults, so the two can't drift (e.g. the sidebar
// dropping Haiku must not leave Settings still offering it). Plain (label, value)
// pairs — the value is the CLI alias passed to `--model` / `--effort`.

enum AssistantModelOptions {
    /// Claude model aliases, in the order shown. Matches `claude --model`.
    static let models: [(label: String, value: String)] = [
        ("Fable", "fable"),
        ("Opus", "opus"),
        ("Sonnet", "sonnet"),
    ]

    /// Reasoning-effort levels, in the order shown. Matches `claude --effort`.
    static let efforts: [(label: String, value: String)] = [
        ("Low", "low"),
        ("Medium", "medium"),
        ("High", "high"),
        ("xHigh", "xhigh"),
        ("Max", "max"),
    ]

    /// The display label for a model alias, falling back to the capitalized alias
    /// (e.g. a Settings-typed full model name that isn't in `models`).
    static func modelLabel(for value: String?) -> String {
        guard let value else { return "Model" }
        return models.first { $0.value == value }?.label ?? value.capitalized
    }

    /// The display label for an effort level, falling back to the capitalized value.
    static func effortLabel(for value: String?) -> String? {
        guard let value else { return nil }
        return efforts.first { $0.value == value }?.label ?? value.capitalized
    }
}
