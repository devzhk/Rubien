# Document Card Presentation Plan

**Goal:** Treat papers, web articles, blog posts, and other saved or external sources as equal Rubien documents, and give the assistant one native-card mechanism whenever it intentionally points the user to something they can open.

## Contract

- Rename the app-private MCP capability to `rubien_present_document_cards`. This is a beta-only clean break; the old `rubien_present_papers` name is not advertised or accepted.
- One call contains every openable document intentionally referenced in the response, whether it is recommended, compared, cited as an example, or surfaced as a result.
- Each response references at most 10 openable documents. When the user asks for more, the assistant presents the 10 most relevant and offers another batch.
- Passing/incidental mentions do not require cards. The trigger is an intentional reference that should give the user an open action.
- Saved library documents use `referenceId`. External web documents use `url` and `title`, plus `authors` and `year` when known.
- Native cards replace Markdown links as the navigation affordance for those documents. Explanations and reasons remain in prose and never enter tool arguments.
- Both Home and Reader built-in prompts carry the same document-card rule. Reader conversations still retain their current-reference context.

## Implementation

1. Generalize the app-private MCP wire name, description, and user-facing wording. Keep the established internal transcript types and role names unchanged; they are implementation details outside this focused contract rename.
2. Generalize the Home prompt beyond papers and add the card rule to both prompt surfaces.
3. Update the app parser/policy contract, CLI integration coverage, focused assistant tests, and design references.
4. Build and run the focused app and CLI suites, complete the repository review workflow, then relaunch the worktree app.

## Verification

- `swift build`
- `swift test --filter RubienTests.AssistantContextTests`
- `swift test --filter RubienTests.ChatPaperPresentationTests`
- `swift test --filter RubienTests.ChatSessionControllerTests`
- `swift test --filter RubienCLITests.MCPServerTests`
