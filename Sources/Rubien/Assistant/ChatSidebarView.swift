#if os(macOS)
import SwiftUI

// MARK: - Chat sidebar (Phase 2c)
//
// The per-reader-window Assistant sidebar: header (provider + Web toggle + session
// menu), the Phase-1 transcript renderer, a NATIVE approval card (outside the
// sanitized-HTML trust zone, §5.3), and the composer. Driven by `ChatSessionController`
// (state + actions); the concrete `ChatTranscriptController` is passed in for the
// `ChatTranscriptView`.

struct ChatSidebarView: View {
    @ObservedObject var session: ChatSessionController
    let renderer: ChatTranscriptController

    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 300)
        .task { await session.recheckAvailability() }
        .onAppear { renderer.setTheme(colorScheme == .dark ? .dark : .light) }
        .onChange(of: colorScheme) { _, new in renderer.setTheme(new == .dark ? .dark : .light) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Label(session.providerKind == .claude ? "Claude" : "Codex", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
            Spacer()
            webToggle
            sessionMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var webToggle: some View {
        Button {
            session.webAccess.toggle()
        } label: {
            Image(systemName: session.webAccess ? "globe" : "globe.badge.chevron.backward")
                .foregroundStyle(session.webAccess ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help(session.webAccess ? "Web access on — the agent can search/fetch the web" : "Web access off")
    }

    private var sessionMenu: some View {
        Menu {
            Button("New Conversation") { session.newConversation(); draft = "" }
            Button("History…") {}.disabled(true)  // 2c-6
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let availability = session.availability, !availability.isInstalled {
            emptyState(availability)
        } else {
            ChatTranscriptView(controller: renderer)
            if let approval = session.pendingApproval {
                approvalCard(approval)
            }
            if let selection = session.stagedSelection {
                selectionChip(selection)
            }
            composer
        }
    }

    // MARK: Empty state (§4.5)

    private func emptyState(_ availability: AgentAvailability) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Assistant unavailable")
                .font(.headline)
            Text(availability.unavailableReason ?? "The Claude Code CLI wasn’t found.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Install Claude Code and run `claude login` in Terminal, then recheck. You can also set the binary path in Settings ▸ Assistant.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Recheck") { Task { await session.recheckAvailability() } }
                .controlSize(.large)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Approval card (§5.3 — native, not sanitized HTML)

    private func approvalCard(_ approval: ChatSessionController.PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised")
                Text("Allow ") + Text(approval.toolName).bold() + Text("?")
            }
            .font(.subheadline)
            if !approval.summary.isEmpty {
                Text(approval.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            HStack(spacing: 8) {
                Button("Allow Once") { session.respond(to: approval, .allowOnce) }
                    .keyboardShortcut(.defaultAction)
                Button("Allow for Conversation") { session.respond(to: approval, .allowForConversation) }
                Spacer()
                Button("Deny", role: .destructive) { session.respond(to: approval, .deny) }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private func selectionChip(_ selection: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "quote.opening").foregroundStyle(.secondary)
            Text(selection)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button { session.stagedSelection = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                composerField
                composerButton
            }
            statusLine
        }
        .padding(10)
    }

    private var composerField: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEmpty {
                Text("Ask about this document…")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $draft)
                .focused($composerFocused)
                .font(.body)
                .frame(minHeight: 34, maxHeight: 120)
                .scrollContentBackground(.hidden)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }

    @ViewBuilder private var composerButton: some View {
        if session.isResponding {
            Button { session.stop() } label: {
                Image(systemName: "stop.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .help("Stop")
        } else {
            Button { sendDraft() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send (⌘↩)")
        }
    }

    @ViewBuilder private var statusLine: some View {
        if session.busyElsewhere {
            statusText("Busy in another window", systemImage: "exclamationmark.triangle")
        } else if let status = session.statusText {
            statusText(status, systemImage: "ellipsis")
        }
    }

    private func statusText(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        session.send(text)
        composerFocused = true
    }
}
#endif
