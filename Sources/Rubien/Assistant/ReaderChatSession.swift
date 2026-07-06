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
    static func make(reference: Reference, transcript: ChatTranscriptController) -> ChatSessionController {
        ChatSessionController(
            provider: ClaudeCodeProvider(
                executableOverride: RubienPreferences.assistantBinaryPath,
                contentChannel: MCPContentChannel.resolveBundled()),
            transcript: transcript,
            reference: ChatReference(
                id: reference.id ?? 0,
                title: reference.title,
                authors: reference.authors.displayString),
            workspaceURL: AssistantContext.ensureWorkspace(RubienPreferences.assistantWorkspaceURL),
            webAccess: RubienPreferences.assistantWebAccess,
            modelOverride: RubienPreferences.assistantModel,
            effortOverride: RubienPreferences.assistantEffort,
            autoApprove: RubienPreferences.assistantAutoApprove)
    }
}
#endif
