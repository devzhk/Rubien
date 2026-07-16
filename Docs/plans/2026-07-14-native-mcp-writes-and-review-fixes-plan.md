# Native MCP Writes, Assistant Approval, and Review Fixes — Implementation Plan

**Date:** 2026-07-14
**Status:** Implemented and locally verified on macOS; Linux CI pending
**Base reviewed:** `unified-write-tools` at `f81e6d9b0aa7`
**Companion contracts:**

- `Docs/specs/2026-07-14-unified-write-tools-design.md`
- `Docs/specs/2026-07-04-assistant-chat-sidebar-design.md`
- `Docs/specs/2026-07-06-codex-app-server-phase3b-design.md`

## Outcome

Finish the unified-write branch rather than merely making its existing tests green:

1. Fix all five merge-review findings.
2. Mirror the final 27-tool npm contract into the native `rubien-cli mcp` server.
3. Make `mcp --read-only` a real restricted mode and plain `mcp` the full catalog.
4. Let the in-app assistant use the full catalog while keeping every library mutation behind the existing Ask/Auto approval UX for both Claude and Codex.
5. Prove denial, approval, read-silence, error propagation, sync timestamps, and catalog parity end to end before merging to `main`.

No database migration or CloudKit field change is required.

## Explicitly deferred next phase — personal MCP servers/connectors

This plan enables writes only for Rubien's bundled native MCP server. The roadmap item **Use my other MCP servers** remains a separate, default-off, security-sensitive follow-up. This phase must not broaden which personal connectors are loaded.

That next phase owns:

- the Settings toggle and user-facing disclosure of loaded servers;
- Claude config merging plus de-duplication of any user-configured Rubien server;
- Codex `loadUserTools` / connector enablement behavior;
- connector read/write approval policy, including the risk of incorrect third-party annotations;
- provider-specific Notion/other-connector approval and denial E2E tests.

Completing Rubien's own write-approval path first provides the verified approval foundation for that follow-up without combining two trust-boundary changes in one merge.

## Acceptance criteria

- Creating or renaming a property to an ASCII-all-digit name fails through every public path.
- Renaming a select option stamps `dateModified` on every changed synced `reference` / `propertyValue` row, with one captured transaction timestamp; true no-ops remain unstamped.
- Native `rubien_list_references` supports `view` exactly like the npm server and rejects `view` mixed with inline filters.
- Native MCP returns the CLI's complete structured stderr envelope verbatim.
- npm property/option row identifiers are JSON integers, not strings; only option values and Tags identities remain strings where specified.
- `rubien-cli mcp --read-only` advertises only tools classified read-only and cannot call a write tool.
- `rubien-cli mcp` advertises exactly the same 27 names, schemas, annotations, and argv behavior as `rubien-mcp-server` 0.3.0.
- In Assistant **Ask** mode, Rubien reads run without a card and every Rubien write waits for the native approval card. Denial performs no mutation; Allow performs it once.
- In Assistant **Auto** mode, writes run without a card only because the user explicitly selected Auto.
- An unknown future `mcp__rubien__*` tool is never silently approved; classification fails closed.
- Claude and Codex each pass an isolated-library write approval round trip. No production library is used by integration tests.
- macOS tests, npm tests, and Linux CI pass.

## Locked implementation decisions

### Catalog and modes

- Native full mode is the complete 27-tool catalog: 14 read-only tools and 13 write tools.
- `MCPTool` gains explicit annotations and a per-tool child timeout. `readOnlyHint` is always emitted (`true` or `false`), rather than relying on a client default.
- `MCPToolCatalog.allTools` is the full catalog. `readOnlyTools` is derived by filtering the same definitions, so the two modes cannot drift.
- Default child timeout remains 60 seconds; `rubien_create_reference` and `rubien_download_pdf` get 300 seconds, matching npm.
- The CLI remains the domain-validation/routing source of truth. Native and npm wrappers enforce their advertised JSON schemas (including bounds and exact integer handling) before constructing argv.

### Security classification

