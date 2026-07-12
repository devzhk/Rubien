#if os(macOS)
import Foundation
import RubienCore

// MARK: - Production reader-session factory (Phase 2c)
//
// The one place a reader window builds its live assistant session from the current
// Assistant settings (Phase 2c-5). Both readers go through here — the web reader
// today, the PDF reader in Phase 3 — so the production wiring (Claude + the bundled
// read-only MCP content channel + the binary-path override + working folder + the
// model/effort/web/approval defaults) lives in exactly one spot and can't drift.
//
// Tests and the DEBUG harness deliberately DON'T use this: they construct
// `ChatSessionController` directly with a mock provider. This factory is the
// production composition root only.

enum ReaderChatSession {
    /// Build a fully-configured session for a reader window from the user's Assistant
    /// settings. `transcript` is the reader's own renderer (also held as a separate
    /// `@StateObject`), so it's injected rather than created here.
    @MainActor
    static func make(
        reference: Reference,
        transcript: ChatTranscriptController,
        database: AppDatabase = .shared
    ) -> ChatSessionController {
        // The read-only MCP content channel (Phase 2b) is shared by both backends, so
        // whichever runtime is active reads THIS document through Rubien's own tools.
        let contentChannel = MCPContentChannel.resolveBundled()

        // Builds a fresh provider for a backend kind — used at construction and by
        // the composer's provider picker (`switchProvider`). Each provider takes its
        // OWN binary-path override (the `claude` vs `codex` executables differ).
        let providerFactory: (AgentProviderKind) -> any AgentProvider = { kind in
            switch kind {
            case .claude:
                return ClaudeCodeProvider(
                    executableOverride: RubienPreferences.assistantBinaryPath,
                    contentChannel: contentChannel)
            case .codex:
                return CodexProvider(
                    executableOverride: RubienPreferences.assistantCodexBinaryPath,
                    contentChannel: contentChannel)
            }
        }

        // The live pref snapshot for a backend, re-read on every fresh conversation so
        // a changed default is adopted on "New conversation"/provider switch without
        // reopening the window. Model/effort/sandbox are backend-specific; web +
        // approvals are shared across backends.
        let defaultsProvider: (AgentProviderKind) -> AssistantConversationDefaults = { kind in
            switch kind {
            case .claude:
                return AssistantConversationDefaults(
                    model: RubienPreferences.assistantModel,
                    effort: RubienPreferences.assistantEffort,
                    webAccess: RubienPreferences.assistantWebAccess,
                    autoApprove: RubienPreferences.assistantAutoApprove)
            case .codex:
                return AssistantConversationDefaults(
                    model: RubienPreferences.assistantCodexModel,
                    effort: RubienPreferences.assistantCodexEffort,
                    webAccess: RubienPreferences.assistantWebAccess,
                    autoApprove: RubienPreferences.assistantAutoApprove,
                    codexSandbox: RubienPreferences.assistantCodexSandbox)
            }
        }

        let initialKind = RubienPreferences.assistantProvider
        let initial = defaultsProvider(initialKind)
        return ChatSessionController(
            provider: providerFactory(initialKind),
            transcript: transcript,
            reference: ChatReference(
                id: reference.id ?? 0,
                title: reference.title,
                authors: reference.authors.displayString),
            workspaceURL: AssistantContext.ensureWorkspace(RubienPreferences.assistantWorkspaceURL),
            webAccess: initial.webAccess,
            modelOverride: initial.model,
            effortOverride: initial.effort,
            autoApprove: initial.autoApprove,
            codexSandbox: initial.codexSandbox,
            providerFactory: providerFactory,
            defaultsProvider: defaultsProvider,
            mentionSearch: { query, limit in
                let candidates = (try? await database.searchReferenceMentions(
                    query: query,
                    limit: limit
                )) ?? []
                return candidates.map {
                    ChatReference(
                        id: $0.id,
                        title: $0.title,
                        authors: $0.authors.displayString,
                        referenceType: $0.referenceType.rawValue,
                        doi: $0.doi
                    )
                }
            })
    }
}
#endif
