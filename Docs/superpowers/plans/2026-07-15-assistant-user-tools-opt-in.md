# Assistant User Tools Opt-In Plan

**Goal:** Add a default-off Assistant setting that lets new Rubien conversations use the selected provider's normal connected apps, plugins, settings, and user-configured MCP servers while retaining Rubien's own MCP server, approval transport, and minimal child-process environment.

**Behavior:**

- Off remains the shipped posture: Claude loads only Rubien's explicit MCP config; Codex disables its built-in Apps connector surface.
- On restores each runtime's normal user tool environment:
  - Claude loads its ordinary user/project/local settings and plugins, merges the explicit Rubien MCP config, and does not use strict MCP isolation.
  - Codex omits `--disable apps`; its existing `~/.codex` MCP configuration and connected Apps load alongside Rubien's injected server.
- The choice is a default for new conversations. An already-open conversation keeps its current posture; choosing **New conversation** re-reads the preference.
- History resumes use the pane's current posture because provider session stores do not contain Rubien's setting snapshot.
- Changing the posture forces Codex's long-lived app-server to respawn because the Apps feature flag is fixed at process launch.
- Rubien keeps its explicit approval transport and per-turn Codex approval/sandbox settings in both modes. User-provided tool annotations and permission rules remain part of the opted-in provider environment, so the Settings copy must disclose the external-data risk.
- The opt-in restores provider configuration, not Rubien's launching shell environment. Agent-configured credentials still load; ambient API-key variables, `SSH_AUTH_SOCK`, and custom `PATH` entries remain excluded.
- Rubien replaces a configured server named exactly `rubien`; an aliased Rubien server cannot be reliably discovered and may remain alongside it.

## Implementation

1. Add `RubienPreferences.assistantLoadUserTools`, defaulting to `false`, and expose it as a mirrored toggle under Assistant defaults.
2. Carry the preference through `AssistantConversationDefaults`, `ChatSessionController`, and `AgentTurnRequest` so it is snapshotted per conversation and re-read on **New conversation** / provider switch.
3. Update Claude invocation construction:
   - isolated: preserve `--setting-sources ''` and `--strict-mcp-config`;
   - opted in: omit both isolation flags while keeping `--mcp-config <rubien>` and `--permission-prompt-tool stdio`.
4. Update Codex server construction to pass the request's `loadUserTools` value into `CodexInvocation`; record it in the live server and respawn when it changes.
5. Add tests for preference defaults/round-trip, controller snapshot/reset behavior, Claude argv in both postures, and Codex argv/respawn behavior.

## Verification

- `swift test --filter RubienTests.RubienPreferencesTests`
- `swift test --filter RubienTests.MCPContentChannelTests`
- `swift test --filter RubienTests.ClaudeCodeProviderTests`
- `swift test --filter RubienTests.CodexProviderTests`
- `swift test --filter RubienTests.ChatSessionControllerTests`
- `swift build`
- `swift test`
- Independent diff review plus the required reuse, quality, and efficiency simplification passes; fix accepted findings and rerun build/tests.
