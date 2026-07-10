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
    /// Seed model for a fresh conversation (must be one of `models`), or nil for a
    /// backend whose models are DISCOVERED live (Codex): a nil pick means "send no
    /// model" and the runtime resolves its own default.
    let defaultModel: String?
    /// Seed effort for a fresh conversation (must be one of `efforts`).
    let defaultEffort: String
    /// Whether the backend has a user-selectable OS sandbox (Codex only).
    let supportsSandbox: Bool
}

extension AgentProviderKind {
    /// The static capabilities for this backend. Claude verified against
    /// `--model`/`--effort` (claude 2.1.206 documents exactly these aliases —
    /// spec §2.4; no discovery API exists, so Claude stays curated-static).
    /// Codex models are DISCOVERED live via `CodexModelCatalog` (`model/list`,
    /// spec §4.1) — the descriptor deliberately has NO baked model list (a
    /// discovery-failed old codex is exactly the one that would reject baked
    /// current-generation slugs; finding #1). Its efforts here are the universal
    /// catalog-less fallback four only, never a normalization gate.
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
                models: [],
                efforts: [("Low", "low"), ("Medium", "medium"), ("High", "high"), ("xHigh", "xhigh")],
                defaultModel: nil,
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

    static func defaultModel(for kind: AgentProviderKind) -> String? {
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

    /// Snap a persisted model to one this backend's STATIC list offers, else its
    /// default. Only meaningful for statically-listed backends (Claude); a
    /// discovery-fed backend (Codex) passes values through — validity there is the
    /// catalog-aware picker's job (spec §4.4), never a silent rewrite.
    static func normalizedModel(_ value: String, for kind: AgentProviderKind) -> String {
        guard let fallback = defaultModel(for: kind) else { return value }
        return models(for: kind).contains { $0.value == value } ? value : fallback
    }

    /// Snap a persisted effort to the static list — Claude only, same rule as
    /// `normalizedModel` (Codex efforts are per-model, from the catalog).
    static func normalizedEffort(_ value: String, for kind: AgentProviderKind) -> String {
        guard kind.descriptor.defaultModel != nil else { return value }
        return efforts(for: kind).contains { $0.value == value } ? value : defaultEffort(for: kind)
    }

    // MARK: Codex dynamic picker rows (shared by the sidebar and Settings — spec §4.6)

    /// The Codex model picker's rows. Row 0 is always "Codex default" (`value: nil`
    /// — send no model; codex resolves its own config), suffixed with the resolved
    /// model's name when known AND the default is the active pick. A `pinned` slug
    /// absent from the catalog stays visible/selectable (finding #6) — with a
    /// warning suffix once the catalog has actually loaded, bare while it's pending.
    static func codexModelRows(
        models: [CodexModelInfo], pinned: String?, resolvedModel: String?
    ) -> [(label: String, value: String?)] {
        var rows: [(label: String, value: String?)] = []
        if pinned == nil, let resolvedModel {
            let name = models.first { $0.id == resolvedModel }?.displayName ?? resolvedModel
            rows.append((label: "Codex default (\(name))", value: nil))
        } else {
            rows.append((label: "Codex default", value: nil))
        }
        rows += models.map { (label: $0.displayName, value: Optional($0.id)) }
        if let pinned, !models.contains(where: { $0.id == pinned }) {
            let label = models.isEmpty ? pinned : "\(pinned) — not offered by this codex"
            rows.append((label: label, value: pinned))
        }
        return rows
    }

    /// The Codex effort picker's rows: the governing model's own effort list
    /// (per-model — 5.6 models add max/ultra), else the universal fallback four.
    static func codexEffortRows(governing: CodexModelInfo?) -> [(label: String, value: String)] {
        if let efforts = governing?.efforts, !efforts.isEmpty {
            return efforts.map { (label: $0.label, value: $0.value) }
        }
        return AgentProviderKind.codex.descriptor.efforts
    }
}