- Put the canonical native tool access classification in a Foundation-only `RubienCore` type (for example `RubienMCPToolPolicy`) usable by both the CLI and app targets.
- The CLI catalog must exhaustively match that policy. The assistant's silent-read decision uses the same read-only name set.
- A Rubien MCP tool is silent only when its exact bare name is in the read-only set. The current namespace-wide `mcp__rubien__*` auto-approval is removed.
- Unknown Rubien tool names are denied without execution in both Ask and Auto modes.
  This is deliberate fail-closed behavior: an unclassified future mutation cannot
  inherit either read silence or Auto approval.

### Approval ownership

- Keep the accepted soft-boundary architecture: provider approval channels own user interaction; do not add a second server-side approval socket unless the Codex gate below proves the provider cannot surface MCP approvals.
- Claude continues through `--permission-prompt-tool stdio` and the existing `can_use_tool` response path.
- Codex continues through `app-server`, with `approvalPolicy: "on-request"` and `approvalsReviewer: "user"`. Its injected Rubien MCP config additionally pins `default_tools_approval_mode = "writes"` so non-read-only tools prompt, and sets an outer tool timeout above the native 300-second child timeout.
- Codex sandbox choice remains independent. MCP writes are governed by tool registration and approval, not assumed to be contained by `read-only` sandbox mode.
- Plain `rubien-cli mcp` is intentionally a full-power local server. Callers wanting a restricted external server must pass `--read-only`.

## Phase 1 — Correctness blockers in Core and CLI

Commit as one focused correctness change.

### 1.1 Property-name validation

- Add a black-box CLI regression proving `properties --create --name 12345` fails.
- Cover the same rule on property rename.
- Change the real CLI create path in `Sources/RubienCLI/RubienCLI.swift` to call the validated RubienCore creation entry point instead of constructing and saving `PropertyDefinition` directly.
- Preserve DTO output and sort-order semantics.

### 1.2 Option-rename sync timestamps

- In `updatePropertyOption`, capture one `now` for the transaction.
- Stamp `Reference.dateModified` when the built-in Status value changes.
- Stamp `PropertyValue.dateModified` for custom single-select and multi-select rows before update.
- Preserve no-op behavior: recoloring or renaming to the existing value must not dirty unrelated rows.
- Add Core tests for Status, custom single-select, and custom multi-select, asserting both value and timestamp changes. Add a no-op assertion and dirty-queue coverage where practical.

**Gate:** `swift build --product rubien-cli`, relevant `RubienCoreTests`, and the property CLI tests.

## Phase 2 — Existing catalog-contract repairs

Commit before broad native-catalog expansion so each defect stays reviewable.

### 2.1 Native saved-view passthrough

- Add integer `view` to native `rubien_list_references` and emit `--view <id>`.
- Match npm's mutual-exclusion behavior between `view` and every inline filter/sort argument.
- Add native MCP black-box tests for saved-view results and conflict failure.

### 2.2 Structured native errors

- Replace `extractCLIError`'s `{"error": ...}` extraction with trimmed raw stderr preservation.
- Empty stderr alone falls back to `rubien-cli invocation failed`.
- Once `rubien_list_properties` lands in Phase 3, add an exact black-box assertion for a fabricated or naturally produced `error/ids/names` envelope. The test must compare the complete JSON text/object, not only `error`.

### 2.3 Numeric npm property identifiers

- Change `ids`, property `id`, and `propertyId` schemas in `mcp-server/src/tools/properties.ts` to integer Zod schemas.
- Convert numbers to strings only when constructing CLI argv.
- Keep `option`, `value`, `replaceWith`, and Tags values as strings per the contract.
- Update catalog/argv tests to accept integers and reject digit strings.

**Gate:** `swift test --filter RubienCLITests`, `npm run build`, and `npm test`.

## Phase 3 — Full native 27-tool catalog

Split mechanics and tool porting into two commits if the diff becomes difficult to review.

### 3.1 Catalog mechanics

- Add the shared `RubienMCPToolPolicy` access table in `RubienCore`.
- Extend `MCPTool` with:
  - access/read-only classification;
  - `destructiveHint` and `idempotentHint` where applicable;
  - per-tool timeout;
  - existing image-result shaping.
