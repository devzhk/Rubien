#if os(macOS)
import SwiftUI

// MARK: - Chat sidebar (Phase 2c)
//
// The per-reader-window Assistant sidebar: header (provider + Web toggle + session
// controls), the Phase-1 transcript renderer, a NATIVE approval card (outside the
// sanitized-HTML trust zone, §5.3), and the composer. Driven by `ChatSessionController`
// (state + actions); the concrete `ChatTranscriptController` is passed in for the
// `ChatTranscriptView`.
//
// Design language matches the annotation popovers (AnnotationPopovers.swift): 13 pt
// semibold icons at `primary.opacity(0.80)` in 28 pt hover buttons, 0.5 pt hairline
// separators, accent-filled continuous capsules/circles with white glyphs for primary
// actions — but theme-adaptive (`Color.primary`-based tints, no forced light mode),
// since this is a persistent pane, not a floating light-glass popover.

struct ChatSidebarView: View {
    @ObservedObject var session: ChatSessionController
    let renderer: ChatTranscriptController
    /// Collapses the sidebar (the reader wires this to its pane toggle; 2c-3).
    /// nil hides the close button.
    var onClose: (() -> Void)? = nil

    @State private var draft = ""
    @State private var showingHistory = false
    @State private var modelMenuHovered = false
    @State private var providerMenuHovered = false
    @State private var plusMenuHovered = false
    @State private var approvalMenuHovered = false
    @FocusState private var composerFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            content
        }
        .frame(minWidth: 300)
        .task { await session.recheckAvailability() }
        .onAppear {
            renderer.setTheme(colorScheme == .dark ? .dark : .light)
            // Re-mounting the pane created a fresh (empty) WebView — restore the
            // conversation from the controller's in-memory render log.
            session.replayTranscript()
            // Opened via Selection→Ask (a selection was staged before the pane
            // mounted): drop the caret into the composer so the user can type.
            if session.stagedSelection != nil { focusComposerSoon() }
        }
        .onChange(of: colorScheme) { _, new in renderer.setTheme(new == .dark ? .dark : .light) }
        // Selection→Ask while the pane is already open — each Ask bumps the token
        // (even re-Asking the same passage), which focuses the composer (§5.4).
        .onChange(of: session.composerFocusRequest) { _, _ in focusComposerSoon() }
    }

    // MARK: Header (popover-toolbar idiom)

    private var header: some View {
        HStack(spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.80))
                Text("Assistant")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.leading, 4)
            Spacer()
            iconButton("square.and.pencil", help: "New conversation") {
                session.newConversation()
                draft = ""
            }
            iconButton("clock.arrow.circlepath", help: "History — resume a past conversation") {
                showingHistory = true
            }
            .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                ChatHistoryPopover(session: session) {
                    showingHistory = false
                    draft = ""
                }
            }
            if let onClose {
                iconButton("xmark", help: "Close the assistant sidebar") { onClose() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .focusEffectDisabled()  // no focus ring/boundary on the toolbar-style controls
    }

    /// The composer's "+" tools menu (Claude-style): future attachment features up
    /// top, then the Web-search toggle with a checkmark reflecting `webAccess`.
    private var plusMenu: some View {
        Menu {
            Button {} label: {
                Label {
                    Text("Add files or photos")
                } icon: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14, weight: .regular))
                }
            }
            .disabled(true)  // attachments arrive in a later phase
            Divider()
            Toggle(isOn: $session.webAccess) {
                Label {
                    Text("Web search")
                } icon: {
                    // The clean thin wireframe globe (Claude's style) — pin the
                    // regular weight so the menu doesn't render it heavier.
                    Image(systemName: "globe")
                        .font(.system(size: 14, weight: .regular))
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.70))
                .frame(width: 27, height: 27)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(plusMenuHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { plusMenuHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: plusMenuHovered)
        .help("Tools — web search" + (session.webAccess ? " (on)" : " (off)"))
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.70))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HeaderControlButtonStyle())
        .help(help)
    }

    /// 0.5 pt hairline rule, the popovers' separator idiom (theme-adaptive tint).
    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let availability = session.availability, !availability.isInstalled {
            emptyState(availability)
        } else {
            ZStack {
                // Kept in the hierarchy while covered so the WebView is loaded
                // and ready the moment the first turn starts streaming.
                ChatTranscriptView(controller: renderer)
                if !session.hasMessages {
                    startPage
                }
            }
            if let approval = session.pendingApproval {
                approvalCard(approval)
            }
            if let selection = session.stagedSelection {
                selectionChip(selection)
            }
            composer
        }
    }

    // MARK: Quick-start page (fresh conversation)

    /// The Rubien icon, from the module bundle (`NSApp.applicationIconImage` is the
    /// generic AppKit icon in a `swift run` dev build — no Info.plist icon there).
    private static let startPageIcon: NSImage? = Bundle.module.image(forResource: "AssistantIcon")

    private var startPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: Self.startPageIcon ?? NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
                .padding(.bottom, 12)
            Text("Ask about this document")
                .font(.system(size: 16, weight: .bold))
                .padding(.bottom, 6)
            // Grounded in what the assistant can actually do (the read-only Rubien
            // tools): document text/figures, the user's annotations, library search;
            // web is the + menu toggle. Selecting text in the reader offers "Ask".
            Text("The assistant reads this document through Rubien — its text, figures, and your highlights — and can search your library. Web search can be toggled in the + menu.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)
            VStack(spacing: 8) {
                suggestionRow("text.alignleft", "Summarize this document")
                suggestionRow("highlighter", "Recap my highlights and notes")
                suggestionRow("books.vertical", "Find related papers in my library")
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func suggestionRow(_ icon: String, _ prompt: String) -> some View {
        QuickStartRow(icon: icon, text: prompt) { session.send(prompt) }
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
            Button {
                Task { await session.recheckAvailability() }
            } label: {
                Text("Recheck")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(Color.accentColor))
            }
            .buttonStyle(.plain)
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.80))
                (Text("Allow ") + Text(approval.toolName).bold() + Text("?"))
                    .font(.system(size: 12))
                Spacer()
                // Parallel tool calls queue (one card at a time); show the depth.
                if session.pendingApprovals.count > 1 {
                    Text("+\(session.pendingApprovals.count - 1) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if !approval.summary.isEmpty {
                Text(approval.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            HStack(spacing: 10) {
                Button {
                    session.respond(to: approval, .allowOnce)
                } label: {
                    Text("Allow Once")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Capsule(style: .continuous).fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                Button("Allow for Conversation") { session.respond(to: approval, .allowForConversation) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Deny") { session.respond(to: approval, .deny) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private func selectionChip(_ selection: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "quote.opening")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(selection)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button {
                session.stagedSelection = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HeaderControlButtonStyle())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 4) {
            composerBox
            statusLine
        }
        .padding(10)
    }

    /// The message box, Claude-chat style: the editor on top, then a bottom control
    /// row INSIDE the box (model · effort selector + the accent-circle send/stop) —
    /// soft continuous corners, hairline border (the popovers' clean idiom).
    private var composerBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            composerEditor
            HStack(spacing: 8) {
                plusMenu
                approvalPicker
                Spacer()
                providerPicker
                modelPicker
                composerButton
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: Approval mode switch (Ask ⟷ Auto)

    /// Whether the agent's write/tool-use actions prompt (Ask — a native approval
    /// card, the D6 soft boundary) or run automatically (Auto). Reads/search are
    /// silent either way.
    private var approvalPicker: some View {
        Menu {
            Picker("Approvals", selection: $session.autoApprove) {
                Label("Ask for approval", systemImage: "hand.raised").tag(false)
                Label("Auto-accept actions", systemImage: "bolt").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            approvalPickerText
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(approvalMenuHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { approvalMenuHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: approvalMenuHovered)
        .help("Approvals — Ask shows a card before writes/shell; Auto runs them automatically")
    }

    private var approvalPickerText: Text {
        let icon = session.autoApprove ? "bolt.fill" : "hand.raised"
        let word = session.autoApprove ? "Auto" : "Ask"
        let tint: Color = session.autoApprove ? .orange : Color.primary.opacity(0.80)
        return ((Text(Image(systemName: icon)) + Text(" \(word)"))
            .foregroundStyle(tint)
            + Text(" ")
            + Text(Image(systemName: "chevron.down"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary))
            .font(.system(size: 12))
    }

    // MARK: Provider (backend) selector

    /// The runtime backend for this conversation. Claude-only until the Codex
    /// provider lands (Phase 3) — Codex is listed but not selectable, so the
    /// control communicates what's coming without a dead end.
    private var providerPicker: some View {
        Menu {
            Picker("Backend", selection: .constant(AgentProviderKind.claude)) {
                Text("Claude Code").tag(AgentProviderKind.claude)
                Text("Codex (coming soon)").tag(AgentProviderKind.codex)
                    .selectionDisabled(true)
            }
            .pickerStyle(.inline)
        } label: {
            providerPickerText
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(providerMenuHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { providerMenuHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: providerMenuHovered)
        .help("Backend for this conversation (Codex arrives in a later update)")
    }

    private var providerPickerText: Text {
        (Text(session.providerKind == .claude ? "Claude" : "Codex")
            .foregroundStyle(Color.primary.opacity(0.80))
            + Text(" ")
            + Text(Image(systemName: "chevron.down"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary))
            .font(.system(size: 12))
    }

    // MARK: Model + effort selector (maps to `--model` / `--effort`)

    // Derived from the shared source of truth (AssistantModelOptions) so the
    // sidebar and Settings ▸ Assistant can't offer different models/efforts. The
    // picker tags are `String?` because `session.modelOverride` is optional (nil
    // omits the flag), so the non-optional shared values are lifted to Optional.
    private static let modelChoices: [(label: String, value: String?)] =
        AssistantModelOptions.models.map { (label: $0.label, value: Optional($0.value)) }
    private static let effortChoices: [(label: String, value: String?)] =
        AssistantModelOptions.efforts.map { (label: $0.label, value: Optional($0.value)) }

    private var modelPicker: some View {
        Menu {
            Picker("Model", selection: $session.modelOverride) {
                ForEach(Self.modelChoices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .pickerStyle(.inline)
            Picker("Effort", selection: $session.effortOverride) {
                ForEach(Self.effortChoices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .pickerStyle(.inline)
        } label: {
            // ONE concatenated Text: a Menu label made of an HStack of Texts does
            // not render reliably under .borderlessButton on macOS — segments get
            // stacked/dropped. Concatenation guarantees a single side-by-side line
            // and gives the reference's two-tone look (bold model, gray effort).
            modelPickerText
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Menus don't take a ButtonStyle — paint the same hover highlight the
        // header controls get (HeaderControlButtonStyle) by hand.
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(modelMenuHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { modelMenuHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: modelMenuHovered)
        .help("Model and reasoning effort for this conversation")
    }

    private var modelLabel: String {
        AssistantModelOptions.modelLabel(for: session.modelOverride)
    }

    /// The gray effort word beside the model ("**Opus** High").
    private var effortLabel: String? {
        AssistantModelOptions.effortLabel(for: session.effortOverride)
    }

    /// "Opus High ˅" as one concatenated Text (dark model · gray effort · chevron),
    /// regular weight — the reference's two-tone look.
    private var modelPickerText: Text {
        var text = Text(modelLabel)
            .foregroundStyle(Color.primary.opacity(0.80))
        if let effortLabel {
            text = text + Text(" \(effortLabel)").foregroundStyle(.secondary)
        }
        text = text
            + Text(" ")
            + Text(Image(systemName: "chevron.down"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        return text.font(.system(size: 12))
    }

    private var composerEditor: some View {
        ZStack(alignment: .topLeading) {
            // Invisible sizer: the ZStack takes THIS text's height, so the editor
            // hugs its content (one line when empty) instead of greedily expanding
            // to the max — a bare TextEditor fills any height it is offered. The
            // trailing space makes a trailing newline count as a line.
            Text(draft.isEmpty ? " " : draft + " ")
                .font(.body)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0)
                .allowsHitTesting(false)
            if draft.isEmpty {
                Text("Ask about this document…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    // Align with the TextEditor's insertion point (its text
                    // container has a ~5 pt leading line-fragment inset).
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $draft)
                .focused($composerFocused)
                .font(.body)
                .scrollContentBackground(.hidden)
        }
        // Grow with content up to ~6 lines, then the editor scrolls internally.
        .frame(maxHeight: 120)
        // Inner margin so the cursor/text never hugs the border.
        .padding(.vertical, 2)
    }

    /// The send/stop control: an accent rounded-corner square (Claude-style squircle)
    /// with a white glyph.
    private static let sendButtonShape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    @ViewBuilder private var composerButton: some View {
        if session.isResponding {
            Button {
                session.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 27, height: 27)
                    .background(Self.sendButtonShape.fill(Color.accentColor))
                    .contentShape(Self.sendButtonShape)
            }
            .buttonStyle(.plain)
            .help("Stop")
        } else {
            let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button {
                sendDraft()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 27, height: 27)
                    .background(Self.sendButtonShape.fill(isEmpty ? Color.accentColor.opacity(0.5) : Color.accentColor))
                    .contentShape(Self.sendButtonShape)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isEmpty)
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
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        session.send(text)
        composerFocused = true
    }

    /// Move keyboard focus into the composer shortly after a selection is staged
    /// (Selection→Ask, §5.4). A `@FocusState` set in the same runloop as a fresh
    /// pane mount doesn't take — the `TextEditor` isn't in the responder chain yet
    /// — so hop a runloop before requesting focus.
    private func focusComposerSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            composerFocused = true
        }
    }
}

// MARK: - History popover (2c-6)

/// Browses the active provider's OWN recent sessions for this working folder (§5.3)
/// and `--resume`s a pick. Rubien stores no transcripts (D5); this is a light read of
/// the runtime's session store. Loaded lazily when the popover opens.
private struct ChatHistoryPopover: View {
    let session: ChatSessionController
    /// Called after a pick is resumed (the sidebar dismisses + clears the draft).
    var onResumed: () -> Void

    @State private var sessions: [AgentSessionSummary]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent conversations")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            content
            Divider()
            Text("The assistant’s own sessions for this working folder.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 320)
        .task {
            if sessions == nil { sessions = await session.listRecentSessions() }
        }
    }

    @ViewBuilder private var content: some View {
        if let sessions {
            if sessions.isEmpty {
                Text("No past conversations in this folder yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sessions) { summary in
                            HistoryRow(summary: summary) {
                                session.resume(summary)
                                onResumed()
                            }
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        } else {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 16)
        }
    }
}

/// One selectable past conversation: first-message preview + date, with a hover fill.
private struct HistoryRow: View {
    let summary: AgentSessionSummary
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.preview)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(summary.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(hovered ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Quick-start suggestion row

/// One tappable suggestion on the fresh-conversation start page: icon + prompt in
/// a hairline-bordered rounded row with a hover highlight.
private struct QuickStartRow: View {
    let icon: String
    let text: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.85))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.04) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// MARK: - Header control button style

/// The popovers' `NotionToolbarButtonStyle`, made theme-adaptive for a persistent
/// pane: clear at rest (no bezel/boundary), a subtle `Color.primary` highlight on
/// hover/press (the popovers use black tints because they force light mode).
private struct HeaderControlButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isPressed
                          ? Color.primary.opacity(0.10)
                          : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
#endif
