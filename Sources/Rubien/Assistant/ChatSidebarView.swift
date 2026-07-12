#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var isDropTargeted = false
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
            session.refreshCodexCatalog()
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
                // Same chat glyph as the reader's "Assistant" toolbar button + the
                // empty state, so the feature reads consistently everywhere.
                Image(systemName: "bubble.left.and.text.bubble.right")
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
            Button(action: chooseAttachments) {
                Label {
                    Text("Add files or photos")
                } icon: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14, weight: .regular))
                }
            }
            .disabled(
                session.isResponding
                    || session.isRehomingAttachments
                    || session.hasAttachmentRehomeFailure)
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
        // A known-not-ready backend while a conversation is showing — the start page
        // (the setup card's only other home) is hidden once hasMessages is true, so
        // surface the reason + Recheck above the composer. Covers a signed-out user
        // resuming a History conversation, or the CLI signing out mid-session.
        if session.hasMessages, let setup = assistantSetupCopy {
            assistantSetupBlock(setup)
                .padding(.horizontal, 10)
                .padding(.top, 8)
        }
        composer
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
            Text("Chat about this document")
                .font(.system(size: 16, weight: .bold))
                .padding(.bottom, 6)
            // Only the two facts a new user can't guess: the Selection→Ask
            // affordance and the web toggle. (That the assistant reads THIS
            // document is already the headline's promise — don't re-explain it.)
            Text("Select text and click \(Image(systemName: "bubble.left.and.text.bubble.right")) to quote it here. Toggle web search in the + menu.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)
            if let setup = assistantSetupCopy {
                assistantSetupBlock(setup)
            } else {
                VStack(spacing: 8) {
                    suggestionRow("text.alignleft", "Summarize this document")
                    suggestionRow("highlighter", "Recap my highlights and notes")
                    suggestionRow("books.vertical", "Find related papers in my library")
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func suggestionRow(_ icon: String, _ prompt: String) -> some View {
        QuickStartRow(icon: icon, text: prompt) { session.send(prompt) }
    }

    // MARK: Setup state (§4.5)

    private struct AssistantSetupCopy {
        var title: String
        var detail: String
    }

    private var assistantSetupCopy: AssistantSetupCopy? {
        // Probe still in flight (`nil`): send is allowed optimistically, so show the
        // normal quick-start suggestions rather than a "checking" gate. Only a KNOWN
        // not-ready state surfaces the setup card below.
        guard let availability = session.availability, !availability.isReady else { return nil }
        switch (session.providerKind, availability.isInstalled, availability.isAuthenticated) {
        case (.claude, false, _):
            return AssistantSetupCopy(
                title: "Claude Code CLI wasn’t found.",
                detail: "Install Claude Code or set the binary path in Settings → Assistant, then recheck.")
        case (.claude, true, false):
            return AssistantSetupCopy(
                title: "Claude Code is installed but not signed in.",
                detail: "Run claude auth login in Terminal, then recheck.")
        case (.codex, false, _):
            return AssistantSetupCopy(
                title: "Codex CLI wasn’t found.",
                detail: "Install Codex or set the binary path in Settings → Assistant, then recheck.")
        case (.codex, true, false):
            return AssistantSetupCopy(
                title: "Codex is installed but not signed in.",
                detail: "Run codex login in Terminal, then recheck.")
        default:
            return AssistantSetupCopy(
                title: "\(session.providerKind.displayName) is unavailable.",
                detail: availability.unavailableReason ?? "Check Settings → Assistant, then recheck.")
        }
    }

    private func assistantSetupBlock(_ copy: AssistantSetupCopy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text(copy.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.85))
            }
            Text(copy.detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await session.recheckAvailability() }
            } label: {
                Text("Recheck")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
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
            VStack(spacing: 6) {
                // Two equal-width, neutral primary actions — the normal highlight is
                // enough; no accent/red tint. Enter still triggers Allow.
                HStack(spacing: 8) {
                    Button("Allow") { session.respond(to: approval, .allowOnce) }
                        .buttonStyle(ApprovalChoiceButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    Button("Deny") { session.respond(to: approval, .deny) }
                        .buttonStyle(ApprovalChoiceButtonStyle())
                }
                // The "for the whole conversation" variant, de-emphasized below.
                Button {
                    session.respond(to: approval, .allowForConversation)
                } label: {
                    Text("Allow for the rest of this conversation")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HeaderControlButtonStyle())
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

    private func selectionChip(_ selection: ChatSessionController.StagedSelection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "quote.opening")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(selection.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let page = selection.pageNumber {
                Text("p. \(page)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
            }
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
            if !session.stagingAttachments.isEmpty
                || !session.pendingAttachments.isEmpty
                || !session.attachmentIssues.isEmpty
            {
                pendingAttachmentTray
            }
            composerEditor
            Text("Add images, Markdown, or text files")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
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
                .stroke(
                    isDropTargeted ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: isDropTargeted ? 1.5 : 1)
        )
        .dropDestination(for: URL.self) { urls, _ in
            session.stageAttachments(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .onPasteCommand(of: [.fileURL, .image], perform: handlePaste)
    }

    // MARK: Attachments

    private var pendingAttachmentTray: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !session.stagingAttachments.isEmpty || !session.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.stagingAttachments) { attachment in
                            stagingAttachmentRow(attachment)
                        }
                        ForEach(session.pendingAttachments) { attachment in
                            readyAttachmentRow(attachment)
                        }
                    }
                }
            }
            ForEach(session.attachmentIssues) { issue in
                attachmentIssueRow(issue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stagingAttachmentRow(_ attachment: StagingChatAttachment) -> some View {
        HStack(spacing: 8) {
            attachmentIcon(for: attachment.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Preparing \(attachment.displayName)")
                    Text("Preparing…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            removeAttachmentButton(id: attachment.id, displayName: attachment.displayName)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: 190, alignment: .leading)
        .background(attachmentRowBackground)
    }

    private func readyAttachmentRow(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 8) {
            attachmentPreview(attachment)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(
                    fromByteCount: attachment.byteCount,
                    countStyle: .file))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            removeAttachmentButton(id: attachment.id, displayName: attachment.displayName)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: 190, alignment: .leading)
        .background(attachmentRowBackground)
    }

    private func attachmentIssueRow(_ issue: ChatAttachmentIssue) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .padding(.top, 1)
            Text("\(issue.displayName): \(issue.message)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: session.clearAttachmentIssues) {
                Image(systemName: session.hasAttachmentRehomeFailure ? "arrow.clockwise" : "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                session.hasAttachmentRehomeFailure
                    ? "Retry moving attachments"
                    : "Dismiss attachment issues")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
    }

    private var attachmentRowBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(0.045))
    }

    @ViewBuilder private func attachmentPreview(_ attachment: ChatAttachment) -> some View {
        if let image = thumbnailImage(from: attachment.thumbnailDataURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
        } else {
            attachmentIcon(for: attachment.displayName, kind: attachment.kind)
        }
    }

    private func attachmentIcon(
        for displayName: String,
        kind: ChatAttachmentKind? = nil
    ) -> some View {
        let isImage = kind == .image || ["png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff"]
            .contains((displayName as NSString).pathExtension.lowercased())
        return Image(systemName: isImage ? "photo" : "doc.text")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.65))
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
            .accessibilityHidden(true)
    }

    private func removeAttachmentButton(id: UUID, displayName: String) -> some View {
        Button {
            session.removePendingAttachment(id: id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(displayName)")
    }

    private func thumbnailImage(from dataURL: String?) -> NSImage? {
        guard
            let dataURL,
            let comma = dataURL.firstIndex(of: ","),
            let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { return nil }
        return NSImage(data: data)
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image] + ["md", "markdown", "txt"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK else { return }
        session.stageAttachments(panel.urls)
    }

    private func handlePaste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    let url = (item as? URL)
                        ?? (item as? NSURL).map { $0 as URL }
                        ?? (item as? Data).map {
                            NSURL(
                                absoluteURLWithDataRepresentation: $0,
                                relativeTo: nil) as URL
                        }
                    guard let url else { return }
                    Task { @MainActor in session.stageAttachments([url]) }
                }
                continue
            }

            guard let identifier = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) else { continue }
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    session.stagePastedImage(data, suggestedName: "Pasted Image.png")
                }
            }
        }
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

    /// The runtime backend for this conversation. Switching is a hard cut — it tears
    /// down the current runtime and starts a fresh conversation on the other (model /
    /// effort / sandbox are backend-specific, so they re-seed). Disabled mid-turn so a
    /// switch can't yank a streaming response.
    private var providerPicker: some View {
        Menu {
            Picker("Backend", selection: Binding(
                get: { session.providerKind },
                set: { session.switchProvider(to: $0) })) {
                Text("Claude Code").tag(AgentProviderKind.claude)
                Text("Codex").tag(AgentProviderKind.codex)
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
        .disabled(
            session.isResponding
                || session.isStagingAttachments
                || session.hasAttachmentRehomeFailure)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(providerMenuHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { providerMenuHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: providerMenuHovered)
        .help("Backend for this conversation — switching starts a new conversation on the other runtime")
    }

    private var providerPickerText: Text {
        (Text(session.providerKind.displayName)
            .foregroundStyle(Color.primary.opacity(0.80))
            + Text(" ")
            + Text(Image(systemName: "chevron.down"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary))
            .font(.system(size: 12))
    }

    // MARK: Model + effort selector (maps to `--model` / `--effort`)

    // Claude: the static descriptor lists (verified CLI aliases — spec §2.4).
    // Codex: DISCOVERED rows — the installed codex's own models (concrete slugs
    // only; a fresh conversation seeds one), with any unknown pin kept visible
    // (spec §4.6). Tags are `String?` only to share the ForEach type with Claude.
    private var modelChoices: [(label: String, value: String?)] {
        switch session.providerKind {
        case .claude:
            return AssistantModelOptions.models(for: .claude)
                .map { (label: $0.label, value: Optional($0.value)) }
        case .codex:
            return AssistantModelOptions.codexModelRows(
                models: session.codexModels,
                pinned: session.modelOverride)
        }
    }
    private var effortChoices: [(label: String, value: String?)] {
        switch session.providerKind {
        case .claude:
            return AssistantModelOptions.efforts(for: .claude)
                .map { (label: $0.label, value: Optional($0.value)) }
        case .codex:
            return AssistantModelOptions.codexEffortRows(
                governing: session.governingCodexModel,
                includingCurrent: session.effortOverride)
                .map { (label: $0.label, value: Optional($0.value)) }
        }
    }

    private var modelPicker: some View {
        Menu {
            Picker("Model", selection: Binding(
                get: { session.modelOverride },
                set: { session.selectModel($0) })) {
                ForEach(modelChoices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .pickerStyle(.inline)
            Picker("Effort", selection: Binding(
                get: { session.effortOverride },
                set: { session.selectEffort($0) })) {
                ForEach(effortChoices, id: \.value) { choice in
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
        .help("Model and reasoning effort for this conversation — on Codex, changing the model starts a new conversation")
    }

    private var modelLabel: String {
        if session.providerKind == .codex {
            // The current model's display name (from the catalog), else its raw
            // slug, else a neutral placeholder for the transient pre-seed window
            // before discovery lands and seeds a concrete model.
            guard let current = session.modelOverride else { return "Codex" }
            return session.codexModels.first { $0.id == current }?.displayName ?? current
        }
        return AssistantModelOptions.modelLabel(for: session.modelOverride, kind: session.providerKind)
    }

    /// The gray effort word beside the model ("**Opus** High").
    private var effortLabel: String? {
        AssistantModelOptions.effortLabel(for: session.effortOverride, kind: session.providerKind)
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
                // The placeholder doubles as the send-shortcut hint (plain ↩ is a
                // newline, so ⌘↩ is otherwise undiscoverable — and this line was
                // spending its words on nothing).
                Text("Chat about this document — ⌘+↩ to send")
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
                // The composer owns the return key DETERMINISTICALLY. Before this,
                // send lived on the button as a ⌘↩ key equivalent — and SwiftUI's
                // loose equivalent matching also fired it for ⇧↩ (undeclared,
                // version-fragile, and it surprised the user). Now: ⌘↩ sends;
                // plain ↩ and every other modifier fall through to the text
                // system (newline) and can never send.
                .onKeyPress(.return, phases: .down) { press in
                    // EXACTLY ⌘ — `contains` would also send on ⌘⇧↩/⌘⌥↩. State
                    // flags are masked out first: caps lock reports as a modifier
                    // (strict equality would dead-key ⌘↩ for a caps-lock user)
                    // and keypad-Enter adds .numericPad.
                    let chord = press.modifiers.subtracting([.capsLock, .numericPad])
                    guard chord == .command else { return .ignored }
                    guard session.canSend(draft: draft)
                    else { return .handled }  // consume the chord; never a newline
                    sendDraft()
                    return .handled
                }
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
            let canSend = session.canSend(draft: draft)
            Button {
                sendDraft()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 27, height: 27)
                    .background(Self.sendButtonShape.fill(canSend ? Color.accentColor : Color.accentColor.opacity(0.5)))
                    .contentShape(Self.sendButtonShape)
            }
            .buttonStyle(.plain)
            // No .keyboardShortcut here — the composer's onKeyPress is the one
            // owner of ⌘↩ (a key EQUIVALENT on the button is the loose-matching
            // pass that made ⇧↩ send by accident).
            .disabled(!canSend)
            .help(canSend ? "Send (⌘↩)" : "Enter a message or add an attachment")
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
        guard session.canSend(draft: draft) else {
            composerFocused = true
            return
        }
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

// MARK: - Floating card (Phase 3a)

/// The assistant as a floating card over the reader's content — the details-panel
/// idiom (`FloatingPanel`), not a docked split pane: solid surface, rounded,
/// hairline-bordered, shadowed, resizable from its leading edge. Readers overlay
/// it with `.overlay(alignment: .trailing)`; the trailing inset and the show/hide
/// `.animation` stay at the call site (they differ per reader), the rest of the
/// presentation lives here. (A Liquid Glass variant was tried and rolled back —
/// the user prefers the solid surface for chat legibility.)
struct FloatingChatPanel: View {
    let session: ChatSessionController
    let renderer: ChatTranscriptController
    @Binding var width: CGFloat
    let onClose: () -> Void

    var body: some View {
        FloatingPanel(width: $width, range: 300...640) {
            ChatSidebarView(session: session, renderer: renderer, onClose: onClose)
                .background(Color.chatSurface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 3)
        }
        .padding(.vertical, 8)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}

extension Color {
    /// The surface behind the whole chat card. The transcript WebView paints NO
    /// page background (chat.css: `background: transparent`), so this native
    /// color is the single owner of the chat surface — header, transcript, and
    /// composer can't seam. Appearance-dynamic; no colorScheme plumbing needed.
    static let chatSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
            : .white
    })
}

// MARK: - History popover (2c-6)

/// Browses the active provider's OWN sessions for this working folder (§5.3) and
/// `--resume`s a pick. Rubien stores no transcripts (D5); this is a light read of
/// the runtime's session store. Recents load lazily when the popover opens; typing
/// in the search field switches to a debounced CONTENT search (the visible
/// user/assistant text of every session, not just first-message previews).
private struct ChatHistoryPopover: View {
    let session: ChatSessionController
    /// Called after a pick is resumed (the sidebar dismisses + clears the draft).
    var onResumed: () -> Void

    /// Which sessions the popover lists: only those attributed to the open document
    /// (the default — attribution is the session's rubien tool calls), or every
    /// session in the working folder.
    private enum HistoryScope: Hashable {
        case thisDocument, allDocuments
    }

    @State private var scope: HistoryScope = .thisDocument
    @State private var sessions: [AgentSessionSummary]?
    @State private var query = ""
    /// nil while a search is in flight (spinner); results otherwise. Ignored when
    /// the query is empty (recents show).
    @State private var searchResults: [AgentSessionSummary]?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Conversations")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            scopePicker
            searchField
            Divider()
            content
            Divider()
            Text(scope == .thisDocument
                ? "Conversations that read this document."
                : "The assistant’s own sessions for this working folder.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 320)
        // `task(id:)` (re)loads recents on open AND whenever the scope flips,
        // cancelling the superseded load (a scoped listing scans session bodies).
        .task(id: scope) {
            sessions = nil
            let loaded = await session.listRecentSessions(
                scopedToReference: scope == .thisDocument)
            // Cancellation is cooperative: a superseded (cancelled) load can still
            // return, and without this guard its stale scope's rows would overwrite
            // the fresh flip's — exactly when the old scoped scan is the slow one.
            guard !Task.isCancelled else { return }
            sessions = loaded
        }
        .onChange(of: query) { _, _ in scheduleSearch() }
        // Re-run an active search under the new scope (the debounce task captures
        // the scope at schedule time). Empty-query handling is scheduleSearch's own.
        .onChange(of: scope) { _, _ in scheduleSearch() }
    }

    /// The reader sidebars' own tab control (hover highlight + sliding indicator)
    /// rather than a native segmented picker, which has no hover feedback on macOS.
    private var scopePicker: some View {
        DraggableSegmentedControl(selection: $scope, items: [
            (label: "This document", value: HistoryScope.thisDocument),
            (label: "All documents", value: HistoryScope.allDocuments),
        ])
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search past conversations", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear search", bundle: .module))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onAppear { focusSoon() }
    }

    /// Debounced content search: typing cancels the previous probe; the query
    /// must be stable for a beat before files are scanned. An empty query just
    /// switches the list back to recents. Honors the scope toggle.
    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            searchResults = nil
            return
        }
        searchResults = nil  // spinner while (re)searching
        let scoped = scope == .thisDocument
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let hits = await session.searchSessions(trimmed, scopedToReference: scoped)
            guard !Task.isCancelled else { return }
            searchResults = hits
        }
    }

    /// Focus at popover-mount doesn't take; hop the runloop first (the sidebar
    /// composer's `focusComposerSoon` idiom).
    private func focusSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            searchFocused = true
        }
    }

    /// Recents and search results share one shape: nil → spinner, empty → label,
    /// rows → list. Only the source array, empty-text, and highlight differ.
    @ViewBuilder private var content: some View {
        let highlight = trimmedQuery.isEmpty ? nil : trimmedQuery
        let items = highlight == nil ? sessions : searchResults
        if let items {
            if items.isEmpty {
                emptyLabel(emptyText(searching: highlight != nil))
            } else {
                rowList(items, highlight: highlight)
            }
        } else {
            loadingSpinner
        }
    }

    private func rowList(_ items: [AgentSessionSummary], highlight: String? = nil) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(items) { summary in
                    HistoryRow(summary: summary, highlightQuery: highlight) {
                        session.resume(summary)
                        onResumed()
                    }
                }
            }
        }
        // A ScrollView has no intrinsic height, and the popover was sized around
        // the loading spinner before the async rows landed — a bare `maxHeight`
        // left it collapsed to ~one visible row. Fixed-height rows make the
        // content height deterministic.
        .frame(height: min(CGFloat(items.count) * HistoryRow.height, 340))
    }

    /// The empty-state line, scope- and mode-aware: a scoped miss points at the
    /// "All documents" toggle so a session filed under another paper isn't read
    /// as data loss.
    private func emptyText(searching: Bool) -> String {
        switch (searching, scope) {
        case (false, .thisDocument):
            return "No conversations for this document yet. “All documents” shows every conversation in this folder."
        case (false, .allDocuments):
            return "No past conversations in this folder yet."
        case (true, .thisDocument):
            return "No conversations for this document match “\(trimmedQuery)”."
        case (true, .allDocuments):
            return "No conversations match “\(trimmedQuery)”."
        }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
    }

    private var loadingSpinner: some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        }
        .padding(.vertical, 16)
    }
}