- Emit MCP annotations matching npm, including destructive delete tools, non-destructive creation, and explicit `readOnlyHint` values.
- Make `MCPCommand.run()` choose `readOnlyTools` only when `--read-only` is present; otherwise use `allTools`.
- Update command help so it no longer claims writes are unsupported.

### 3.2 Port the missing tools

Mirror the npm definitions, schemas, descriptions, argv, annotations, and timeouts for:

- Reads missing from native today: `list_properties`, `list_views`, `cite`, `list_styles`, `export`, `get_sync_status`.
- Writes: `create/update/delete_reference`, `create/update/delete_property`, `create/update/delete_option`, `create/update/delete_view`, and `download_pdf`.

Use small private argv/schema helpers rather than copying flag coercion logic repeatedly. Keep all cross-argument and domain validation in the CLI.

### 3.3 Parity tests

- Native full mode advertises exactly 27 names; read-only mode advertises exactly the 14 definitions with `readOnlyHint: true`.
- A write call against `--read-only` returns unknown-tool and cannot mutate the isolated DB.
- Full-mode argv tests cover every new tool, both Boolean branches, repeatable arrays, JSON-valued fields, and the 300-second routes.
- Add a normalized catalog contract fixture or equivalent cross-runtime assertion for names, input schemas, required fields, and annotations. Both Swift and npm tests consume it so updating only one catalog fails CI.
- Add representative full-mode black-box mutations for reference, property/option, and view families, plus exact structured-error preservation.
- Preserve Linux compilation and deterministic failure behavior for platform-specific sync operations.

**Gate:** build the CLI first, run all `RubienCLITests`, then npm build/tests and the catalog parity check.

## Phase 4 — Assistant full mode and approval policy

Do not enable a production-library write until the provider-specific approval gates below pass against an isolated `RUBIEN_LIBRARY_ROOT`.

### 4.1 Provider invocation

- Change `MCPContentChannel` from a read-only content channel to the full Rubien library channel and launch `rubien-cli mcp` without `--read-only` for Claude.
- Change Codex's injected `mcp_servers.rubien.args` likewise.
- Pin Codex's Rubien server to `default_tools_approval_mode = "writes"` and an outer timeout safely above 300 seconds, using supported Codex config keys.
- Keep `approvalPolicy: "on-request"` and `approvalsReviewer: "user"` explicit on new and resumed threads.
- Update comments, naming, Settings help, and invocation tests that currently pin `["mcp", "--read-only"]`.

### 4.2 Name-based silent reads

- Replace the prefix-wide `isSilentReadTool` behavior with exact lookup through `RubienMCPToolPolicy`.
- Continue silently approving Claude's known read/search built-ins.
- Add table-driven tests covering every native tool: all 14 reads silent, all 13 writes prompt, and unknown Rubien names prompt.
- Preserve FIFO approval behavior, Allow Once, Allow for Conversation, Deny, stale-response rejection, and turn/new-conversation cleanup.

### 4.3 Claude approval gate

- Extend the fake-Claude fixture with `can_use_tool` requests for one read and one Rubien write.
- Assert the read is answered automatically, while the write remains blocked until the card response.
- Assert Deny sends the interrupting control response and leaves the isolated DB unchanged.
- Assert Allow echoes the original input and produces exactly one mutation.
- Run one real Claude CLI smoke test against a disposable library before declaring the phase complete.

### 4.4 Codex approval gate — hard go/no-go

- Generate the installed app-server schema and capture a real side-effecting Rubien MCP call with `default_tools_approval_mode = "writes"`.
- Record the exact server-request method, params, decision response, and item lifecycle in a committed fixture. Do not infer MCP approval framing from shell/file approval fixtures.
- Update `CodexAppServerProtocol` only to the verified shape, preserving raw JSON-RPC id types and deny/cancel fallback rules.
- Extend the fake app-server to block on that MCP approval and verify Deny/no-mutation and Allow/one-mutation.
- Run a real Codex app-server smoke test against a disposable library.
- **Go/no-go:** if the installed supported app-server does not surface an interactive MCP approval request, keep Codex on `--read-only` and stop this phase. Design and review a server-side approval broker before exposing Codex writes; never silently rely on sandboxing or annotations alone.

