import Foundation

// MARK: - Per-backend static capabilities (Phase 3b-3)
//
// One descriptor per coding-agent backend: display name, the model/effort lists it
// accepts, its defaults, and whether it has an OS sandbox. This is the SINGLE place
// backend-specific static data lives — adding a third backend is one literal here,
// and the compiler still forces the switch to be exhaustive. Crucially the default
// model/effort sit next to their own list, so they can't drift (the values the
// runtime accepts and the value we seed are co-located).

struct AgentBackendDescriptor {
    /// User-facing backend name (composer picker + Settings).
    let displayName: String
    /// Model aliases in display order — the value is the slug passed to the runtime
    /// (`--model` for Claude; `model` on `thread/start` for Codex).
    let models: [(label: String, value: String)]
    /// Reasoning-effort levels in display order.
    let efforts: [(label: String, value: String)]
    /// Seed model for a fresh conversation (must be one of `models`).
    let defaultModel: String
    /// Seed effort for a fresh conversation (must be one of `efforts`).
    let defaultEffort: String
    /// Whether the backend has a user-selectable OS sandbox (Codex only).
    let supportsSandbox: Bool
}

extension AgentProviderKind {
    /// The static capabilities for this backend. Verified against the runtimes:
    /// Claude `--model`/`--effort`; Codex slugs from the codex 0.142 binary
    /// (`gpt-5.5` is the config default). Codex has no `max` effort and defaults to
    /// `medium` deliberately — the user's `~/.codex` default is often `xhigh`, which
    /// can stall a turn (Risk #8); pinning `medium` avoids it.
    var descriptor: AgentBackendDescriptor {
        switch self {
        case .claude:
            return AgentBackendDescriptor(
                displayName: "Claude",
                models: [("Fable", "fable"), ("Opus", "opus"), ("Sonnet", "sonnet")],
                efforts: [("Low", "low"), ("Medium", "medium"), ("High", "high"),
                          ("xHigh", "xhigh"), ("Max", "max")],
                defaultModel: "opus",
                defaultEffort: "high",
                supportsSandbox: false)
        case .codex:
            return AgentBackendDescriptor(
                displayName: "Codex",
                models: [("GPT-5.5", "gpt-5.5"), ("GPT-5.5 Pro", "gpt-5.5-pro")],
                efforts: [("Low", "low"), ("Medium", "medium"), ("High", "high"), ("xHigh", "xhigh")],
                defaultModel: "gpt-5.5",
                defaultEffort: "medium",
                supportsSandbox: true)
        }
    }

    /// User-facing backend name (composer picker + Settings).
    var displayName: String { descriptor.displayName }
}

// MARK: - Assistant model & effort choices (thin facades over the descriptor)
//
// One source of truth for the sidebar's per-conversation pickers and the
// Settings ▸ Assistant defaults, so the two can't drift. These read
// `kind.descriptor`; call sites use `AssistantModelOptions.models(for:)` etc. and
// don't churn when the descriptor changes.

enum AssistantModelOptions {
    static func models(for kind: AgentProviderKind) -> [(label: String, value: String)] {
        kind.descriptor.models
    }

    static func efforts(for kind: AgentProviderKind) -> [(label: String, value: String)] {
        kind.descriptor.efforts
    }

    static func defaultModel(for kind: AgentProviderKind) -> String {
        kind.descriptor.defaultModel
    }

    static func defaultEffort(for kind: AgentProviderKind) -> String {
        kind.descriptor.defaultEffort
    }

    /// The display label for a model alias on this backend, falling back to the
    /// capitalized alias (e.g. a Settings-typed name not in the list).
    static func modelLabel(for value: String?, kind: AgentProviderKind) -> String {
        guard let value else { return "Model" }
        return models(for: kind).first { $0.value == value }?.label ?? value.capitalized
    }

    /// The display label for an effort level on this backend, falling back to the
    /// capitalized value.
    static func effortLabel(for value: String?, kind: AgentProviderKind) -> String? {
        guard let value else { return nil }
        return efforts(for: kind).first { $0.value == value }?.label ?? value.capitalized
    }

    /// Snap a persisted model to one this backend actually offers, else its default —
    /// so a stale/hand-edited pref (e.g. a Claude slug left in the Codex pref, or a
    /// dropped model) can't leave a picker with no valid selection or send an
    /// unaccepted slug to the runtime.
    static func normalizedModel(_ value: String, for kind: AgentProviderKind) -> String {
        models(for: kind).contains { $0.value == value } ? value : defaultModel(for: kind)
    }

    /// Snap a persisted effort to one this backend offers, else its default.
    static func normalizedEffort(_ value: String, for kind: AgentProviderKind) -> String {
        efforts(for: kind).contains { $0.value == value } ? value : defaultEffort(for: kind)
    }
}
