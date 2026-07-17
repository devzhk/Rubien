# Custom Assistant Prompts Plan

**Goal:** Let users see and customize the complete seed prompts for Home and reader assistant conversations, with an obvious way to restore Rubien's defaults.

**Behavior:**

- Settings → Assistant exposes multiline prompt editors for Home and reader conversations. Each editor shows the current effective prompt, including Rubien's default when no override is stored.
- A persistent **Reset to Default** button restores the corresponding current built-in prompt and clears the stored override.
- Each prompt is bounded to 8,000 characters / 32 KB and strips embedded NULs before provider dispatch.
- The reader default uses a visible `{{reference}}` placeholder. Rubien replaces it with the sanitized reference ID, title, and authors when a conversation starts; if the user removes the placeholder, Rubien appends the current reference context so reader conversations remain scoped.
- Prompt overrides are local, per-device Assistant defaults, matching the existing model, tools, approval, and workspace preferences.
- A conversation snapshots its prompt when it starts. Settings changes affect newly opened conversations, **New conversation**, and provider switches; live and resumed conversations retain their original provider context.

## Implementation

1. Add optional Home and reader prompt-override accessors to `RubienPreferences`; storing the current default clears the override.
2. Extend `AssistantContext` with visible default prompts, bounded override selection, and reader-placeholder rendering.
3. Carry the appropriate surface-specific override through `AssistantConversationDefaults`, `ReaderChatSession`, and `ChatSessionController` so every fresh-conversation entry point stays aligned.
4. Add mirrored full-prompt editors and persistent reset actions to Settings → Assistant.
5. Add focused tests for default display values, preference persistence, prompt rendering, first-turn delivery, and adopting changed prompts on **New conversation**.

## Verification

- `swift test --filter RubienTests.AssistantContextTests`
- `swift test --filter RubienTests.RubienPreferencesTests`
- `swift test --filter RubienTests.ChatSessionControllerTests`
- `swift build`
- Independent diff review plus the required reuse, quality, and efficiency simplification passes; address accepted findings and rerun relevant checks.