The current native approval card is reused; no visual redesign is required. Improve the summary only if the captured provider payload does not identify the operation and target clearly enough.

**Gate:** `swift test --filter 'RubienTests\..*'` plus the two disposable-library provider smokes.

## Phase 5 — Documentation, independent review, and merge gate

### Documentation

- Update `Docs/CLI-Reference.md` for full versus `--read-only` native MCP modes and all 27 tools.
- Update the assistant master spec to mark Phase 4 complete and replace the namespace-wide silent-read assumption.
- Add a superseding note to the unified-write spec's native-write non-goal rather than rewriting its historical decision context.
- Update README/help text that describes the native channel as read-only.
- Document that external callers use `--read-only` for a non-mutating server, while the in-app full server relies on Ask/Auto provider approvals.

### Full verification

Run from a clean tree:

```bash
swift build
swift test --filter RubienCoreTests
swift test --filter RubienCLITests
swift test --filter 'RubienTests\..*'
swift test --filter RubienSyncTests
swift test --filter RubienPDFKitTests
cd mcp-server && npm run build && npm test
git diff --check main...HEAD
```

Also require Linux CI because native MCP and portable assistant policy code compile there.

### Security/E2E matrix

For both providers with a disposable library:

| Mode/action | Expected result |
|---|---|
| Ask + read | Runs silently; no card |
| Ask + create/update/delete | Card appears before mutation |
| Ask + Deny | No DB/file mutation; denied chip |
| Ask + Allow Once | Exactly one mutation |
| Ask + Allow for Conversation | Same-tool grant follows existing conversation semantics |
| Auto + write | Runs without card by explicit user choice |
| Unknown Rubien tool approval | Denied without execution |
| `mcp --read-only` + write call | Unknown tool; no mutation |
| Structured CLI failure | Complete envelope reaches the agent |

Finally follow `AGENTS.md`: independent `codex-rescue` review of the uncommitted diff, `/simplify` reuse/quality/efficiency sweep, decide findings explicitly, rerun the full gate, then merge locally by fast-forward only if `main` is still the branch ancestor.

## Verification result

Local macOS verification completed on 2026-07-14:

- All five Swift test targets passed independently: 1,718 tests total, 5 skipped, 0 failures (`RubienCoreTests` 759; `RubienCLITests` 169; `RubienTests` 617; `RubienSyncTests` 153; `RubienPDFKitTests` 20).
- The final native MCP suite passed 28/28, including every added route, full/read-only catalog behavior, schema enforcement, output shaping, and raw scalar/array integer edge cases.
- `npm run build` passed; npm/Vitest passed 77/77, including exact native/npm schemas, annotations, and representative JSON/BibTeX/RIS output parity.
- A real Claude 2.1.210 disposable-library smoke surfaced the write approval request and created exactly one row only after the existing control response approved it.
- The installed Codex 0.144 app-server capture established the real `mcpServer/elicitation/request` framing and decline response. Provider tests using that captured shape prove decline/no mutation and accept/exactly-one mutation against an isolated library.
- Three independent review passes rechecked correctness, parity, process limits, and integer decoding after fixes and reported no remaining merge blockers.
- `git diff --check` passes.

Two monolithic `swift test` attempts stopped making progress late in the combined process at `UpdateControllerTests`; the same complete `RubienTests` target (including those tests) passes in isolation. The documented per-target gate above is green. Linux CI remains required before merging because it is the only verification of the portable app subset and Linux MCP build.

## Suggested commit sequence

1. `fix(core): close unified-write correctness findings`
2. `fix(mcp): repair saved-view errors and numeric id contracts`
3. `feat(mcp): add the full native 27-tool catalog`
4. `feat(assistant): gate native library writes through approvals`
5. `docs(test): complete phase-4 contracts and merge verification`

Each commit must build and pass its directly affected suites; do not defer all validation to the final commit.