/// One selectable past conversation: first-message preview + date (or, for a
/// search hit, the matched snippet with the query bolded), with a hover fill.
private struct HistoryRow: View {
    /// Fixed row height so the popover list's total height is deterministic
    /// (both lines are single-line for the same reason).
    static let height: CGFloat = 44

    let summary: AgentSessionSummary
    var highlightQuery: String? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.preview)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                secondLine
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: Self.height)
            .background(hovered ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    /// The matched snippet (query bolded) for a search hit; the date otherwise.
    @ViewBuilder private var secondLine: some View {
        if let snippet = summary.matchSnippet {
            Text(Self.highlighted(snippet, query: highlightQuery))
        } else {
            Text(summary.date.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private static func highlighted(_ snippet: String, query: String?) -> AttributedString {
        var attributed = AttributedString(snippet)
        // Re-find with the store's own match options — sound by construction (the
        // snippet window opens ≤ context before the file's FIRST match, so its
        // first occurrence is that match).
        if let query, !query.isEmpty,
           let range = attributed.range(of: query, options: ClaudeSessionStore.matchOptions) {
            attributed[range].font = .system(size: 10, weight: .bold)
        }
        return attributed
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

/// An equal-width, neutral approval action (Allow / Deny). A soft filled + hairline
/// pill that deepens on hover/press — the normal highlight, no accent or red tint.
private struct ApprovalChoiceButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.85))
            .frame(maxWidth: .infinity)   // equal width across the row
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed
                          ? Color.primary.opacity(0.14)
                          : (isHovered ? Color.primary.opacity(0.09) : Color.primary.opacity(0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
#endif
