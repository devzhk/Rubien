# Codex model & effort auto-discovery — design

- **Date:** 2026-07-10 (v2 — revised after codex review, gpt-5.6 config-default @ medium, job task-mrfdx04v-mykh1d: verdict SOUND-WITH-FIXES, all 10 findings dispositioned below)
- **Status:** Draft (awaiting user review; §3 contains one review-driven decision change to confirm)
- **Area:** Assistant chat sidebar (`Sources/Rubien/Assistant/`)
- **Related:** `2026-07-06-codex-app-server-phase3b-design.md`, `2026-07-04-assistant-chat-sidebar-design.md`
- **Memory:** `[[assistant-chat-sidebar]]`

## 1. Motivation

Codex shipped a new model generation (`gpt-5.6-sol` / `gpt-5.6-terra` / `gpt-5.6-luna`). The Codex backend descriptor in `AssistantModelOptions.swift` hardcodes an older, now-stale list (`gpt-5.5` / `gpt-5.5-pro`, default `gpt-5.5`) and a single static effort list (`low/medium/high/xhigh`).

Editing the hardcoded list doesn't fix the class of problem:

1. **Old-CLI safety.** Rubien wraps *whatever* `codex` binary the user has installed. Handing an older codex a slug it doesn't know risks a failed turn; a version→model table would need the exact codex version each model landed in, maintained every release.
2. **Effort is per-model.** The 5.6 models support `max` (and Sol/Terra `ultra`) — levels the static list omits. One flat effort list is already wrong.

**Direction:** don't predict — *ask the installed codex*, and where possible *send nothing and let codex resolve*.

## 2. Verified findings (all empirical, this machine, 2026-07-10)

### 2.1 `model/list` — present, local, un-auth-gated, version-faithful

Driving `codex app-server` with Rubien's own handshake (`initialize` → `initialized` → request), `model/list {}` returns one entry per model **that binary** knows:

| probe | result |
|---|---|
| codex **0.144.1**, real `~/.codex` | `gpt-5.5` *(isDefault)*, `gpt-5.6-sol` (efforts …`max,ultra`, defEffort `low`), `gpt-5.6-terra` (…`max,ultra`, defEffort `medium`), `gpt-5.6-luna` (…`max`, defEffort `medium`), `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex-spark` |
| codex **0.144.1**, **empty** `CODEX_HOME` | answers fine (⇒ **not auth-gated**); `gpt-5.6-sol` is `isDefault`; list composition differs (has `gpt-5.2`, no spark) |
| codex **0.142.5** (Phase-3b baseline; installed from npm) | **`model/list` works** and returns only its own generation: `gpt-5.5` *(isDefault)*, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex-spark` — no 5.6 |

Per-model fields we consume: `id`, `displayName`, `description`, `hidden`, `supportedReasoningEfforts[] {reasoningEffort, description}`, `defaultReasoningEffort`, `isDefault`. Response also carries `inputModalities`, `serviceTiers`, `availabilityNux`, `upgrade*` — captured by the decoder tolerantly, unused in v1.

Consequences: discovery is **safe on old CLIs** (they report their own list — verified on 0.142.5), and **`isDefault` is home-state volatile** (5.5 on this user's real home despite `config.toml` saying `gpt-5.6-terra`; sol on a fresh home) — it is a rollout artifact, **neither** the builtin constant **nor** the user's configured model. Do not build UX on it beyond cosmetics.

### 2.2 Omitting `model` on `thread/start` → codex resolves the user's own config

`thread/start` **without** a `model` key, against the real home, returned `"model": "gpt-5.6-terra"` — exactly the user's `config.toml` value — plus the resolved `reasoningEffort` ("max" here) and the rest of the effective posture. So:

- **"Use codex's default" = omit the param.** No TOML parsing, config/profile-faithful by construction.
- **The response reports what was resolved.** Rubien can read `model` back and display it ("Codex default (GPT-5.6-Terra)"). Today `CodexProvider` ignores these response fields.

### 2.3 Model is thread-scoped on the wire

`thread/start` (and `thread/resume`) carry `model`; `turn/start` carries only `effort` (`CodexAppServerProtocol.swift:386-411`, confirmed by review). Changing the model of a *running* Codex conversation has **no wire path today** — the current UI silently ignores a mid-conversation model change for Codex (pre-existing latent behavior; Claude honors it since every turn is a fresh spawn with `--model`).

### 2.4 Claude has no discovery surface — stays curated-static

`claude` 2.1.206: no model-list subcommand; `--model` help documents exactly the aliases Rubien already ships (`fable`, `opus`, `sonnet`). Nothing to discover; scraping help text would be fragile and add nothing. **Claude side unchanged.**

## 3. Decisions

- **Scope:** full auto-discovery for Codex (user, 2026-07-10).
- **Default model — REVISED (review finding #7 + §2.1/§2.2 evidence; supersedes the earlier "mirror `isDefault`" choice, pending user confirmation):** the default is a **"Codex default"** picker option = send no `model` at all; codex resolves its own config chain (profile → `config.toml` → builtin). The UI reads the resolved model back from the `thread/start` response and shows it. Rationale: `isDefault` proved volatile and config-blind (§2.1) — mirroring it would give this very user gpt-5.5 while their own codex runs terra. Omitting the param is the purest "reflect the installed codex" and is what the original "read ~/.codex config" option wanted, without the TOML-parsing fragility that disqualified it. **Label: "Codex default", deliberately NOT "Auto"** — "Auto" already means auto-approval in the composer's Ask/Auto switch (user caught the collision, 2026-07-10).
- **Effort:** stays **explicit-always** (every `turn/start` sends the effort shown in the picker — never omitted, so a `~/.codex` `xhigh`/`max` default can't sneak in; the known stall risk stays dodged by construction). Seeding: pref if set, else `medium` (universal — every observed model since 0.142 supports it). When the user explicitly picks a model, the effort control snaps to that model's `defaultReasoningEffort` (adjustable). No effort analogue of "Codex default" — avoids the unrepresentable-pin ambiguity (finding #3).

## 4. Design

### 4.1 `CodexModelCatalog` (discovery — picker UI only, never on the turn path)

A shared actor that fetches and memoizes `model/list` per resolved codex binary.

- `func catalog(binaryPath: String?, forceReload: Bool = false) async -> CodexCatalog` where `CodexCatalog = { models: [CodexModelInfo], fetchedOK: Bool }`.
- Internally: short-lived `codex app-server` spawn (reuse `SpawnedAgentProcess` + `CodexInvocation`), `initialize` → `initialized` → `model/list`, decode, shut down — the same bounded-probe pattern as `CodexProvider.isAvailable()`. Independent of any reader's live turn server; Settings and all windows share one result.
- **Correctness internals (finding #9):** memo keyed by *resolved* binary path; an **in-flight `Task` is stored and joined** so concurrent callers trigger one spawn; a **generation token** invalidates on `forceReload`/path change so a stale completion cannot repopulate an invalidated entry.
- Failure (spawn error, RPC unknown, timeout) → `{models: [], fetchedOK: false}`.
- **Crucially, no turn ever waits on the catalog.** Discovery only populates pickers. This removes the first-turn race (finding #2): a turn sent before the catalog resolves is already correct, because Codex default sends no model and a pinned slug is sent verbatim (§4.5).

### 4.2 Data model & decoding

```swift
struct CodexModelInfo {
    let id: String                 // slug for thread/start `model`
    let displayName: String
    let description: String?
    let efforts: [CodexEffortInfo] // supportedReasoningEfforts, server order
    let defaultEffort: String?     // defaultReasoningEffort
    let isDefault: Bool            // cosmetic only (badge/order) — see §2.1
    let hidden: Bool
}
struct CodexEffortInfo { let value: String; let label: String; let description: String? }
```

Decoder lives beside the existing `thread/list`/`thread/read` decoders in `CodexAppServerProtocol.swift`; tolerant of unknown fields/enum values. `hidden == true` entries are dropped by consumers. If a model's `supportedReasoningEfforts` is missing/empty, the effort picker for it shows the universal observed set `low/medium/high/xhigh` (finding #10: never *send* an effort the user didn't see selected; these four have been accepted by every codex generation back to 0.142).

### 4.3 Provider seam

```swift
// AgentProvider, default implementation returns nil
func availableModels(binaryPath: String?) async -> CodexCatalog?
```

Three unambiguous states: `nil` = backend has no discovery (Claude → static descriptor); `{fetchedOK: false}` = discovery attempted and failed (→ §4.7 degraded picker); `{fetchedOK: true, models}` = live list. `CodexProvider` delegates to `CodexModelCatalog`.

### 4.4 Preference & selection representation (findings #5, #8)

- `RubienPreferences.assistantCodexModel` becomes `String?` — **`nil`/absent = Codex default**. No sentinel string in the slug namespace; the "Codex default" row is a UI-layer tag that is never persisted as a slug and never sent on the wire. Existing stored values (e.g. `gpt-5.5`) keep meaning "pinned to that slug" — no migration write needed; a stale pin is handled at §4.5/§4.6.
- The getter returns the **raw** stored value; the current synchronous normalize-against-static-list call (`RubienPreferences.swift:264`) is deleted, not relocated — with omit-by-default there is nothing to normalize at read time. `assistantCodexEffort` likewise drops its static normalization (`RubienPreferences.swift:277`) and returns raw-or-`medium`: the old clamp would silently rewrite a user-chosen `max`/`ultra` (not in the static four) back to `medium`. Validity is now governed at the picker layer per model (§4.6).
- Sync call sites (`ReaderChatSession.defaults()`, Settings `@State` mirrors, `newConversation()`'s `defaultsProvider`) pass the optional through unchanged — none of them block on the catalog (finding #5 dissolved).

### 4.5 Turn path (deterministic, catalog-free)

- **Codex default (nil):** `thread/start`/`thread/resume` omit `model`. Parse the **resolved model** out of the response (§2.2) and publish it (`@Published var resolvedModel: String?`) → picker label shows "Codex default (GPT-5.6-Terra)".
- **Pinned slug:** sent verbatim. If the catalog has resolved and the pin is absent from it, the picker shows a warning row and the composer nudges to Codex default — but **the send is never silently rewritten** (finding #6: no invisible snapping; the user sees what will be sent).
- **Effort:** always explicit on `turn/start`, exactly the picker value.

### 4.6 Pickers

- **Sidebar model picker (Codex):** rows = `Codex default` [+ resolved-model suffix once known] + non-hidden catalog models (with `description` tooltips; `isDefault` may badge the matching row). Until the catalog resolves: `Codex default` + the current pinned value if any (kept visible/selectable — finding #6). No fallback model list exists at all (finding #1: the baked 5.6 trio is deleted, not just demoted — a discovery-failed codex is exactly the codex most likely to reject those slugs).
- **Effort picker (Codex):** sourced from the *governing* model's `efforts` — the pinned model, else the resolved codex-default model once a thread exists, else (catalog-less) the universal four. Picking a model snaps effort to that model's `defaultEffort`; an unsupported prior effort snaps with a visible change, never silently at send time.
- **Mid-conversation model change (finding #4):** for Codex, the model is thread-scoped (§2.3). Changing the model picker once the conversation has turns **starts a new conversation** (same semantics as the existing provider switch — `switchProvider` precedent), with the composer noting it. Claude keeps live per-turn switching. *(Implementation may probe whether `turn/start` accepts a `model` override and loosen this later; not assumed.)*
- **Settings ▸ Assistant (Codex default-model picker):** same rows as the sidebar (`Codex default` + catalog). Mirrors seed from raw prefs and **write only on user action — never persist a normalization during catalog load** (finding #6). The existing Recheck button also invalidates the catalog (`forceReload`).
- **Claude pickers:** unchanged, static `AssistantModelOptions` descriptor.

### 4.7 Degraded modes

| condition | behavior |
|---|---|
| `model/list` fails / absent (pre-0.142-era codex, spawn failure) | Picker = `Codex default` (+ pinned value if stored). It still works on *any* codex — it sends nothing. |
| Logged-out codex | `model/list` still answers (§2.1); turns fail at auth exactly as today (`isAvailable()` posture unchanged). |
| Pinned model unknown to the installed codex | Warning row in picker + nudge to Codex default; sent verbatim if the user insists (codex's own error surfaces as the turn failure notice). |
| Catalog resolves mid-conversation | Picker rows refresh in place; the running thread's model is untouched (§4.6 bullet 3). |

### 4.8 `AssistantModelOptions` after this change

The Codex descriptor keeps only `displayName`, `supportsSandbox`, and the universal effort list — used solely as the catalog-less effort *picker* fallback, never as a normalization gate. Its hardcoded model list and `defaultModel` are deleted; static `normalizedModel`/`normalizedEffort` for `.codex` are deleted (Claude keeps both). Doc comment updated to point at `CodexModelCatalog`.

## 5. Effort semantics note

`ultra` = "Maximum reasoning with automatic task delegation" (may spawn codex sub-agents); `xhigh+` historically stalls some turns (memory Risk #8). Mitigations unchanged: effort is always the explicit picker value (never inherited from `~/.codex`), defaults seed at `medium`, per-turn `turn/interrupt` + process-group kill exist. A user explicitly selecting `max`/`ultra` gets codex's native behavior — no gating in v1.

## 6. Testing

- **Codec:** `model/list` decode fixture (sanitized from the real 0.144.1 capture — include a `hidden` entry, `max`/`ultra` efforts, a missing-`supportedReasoningEfforts` entry, unknown fields). `thread/start` response decode now also extracts `model` (resolved-model readback) — fixture from §2.2 capture. (`CodexAppServerProtocolTests`)
- **Catalog actor:** single-spawn under concurrent callers (in-flight join), memo hit, `forceReload` + binary-path-change invalidation beats a stale completion (generation token), failure → `{fetchedOK:false}`. Extend `fake-codex-app-server.py` with a `model/list` reply + optional delay/error knobs.
- **Controller:** Codex default sends no model + publishes resolvedModel from the response; pinned slug sent verbatim; model change mid-conversation → newConversation for Codex only; effort snaps on explicit model pick; catalog resolution never mutates an active thread's model.
- **Prefs:** `assistantCodexModel` nil/raw round-trip and `assistantCodexEffort` raw-or-medium (update `RubienPreferencesTests:186/196/212` — neither getter normalizes statically anymore; a stored `ultra` survives the round-trip); Settings mirrors don't write during load.
- **Update static assertions** pinning the old list (`AssistantModelOptionsTests:28/40`, `ChatSessionControllerTests:400/418`) to the new shape (descriptor without models; nil-model paths).

## 7. Review disposition (codex task-mrfdx04v-mykh1d, all 10 findings)

| # | sev | finding (short) | disposition |
|---|---|---|---|
| 1 | High | 5.6-only fallback defeats old-CLI safety | **Fixed** — baked fallback list deleted; degraded mode = Codex default/omit (§4.6/§4.7) |
| 2 | High | async catalog races first turn | **Fixed** — catalog is picker-only; turn path never waits (§4.1/§4.5) |
| 3 | High | "pinned effort" unrepresentable | **Fixed** — effort stays explicit-always; snap-on-model-pick, no default-following effort state (§3) |
| 4 | High | mid-conversation model change is a silent no-op (thread-scoped) | **Fixed** — Codex model change ⇒ new conversation; turn/start override left as an implementation probe (§4.6) |
| 5 | Med | raw prefs break sync default paths | **Fixed** — omit-by-default makes sync paths pass-through; static normalize deleted, not relocated (§4.4) |
| 6 | Med | fallback→live swap can clobber a valid pin | **Fixed** — pin stays visible during load; writes only on user action; no silent rewrite at send (§4.5/§4.6) |
| 7 | Med | `isDefault` ≠ user's configured default | **Fixed & verified** — Codex default = omit param; `isDefault` demoted to cosmetics (§2.1/§2.2/§3) |
| 8 | Med | string sentinel collision | **Fixed** — Codex default = nil pref, UI-layer tag, never on wire (§4.4) |
| 9 | Med | actor memo races (in-flight, generation) | **Fixed** — spec'd internals (§4.1) |
| 10 | Low | static effort fallback reintroduces unsupported-effort risk | **Fixed** — universal observed four only, never auto-sent (§4.2) |

Codex's three pre-implementation verifications: (1) logged-out + old-CLI `model/list` — **done** (§2.1); (2) `isDefault`/`defaultReasoningEffort` vs config — **done** (§2.1/§2.2); (3) hidden-entry fixture + delayed-discovery/first-turn concurrency + Recheck races — **carried into §6 tests**.

## 8. Out of scope

- Claude model auto-discovery (no supported API — verified §2.4).
- Parsing `~/.codex` config TOML (obsoleted by omit-by-default).
- Service-tier / speed-tier / personality / `availabilityNux` surfacing (decoded tolerantly, unused).
- `turn/start` model override (probe during implementation; not assumed).
- Library writes (Phase 4).

## 9. Files touched (estimate)

- `Sources/Rubien/Assistant/CodexAppServerProtocol.swift` — `model/list` request/decoder; `thread/start` response `model` extraction.
- `Sources/Rubien/Assistant/CodexModelCatalog.swift` — **new** discovery actor.
- `Sources/Rubien/Assistant/CodexProvider.swift` — `availableModels`; omit-model when request has none; surface resolved model in an `AgentEvent` (or session-started payload).
- `Sources/Rubien/Assistant/AgentProvider.swift` — `availableModels` default; `CodexCatalog`/`CodexModelInfo` types; resolved-model event plumbing.
- `Sources/Rubien/Assistant/AssistantModelOptions.swift` — Codex descriptor slimmed (§4.8).
- `Sources/Rubien/Assistant/ChatSessionController.swift` — catalog fetch lifecycle, `resolvedModel`, default/pin selection state, Codex model-change ⇒ newConversation, effort snapping.
- `Sources/Rubien/Assistant/ChatSidebarView.swift` — dynamic rows, Codex-default row + resolved suffix, warning row.
- `Sources/Rubien/Assistant/ReaderChatSession.swift` — optional-model defaults pass-through.
- `Sources/Rubien/Views/RubienSettingsView.swift` — Codex-default row, no-write-during-load, Recheck → catalog invalidation.
- `Sources/Rubien/RubienPreferences.swift` — `assistantCodexModel: String?` raw semantics.
- Tests per §6; `Tests/RubienTests/Fixtures/fake-codex-app-server.py` + new fixtures.

## 10. Risks & implementation probes

- **`thread/resume` + Codex default:** confirm a resumed thread with no `model` param keeps its original model (expected: thread-scoped) — probe during implementation.
- **Resolved-model readback shape on older codex:** §2.2 field observed on 0.144.1; treat as optional (`resolvedModel` stays nil if absent — UI just shows "Codex default").
- **Unknown pinned slug on `thread/start`:** what error codex returns is unverified; the turn-failure notice path already renders provider errors, so worst case is a clear failed turn (never a hang — timeouts exist).
- **Picker churn:** catalog resolves within ~1s locally; rows refresh once per launch. Acceptable; no spinner needed beyond the existing composer affordances.
