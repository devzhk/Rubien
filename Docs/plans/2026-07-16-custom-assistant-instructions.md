# Custom Assistant Instructions Plan

**Goal:** Let users add separate instructions for Home and reader assistant conversations without replacing Rubien's built-in tool, presentation, reference-context, or untrusted-content requirements.

**Behavior:**

- Settings → Assistant exposes multiline custom-instruction fields for Home and reader conversations.
- Empty or whitespace-only text means no customization and restores the built-in behavior.
- Each field is bounded to 8,000 characters / 32 KB and strips embedded NULs before provider dispatch.
- Rubien appends the selected customization to its fixed context seed with an explicit statement that the built-in Rubien requirements take precedence.
- Instructions are local, per-device Assistant defaults, matching the existing model, tools, approval, and workspace preferences.
- A conversation snapshots its instructions when it starts. Settings changes affect newly opened conversations, **New conversation**, and provider switches; live and resumed conversations retain their original provider context.

## Implementation

1. Add optional Home and reader custom-instruction accessors to `RubienPreferences` with empty-value clearing semantics.
2. Extend `AssistantContext` with pure prompt composition that preserves each built-in seed and appends non-empty user instructions.
3. Carry the appropriate surface-specific instruction through `AssistantConversationDefaults`, `ReaderChatSession`, and `ChatSessionController` so every fresh-conversation entry point stays aligned.
4. Add mirrored multiline controls and reset actions to Settings → Assistant.
5. Add focused tests for preference persistence, prompt composition, first-turn delivery, and adopting changed instructions on **New conversation**.

## Verification

- `swift test --filter RubienTests.AssistantContextTests`
- `swift test --filter RubienTests.RubienPreferencesTests`
- `swift test --filter RubienTests.ChatSessionControllerTests`
- `swift build`
- Independent diff review plus the required reuse, quality, and efficiency simplification passes; address accepted findings and rerun relevant checks.
