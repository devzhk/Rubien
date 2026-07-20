#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import RubienCore

private enum ChatSurfaceTypography {
    /// Secondary interface text stays one step below 14-point conversation text.
    static let controlFontSize: CGFloat = 13
}

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

/// The reader-facing wrapper owns its draft locally. The underlying surface is also
/// used by Agent Home with an external draft binding, so leaving Home for Library and
/// returning does not discard work in progress.
struct ChatSidebarView: View {
    @ObservedObject var session: ChatSessionController
    let renderer: ChatTranscriptController
    var onClose: (() -> Void)? = nil

    @State private var draft = ""
    @State private var selectedMentions: [PaperMentionSelection] = []

    var body: some View {
        ChatSurfaceView(
            session: session,
            renderer: renderer,
            draft: $draft,
            selectedMentions: $selectedMentions,
            configuration: .reader(
                onClose: onClose,
                onOpenReference: ReaderChatPaperActions.openReference,
                onOpenPaperSource: ReaderChatPaperActions.openSource,
                onAddPaperSource: ReaderChatPaperActions.addSource))
    }
}

/// Configuration for the shared, full-fidelity chat surface. Both placements use
/// the same composer implementation (attachments, paste/drop, @paper mentions,
/// provider/model/effort, web and approvals); only their empty state, history scope,
/// and suggested-document presentation differ.
struct ChatSurfaceConfiguration {
    enum Placement: Equatable {
        case reader
        case home
    }

    let placement: Placement
    var onClose: (() -> Void)?
    let onOpenReference: (Int64) -> Void
    let onOpenPaperSource: (String) -> Void
    let onAddPaperSource: (String) -> Void
    var libraryIsEmpty: Bool
    var onAddPapers: (() -> Void)?
    var onImportPDFs: (() -> Void)?
    var scheduledJobs: ScheduledJobCoordinator?
    var onOpenScheduledRun: ((ScheduledJobRun) -> Void)?
    var scheduledJobsPresentation: Binding<ScheduledJobsPresentation?>?

    static func reader(
        onClose: (() -> Void)?,
        onOpenReference: @escaping (Int64) -> Void,
        onOpenPaperSource: @escaping (String) -> Void,
        onAddPaperSource: @escaping (String) -> Void
    ) -> Self {
        Self(
            placement: .reader,
            onClose: onClose,
            onOpenReference: onOpenReference,
            onOpenPaperSource: onOpenPaperSource,
            onAddPaperSource: onAddPaperSource,
            libraryIsEmpty: false,
            onAddPapers: nil,
            onImportPDFs: nil,
            scheduledJobs: nil,
            onOpenScheduledRun: nil,
            scheduledJobsPresentation: nil)
    }

    static func home(
        onOpenReference: @escaping (Int64) -> Void,
        onOpenPaperSource: @escaping (String) -> Void,
        onAddPaperSource: @escaping (String) -> Void,
        libraryIsEmpty: Bool,
        onAddPapers: @escaping () -> Void,
        onImportPDFs: @escaping () -> Void,
        scheduledJobs: ScheduledJobCoordinator,
        onOpenScheduledRun: @escaping (ScheduledJobRun) -> Void,
        scheduledJobsPresentation: Binding<ScheduledJobsPresentation?>
    ) -> Self {
        Self(
            placement: .home,
            onClose: nil,
            onOpenReference: onOpenReference,
            onOpenPaperSource: onOpenPaperSource,
            onAddPaperSource: onAddPaperSource,
            libraryIsEmpty: libraryIsEmpty,
            onAddPapers: onAddPapers,
            onImportPDFs: onImportPDFs,
            scheduledJobs: scheduledJobs,
            onOpenScheduledRun: onOpenScheduledRun,
            scheduledJobsPresentation: scheduledJobsPresentation)
    }

    var isHome: Bool { placement == .home }
}

struct ChatSurfaceView: View {
    private static let homeContentMaxWidth: CGFloat = 700
    private static let homeApprovalMaxWidth: CGFloat = 520
    private static let queuedMessageRowHeight: CGFloat = 54

    @ObservedObject var session: ChatSessionController
    let renderer: ChatTranscriptController
    @Binding var draft: String
    @Binding var selectedMentions: [PaperMentionSelection]
    var isActive = true
    let configuration: ChatSurfaceConfiguration

    @State private var showingHistory = false
    @State private var showingScheduledJobs = false
    @State private var scheduledJobToEdit: ScheduledJob?
    @State private var scheduledJobsInitialErrorMessage: String?
    @State private var modelMenuHovered = false
    @State private var providerMenuHovered = false
    @State private var plusMenuHovered = false
    @State private var approvalMenuHovered = false
    @State private var isDropTargeted = false
    /// Bumped to move first-responder status into the composer editor (see
    /// `ComposerTextView.focusRequestCount`); a `@FocusState` can't reach into
    /// the AppKit-backed editor. Distinct from `session.composerFocusRequest`,
    /// the controller-level signal that feeds this via `focusComposerSoon`.
    @State private var editorFocusRequests = 0
    /// Character offsets supplied by the AppKit-backed composer. Offsets remain
    /// safe to validate while the text and selection bindings coalesce.
    @State private var draftSelection: Range<Int>?
    @State private var activeMentionQuery: PaperMentionQuery?
    @State private var mentionResults: [ChatReference] = []
    @State private var selectedMentionIndex = 0
    /// Exact draft already reconciled by a programmatic completion. Its next
    /// `onChange` must not apply the same edit a second time.
    @State private var reconciledDraft: String?
    /// Draft and selection are separate SwiftUI bindings and can publish in
    /// either order. Coalesce them before converting offsets to String.Index.
    @State private var mentionRefreshTask: Task<Void, Never>?
    @State private var mentionSearchTask: Task<Void, Never>?
    @State private var mentionSearchInProgress = false
    /// A Home History pick starts docking immediately while the asynchronous
    /// attribution lookup loads its transcript. `hasMessages` becomes authoritative
    /// as soon as the resume is adopted.
    @State private var homeResumeRequested = false
    /// Fresh Home sends retain their draft until the global turn gate actually
    /// admits the turn. This snapshot lets the commit observer clear only the exact
    /// draft that was submitted; a refused turn therefore remains fully retryable.
    @State private var pendingFreshHomeDraft: String?
    @State private var editingQueuedMessageID: UUID?
    @State private var queuedMessageEditDraft = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            if !configuration.isHome {
                hairline
            }
            content
        }
        .frame(minWidth: AssistantSidebarMetrics.minimumWidth)
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
            presentRequestedScheduledJobs(
                configuration.scheduledJobsPresentation?.wrappedValue
            )
        }
        .onChange(of: configuration.scheduledJobsPresentation?.wrappedValue) { _, request in
            presentRequestedScheduledJobs(request)
        }
        .onChange(of: colorScheme) { _, new in renderer.setTheme(new == .dark ? .dark : .light) }
        .onChange(of: session.hasMessages) { _, hasMessages in
            guard configuration.isHome else { return }
            if hasMessages {
                homeResumeRequested = false
                if let submitted = pendingFreshHomeDraft {
                    // Preserve edits made during the very short gate-acquisition
                    // window; clear only the exact draft that was committed.
                    if draft == submitted || draft.isEmpty { resetDraft() }
                    pendingFreshHomeDraft = nil
                }
            } else {
                homeResumeRequested = false
                pendingFreshHomeDraft = nil
            }
        }
        // Selection→Ask while the pane is already open — each Ask bumps the token
        // (even re-Asking the same passage), which focuses the composer (§5.4).
        .onChange(of: session.composerFocusRequest) { _, _ in focusComposerSoon() }
        .onChange(of: draft) { old, new in
            if reconciledDraft == new {
                reconciledDraft = nil
            } else {
                selectedMentions = PaperMentions.reconciling(
                    selectedMentions,
                    from: old,
                    to: new
                )
            }
            scheduleMentionRefresh()
        }
        .onChange(of: draftSelection) { _, _ in scheduleMentionRefresh() }
        .onChange(of: session.queuedMessages) { _, messages in
            guard let editingQueuedMessageID,
                  !messages.contains(where: { $0.id == editingQueuedMessageID })
            else { return }
            cancelQueuedMessageEdit()
        }
        .onExitCommand {
            if editingQueuedMessageID != nil {
                cancelQueuedMessageEdit()
                return
            }
            // The composer consumes Escape first when its mention popover is open.
            // Otherwise make interrupt-and-send work from the transcript and other
            // controls too, not only while the text editor owns focus.
            guard activeMentionQuery == nil else { return }
            _ = interruptAndSendQueuedIfPossible()
        }
        .onDisappear {
            cancelQueuedMessageEdit()
            mentionSearchTask?.cancel()
            mentionRefreshTask?.cancel()
        }
    }

    // MARK: Header (popover-toolbar idiom)

    private var header: some View {
        HStack(spacing: 2) {
            if !configuration.isHome {
                HStack(spacing: 5) {
                    // Same glyph as the reader's Assistant toolbar button.
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.80))
                    Text("Assistant")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.leading, 4)
            }
            Spacer()
            let newConversation = {
                session.newConversation()
                resetDraft()
                homeResumeRequested = false
                pendingFreshHomeDraft = nil
            }
            if configuration.isHome {
                labeledHeaderButton(
                    "square.and.pencil",
                    title: "New",
                    help: "New conversation",
                    action: newConversation)
            } else {
                iconButton(
                    "square.and.pencil",
                    help: "New conversation",
                    action: newConversation)
            }
            if configuration.isHome {
                labeledHeaderButton(
                    "clock.arrow.circlepath",
                    title: "History",
                    help: "Home conversation history") {
                    showingHistory = true
                }
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                    HomeChatHistoryPopover(session: session) {
                        showingHistory = false
                        resetDraft()
                        pendingFreshHomeDraft = nil
                        homeResumeRequested = true
                    }
                }
                if let scheduledJobs = configuration.scheduledJobs {
                    labeledHeaderButton(
                        "alarm",
                        title: "Scheduled",
                        help: "Scheduled jobs and recent runs"
                    ) {
                        scheduledJobToEdit = nil
                        scheduledJobsInitialErrorMessage = nil
                        showingScheduledJobs = true
                    }
                    .overlay(alignment: .topTrailing) {
                        if scheduledJobs.unreadRunCount > 0 {
                            Text(scheduledJobs.unreadRunCount > 9 ? "9+" : "\(scheduledJobs.unreadRunCount)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .frame(minWidth: 13, minHeight: 13)
                                .background(Color.accentColor, in: Capsule())
                                .offset(x: 3, y: -2)
                        }
                    }
                    .popover(isPresented: $showingScheduledJobs, arrowEdge: .bottom) {
                        ScheduledJobsPopover(
                            coordinator: scheduledJobs,
                            onOpenRun: { run in
                                showingScheduledJobs = false
                                resetDraft()
                                pendingFreshHomeDraft = nil
                                homeResumeRequested = true
                                configuration.onOpenScheduledRun?(run)
                            },
                            initialEditorJob: scheduledJobToEdit,
                            initialErrorMessage: scheduledJobsInitialErrorMessage
                        )
                    }
                }
            } else {
                iconButton("clock.arrow.circlepath", help: "History — resume a past conversation") {
                    showingHistory = true
                }
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                    ChatHistoryPopover(session: session) {
                        showingHistory = false
                        resetDraft()
                    }
                }
            }
            if let onClose = configuration.onClose {
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

    private func labeledHeaderButton(
        _ systemName: String,
        title: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.system(size: ChatSurfaceTypography.controlFontSize, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.72))
                .padding(.horizontal, 7)
                .frame(height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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
        if configuration.isHome {
            if homeConversationIsDocked {
                ChatTranscriptView(
                    controller: renderer,
                    onOpenReference: configuration.onOpenReference,
                    onOpenPaperSource: configuration.onOpenPaperSource,
                    onAddPaperSource: configuration.onAddPaperSource)
                if let approval = session.pendingApproval {
                    approvalCard(approval)
                }
                if let setup = assistantSetupCopy {
                    assistantSetupBlock(setup)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                }
                homeComposer
                    .padding(.horizontal, 24)
            } else {
                homeStartPage
            }
        } else {
            ZStack {
                // Kept in the hierarchy while covered so the WebView is loaded
                // and ready the moment the first turn starts streaming.
                ChatTranscriptView(
                    controller: renderer,
                    onOpenReference: configuration.onOpenReference,
                    onOpenPaperSource: configuration.onOpenPaperSource,
                    onAddPaperSource: configuration.onAddPaperSource)
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
    }

    private var homeConversationIsDocked: Bool {
        session.hasMessages || homeResumeRequested
    }

    /// Home keeps one composer footprint across the empty and transcript
    /// layouts; sending changes only its vertical position.
    private var homeComposer: some View {
        composer
            .frame(maxWidth: Self.homeContentMaxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// A fresh Home keeps the complete composer near the visual center while its
    /// three quieter quick starts sit immediately above it.
    private var homeStartPage: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    if let scheduledJobs = configuration.scheduledJobs,
                       !scheduledJobs.upcomingJobs.isEmpty {
                        Button {
                            scheduledJobToEdit = nil
                            scheduledJobsInitialErrorMessage = nil
                            showingScheduledJobs = true
                        } label: {
                            HStack(spacing: 4) {
                                homeSectionTitle("Upcoming jobs")
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 25)
                        .frame(maxWidth: Self.homeContentMaxWidth, alignment: .leading)
                        VStack(spacing: 2) {
                            ForEach(scheduledJobs.upcomingJobs) { job in
                                Button {
                                    scheduledJobToEdit = job
                                    scheduledJobsInitialErrorMessage = nil
                                    showingScheduledJobs = true
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "alarm")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(job.name)
                                            .lineLimit(1)
                                        Spacer()
                                        if let next = job.nextRunAt {
                                            Text(next.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .font(.system(size: ChatSurfaceTypography.controlFontSize))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 25)
                                    .padding(.trailing, 10)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: Self.homeContentMaxWidth)
                        .padding(.bottom, 21)
                    }
                    if let setup = assistantSetupCopy {
                        assistantSetupBlock(setup)
                            .frame(maxWidth: 680)
                    } else {
                        if configuration.scheduledJobs?.upcomingJobs.isEmpty == false {
                            homeSectionTitle("Suggestions")
                                .padding(.leading, 25)
                                .frame(maxWidth: Self.homeContentMaxWidth, alignment: .leading)
                        }
                        VStack(spacing: 4) {
                            if configuration.libraryIsEmpty {
                                homeNativeAction(
                                    "Add papers", action: configuration.onAddPapers)
                                homeNativeAction(
                                    "Import PDFs", action: configuration.onImportPDFs)
                                homeSuggestion("Help me choose a field to explore")
                            } else {
                                homeSuggestion("What should I read next?")
                                homeSuggestion("Find recent papers in my field")
                                homeSuggestion("Summarize what we’ve been reading this week")
                            }
                        }
                        // Match the composer width. Section headings land on the
                        // editor caret; quick starts keep a 15-point subordinate
                        // indent beneath them.
                        .frame(maxWidth: Self.homeContentMaxWidth)
                        .padding(.bottom, 16)
                    }
                    homeComposer
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.top, homeStartTopPadding(for: geometry.size.height))
                .padding(.bottom, 24)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func presentRequestedScheduledJobs(_ request: ScheduledJobsPresentation?) {
        guard let request else { return }
        homeResumeRequested = false
        scheduledJobToEdit = nil
        scheduledJobsInitialErrorMessage = request.message
        showingScheduledJobs = true
        configuration.scheduledJobsPresentation?.wrappedValue = nil
    }

    /// The starts occupy roughly 14% of an ordinary canvas, so placing the cluster
    /// around 24% keeps the composer's top edge near its former ~38% position. The
    /// surrounding ScrollView is the backstop for attachments and short windows.
    private func homeStartTopPadding(for availableHeight: CGFloat) -> CGFloat {
        let preferred = availableHeight * 0.24
        let roomAwareMaximum = max(24, availableHeight - 260)
        return max(24, min(preferred, roomAwareMaximum))
    }

    private func homeSuggestion(_ prompt: String) -> some View {
        PlainQuickStartText(text: prompt) { session.send(prompt) }
    }

    private func homeSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func homeNativeAction(
        _ title: String,
        action: (() -> Void)?
    ) -> some View {
        PlainQuickStartText(text: title) { action?() }
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
            VStack(alignment: .trailing, spacing: 4) {
                // Compact, neutral primary actions — the normal highlight is enough;
                // no accent/red tint. Enter still triggers Allow.
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Allow") { session.respond(to: approval, .allowOnce) }
                        .buttonStyle(ApprovalChoiceButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isActive)
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
                }
                .buttonStyle(HeaderControlButtonStyle())
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .frame(maxWidth: configuration.isHome ? Self.homeApprovalMaxWidth : .infinity)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, configuration.isHome ? 24 : 0)
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
            if session.hasQueuedMessages {
                queuedMessageTray
            }
            composerBox
            statusLine
        }
        .padding(10)
        // The AppKit-backed editor has no useful intrinsic height of its own.
        // Size from the SwiftUI text sizer in `composerEditor` in both placements
        // so the reader composer stays as compact as Agent Home.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var queuedMessageTray: some View {
        let messages = session.queuedMessages
        let visibleRows = min(messages.count, 3)
        let viewportHeight = CGFloat(visibleRows) * Self.queuedMessageRowHeight
            + CGFloat(max(0, visibleRows - 1)) * 5
        return ScrollView(.vertical) {
            LazyVStack(spacing: 5) {
                ForEach(messages) { message in
                    queuedMessageRow(message)
                }
            }
        }
        .scrollIndicators(.automatic)
        .frame(height: viewportHeight)
        .accessibilityLabel("Queued messages")
    }

    @ViewBuilder
    private func queuedMessageRow(
        _ message: ChatSessionController.QueuedMessagePreview
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            if editingQueuedMessageID == message.id {
                TextField("Edit queued message", text: $queuedMessageEditDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...2)
                    .onChange(of: queuedMessageEditDraft) { _, text in
                        guard editingQueuedMessageID == message.id else { return }
                        _ = session.updateQueuedMessageEdit(id: message.id, text: text)
                    }

                Button(action: saveQueuedMessageEdit) {
                    Image(systemName: "checkmark")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HeaderControlButtonStyle())
                .disabled(queuedMessageEditDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
                    || session.isAwaitingTurnAdmission)
                .help("Save queued message")

                Button(action: cancelQueuedMessageEdit) {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HeaderControlButtonStyle())
                .help("Cancel editing")
            } else {
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                if session.isResponding {
                    Button {
                        session.interruptAndSendQueued()
                    } label: {
                        Label("Steer", systemImage: "arrow.turn.down.right")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HeaderControlButtonStyle())
                    .disabled(session.isAwaitingTurnAdmission
                        || editingQueuedMessageID != nil)
                    .help("Interrupt the response and send all queued messages")
                }

                Button {
                    guard let rawText = session.beginQueuedMessageEdit(id: message.id)
                    else { return }
                    editingQueuedMessageID = message.id
                    queuedMessageEditDraft = rawText
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HeaderControlButtonStyle())
                .disabled(session.isAwaitingTurnAdmission
                    || editingQueuedMessageID != nil)
                .help("Edit queued message")

                Button {
                    session.removeQueuedMessage(id: message.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HeaderControlButtonStyle())
                .disabled(session.isAwaitingTurnAdmission)
                .help("Delete queued message")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.queuedMessageRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.8)
        )
    }

    private func saveQueuedMessageEdit() {
        guard let id = editingQueuedMessageID,
              session.updateQueuedMessageEdit(id: id, text: queuedMessageEditDraft),
              session.commitQueuedMessageEdit(id: id)
        else { return }
        editingQueuedMessageID = nil
        queuedMessageEditDraft = ""
    }

    private func cancelQueuedMessageEdit() {
        if let id = editingQueuedMessageID {
            session.cancelQueuedMessageEdit(id: id)
        }
        editingQueuedMessageID = nil
        queuedMessageEditDraft = ""
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
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                // A neutral lift plus a very restrained accent halo gives the
                // composer a luminous edge without turning it into a heavy card.
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.24 : 0.09),
                    radius: 9,
                    y: 4)
                .shadow(
                    color: Color.accentColor.opacity(
                        isDropTargeted ? 0.24 : (configuration.isHome ? 0.09 : 0.055)),
                    radius: isDropTargeted ? 13 : 11)
        }
        .overlay {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            if isDropTargeted {
                shape.stroke(Color.accentColor, lineWidth: 1.5)
            } else {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.10 : 0.62),
                            Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10),
                            Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    lineWidth: 0.8)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isDropTargeted)
        // Catches drops on the box outside the editor (tray, control row, padding);
        // drops on the editor itself are routed by `ComposerNSTextView`, which sits
        // in front of this destination in AppKit's hit-testing.
        .dropDestination(for: URL.self) { urls, _ in
            session.stageAttachments(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
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
            Text(issue.presentedMessage)
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

    // MARK: Approval mode switch (Ask ⟷ Auto)

    /// Whether approval requests become native cards or run automatically. In the
    /// isolated posture this is Ask vs Auto; with the full user environment, the
    /// agent's own permissions apply first and Rubien can card only requests the
    /// provider actually emits. Reads/search are silent either way.
    private var approvalPicker: some View {
        Menu {
            Picker("Approvals", selection: $session.autoApprove) {
                if session.loadUserTools {
                    Label("Use agent permissions", systemImage: "hand.raised").tag(false)
                } else {
                    Label("Ask for approval", systemImage: "hand.raised").tag(false)
                }
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
        .help(session.loadUserTools
              ? "Approvals — existing agent permissions apply; Rubien shows a card when the agent asks"
              : "Approvals — Ask shows a card before writes/shell; Auto runs them automatically")
    }

    private var approvalPickerText: Text {
        let icon = session.autoApprove ? "bolt.fill" : "hand.raised"
        let word = session.autoApprove ? "Auto" : (session.loadUserTools ? "Agent" : "Ask")
        let tint: Color = session.autoApprove ? .orange : Color.primary.opacity(0.80)
        return ((Text(Image(systemName: icon)) + Text(" \(word)"))
            .foregroundStyle(tint)
            + Text(" ")
            + Text(Image(systemName: "chevron.down"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary))
            .font(.system(size: ChatSurfaceTypography.controlFontSize))
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
            .font(.system(size: ChatSurfaceTypography.controlFontSize))
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
        return text.font(.system(size: ChatSurfaceTypography.controlFontSize))
    }

    /// One compact empty-state block inside the editor. Keeping the heading and
    /// affordances together avoids the visual gap created when they were separate
    /// siblings in the composer box.
    private static let composerHintKeyWidth: CGFloat = 30
    private static let composerHintColumnSpacing: CGFloat = 8
    private static let composerHintGridSpacing: CGFloat = 12

    private var composerEmptyGuidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(configuration.isHome ? "Ask Rubien:" : "Chat about document:")
                .font(.system(size: ChatSurfaceTypography.controlFontSize, weight: .medium))
            HStack(alignment: .top, spacing: Self.composerHintGridSpacing) {
                VStack(alignment: .leading, spacing: 3) {
                    composerHint("⌘↩", "Send")
                    composerHint("⌘V", "Paste an image")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    composerHint("@", "Mention a paper", keyAlignment: .center)
                    composerHint("+", "Add files", keyAlignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 5)
        .foregroundStyle(.tertiary)
        .allowsHitTesting(false)
    }

    private func composerHint(
        _ key: String,
        _ label: String,
        keyAlignment: Alignment = .leading
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.composerHintColumnSpacing) {
            Text(key)
                .lineLimit(1)
                .frame(width: Self.composerHintKeyWidth, alignment: keyAlignment)
            Text(label)
        }
        .font(.system(size: ChatSurfaceTypography.controlFontSize))
    }

    private var composerEditor: some View {
        ZStack(alignment: .topLeading) {
            // Invisible sizer: the ZStack takes THIS text's height, so the editor
            // hugs its content (one line when empty) instead of greedily expanding
            // to the max — a bare TextEditor fills any height it is offered. The
            // trailing space makes a trailing newline count as a line.
            Text(draft.isEmpty ? " " : draft + " ")
                .font(.system(size: ComposerTextView.messageFontSize))
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0)
                .allowsHitTesting(false)
            if draft.isEmpty {
                composerEmptyGuidance
            }
            // AppKit-backed editor (not a `TextEditor`): it routes pasted/dropped
            // images and files into the attachment pipeline — a TextEditor's text
            // view swallows those (image ⌘V no-ops, file drops paste the path) —
            // owns ⌘↩-sends-exactly, and reports selection/key events for mentions.
            ComposerTextView(
                text: $draft,
                selection: $draftSelection,
                focusRequestCount: editorFocusRequests,
                onCommandReturn: sendDraft,
                onNavigationKey: handleComposerNavigationKey,
                onAttachFiles: { session.stageAttachments($0) },
                onAttachImageData: { session.stagePastedImage($0, suggestedName: $1) },
                onDragTargeted: { isDropTargeted = $0 }
            )
                .popover(
                    isPresented: mentionPopoverPresented,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    mentionSearchPopover
                }
        }
        // Grow with content up to ~6 lines, then the editor scrolls internally.
        .frame(maxHeight: 120)
        // Inner margin so the cursor/text never hugs the border.
        .padding(.vertical, 2)
    }

    /// Compact interrupt + send controls. During a response the arrow remains active
    /// so messages can queue; Stop ends the response and the queued batch starts next.
    private static let sendButtonShape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    private var composerButton: some View {
        HStack(spacing: 5) {
            if session.isResponding {
                Button {
                    session.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .frame(width: 27, height: 27)
                        .background(Self.sendButtonShape.fill(Color.primary.opacity(0.07)))
                        .contentShape(Self.sendButtonShape)
                }
                .buttonStyle(.plain)
                .disabled(session.isAwaitingTurnAdmission)
                .help(session.hasActiveQueuedMessageEdit
                    ? "Stop response; finish editing to send queued messages"
                    : session.hasQueuedMessages
                        ? "Interrupt and send queued messages (Esc)"
                        : "Stop response")
            }

            sendButton
        }
    }

    private var sendButton: some View {
        let canSend = session.canSend(draft: draft)
        return Button {
            sendDraft()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 27, height: 27)
                .background(Self.sendButtonShape.fill(
                    canSend ? Color.accentColor : Color.accentColor.opacity(0.5)))
                .contentShape(Self.sendButtonShape)
        }
        .buttonStyle(.plain)
        // No .keyboardShortcut here — ComposerNSTextView.performKeyEquivalent
        // owns ⌘↩ (a key equivalent on the button is the loose-matching pass
        // that made ⇧↩ send by accident).
        .disabled(!canSend)
        .help(sendButtonHelp(canSend: canSend))
    }

    private func sendButtonHelp(canSend: Bool) -> String {
        if session.hasActiveQueuedMessageEdit {
            return "Save or cancel the queued edit"
        }
        guard canSend else { return "Enter a message or add an attachment" }
        if session.isResponding {
            return "Queue message (⌘↩)"
        }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           session.hasQueuedMessages {
            return "Send queued messages"
        }
        return "Send (⌘↩)"
    }

    @ViewBuilder private var statusLine: some View {
        if session.isResuming {
            statusText("Loading conversation…", systemImage: "clock.arrow.circlepath")
        } else if session.busyElsewhere {
            statusText("Busy in another window", systemImage: "exclamationmark.triangle")
        } else if session.isResponding, session.queuedMessageCount > 0 {
            statusText(
                "Responding… · \(session.queuedMessageCount) \(session.queuedMessageCount == 1 ? "message" : "messages") queued",
                systemImage: "text.badge.plus")
        } else if session.hasActiveQueuedMessageEdit {
            statusText(
                "Finish editing to send queued messages",
                systemImage: "pencil")
        } else if session.queuedMessageCount > 0 {
            statusText(
                "\(session.queuedMessageCount) \(session.queuedMessageCount == 1 ? "message" : "messages") queued — press Send to retry",
                systemImage: "text.badge.plus")
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
            editorFocusRequests += 1
            return
        }
        let text = draft
        let mentions = selectedMentions
        if configuration.isHome, !session.hasMessages {
            // The controller publishes `hasMessages` only after the global gate
            // admits and commits the user turn. Until then, retain the exact draft,
            // attachments, and mention state so a gate refusal is retryable.
            pendingFreshHomeDraft = text
            // The Binding belongs to ContentView, not this transient Home subtree.
            // If the user switches to Library during gate acquisition, this still
            // clears the committed text while preserving any later edit.
            let externalDraft = $draft
            session.send(text, mentionedReferences: mentions) {
                if externalDraft.wrappedValue == text {
                    externalDraft.wrappedValue = ""
                }
            }
        } else {
            resetDraft()
            session.send(text, mentionedReferences: mentions)
        }
        editorFocusRequests += 1
    }

    // MARK: Paper mentions

    private var mentionPopoverPresented: Binding<Bool> {
        Binding(
            get: { activeMentionQuery != nil },
            set: { if !$0 { dismissMentionPopover() } }
        )
    }

    private var mentionSearchPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical")
                    .foregroundStyle(.secondary)
                Text(activeMentionQuery?.text.trimmingCharacters(in: .whitespaces).isEmpty == false
                    ? "Search library"
                    : "Mention a paper")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if mentionSearchInProgress {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if mentionResults.isEmpty, !mentionSearchInProgress {
                Text("No matching papers")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(mentionResults.enumerated()), id: \.element.id) { index, reference in
                                Button {
                                    completeMention(reference)
                                } label: {
                                    mentionResultRow(
                                        reference,
                                        selected: index == selectedMentionIndex
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(reference.id)
                            }
                        }
                        .padding(4)
                    }
                    .onChange(of: selectedMentionIndex) { _, index in
                        guard mentionResults.indices.contains(index) else { return }
                        proxy.scrollTo(mentionResults[index].id, anchor: .center)
                    }
                }
                // A ScrollView has no intrinsic height. A bare maxHeight lets the
                // popover stay at the tiny size it had while search was loading,
                // leaving only a sliver of the results visible.
                .frame(height: min(
                    CGFloat(mentionResults.count) * Self.mentionResultRowHeight + 8,
                    280
                ))
            }
        }
        .frame(width: 330)
    }

    private static let mentionResultRowHeight: CGFloat = 58

    private func mentionResultRow(_ reference: ChatReference, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 18, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(reference.title.isEmpty ? "Untitled" : reference.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !reference.authors.isEmpty {
                    Text(reference.authors)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.mentionResultRowHeight)
        .padding(.horizontal, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.11) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func refreshActiveMention() {
        guard let selection = draftSelection,
              selection.isEmpty,
              selection.lowerBound >= 0,
              let caret = draft.index(
                draft.startIndex,
                offsetBy: selection.lowerBound,
                limitedBy: draft.endIndex
              )
        else {
            dismissMentionPopover()
            return
        }

        let next = PaperMentions.activeQuery(
            in: draft,
            caret: caret,
            completed: selectedMentions
        )
        guard next != activeMentionQuery else { return }
        activeMentionQuery = next
        selectedMentionIndex = 0
        mentionSearchTask?.cancel()
        mentionResults = []

        guard let next else {
            mentionSearchInProgress = false
            return
        }
        mentionSearchInProgress = true
        mentionSearchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let results = await session.searchMentionableReferences(next.text)
            guard !Task.isCancelled, activeMentionQuery == next else { return }
            mentionResults = results
            selectedMentionIndex = 0
            mentionSearchInProgress = false
        }
    }

    private func scheduleMentionRefresh() {
        mentionRefreshTask?.cancel()
        mentionRefreshTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            refreshActiveMention()
        }
    }

    private func completeMention(_ reference: ChatReference) {
        guard let query = activeMentionQuery else { return }
        let completed = PaperMentions.completing(query, with: reference, in: draft)
        var mentions = PaperMentions.reconciling(
            selectedMentions,
            from: draft,
            to: completed.text
        )
        guard mentions.count < PaperMentions.maximumMentionsPerTurn else {
            dismissMentionPopover()
            return
        }
        mentions.append(PaperMentionSelection(
            reference: reference,
            range: completed.mentionRange
        ))
        selectedMentions = mentions
        activeMentionQuery = nil
        mentionSearchTask?.cancel()
        mentionSearchInProgress = false
        draftSelection = nil
        reconciledDraft = completed.text
        draft = completed.text
        draftSelection = completed.caretOffset..<completed.caretOffset
        editorFocusRequests += 1
    }

    private func handleComposerNavigationKey(_ key: ComposerNavigationKey) -> Bool {
        switch key {
        case .returnKey:
            guard activeMentionQuery != nil,
                  mentionResults.indices.contains(selectedMentionIndex)
            else { return false }
            completeMention(mentionResults[selectedMentionIndex])
        case .downArrow:
            guard activeMentionQuery != nil, !mentionResults.isEmpty else { return false }
            moveMentionSelection(by: 1)
        case .upArrow:
            guard activeMentionQuery != nil, !mentionResults.isEmpty else { return false }
            moveMentionSelection(by: -1)
        case .escape:
            if activeMentionQuery != nil {
                dismissMentionPopover()
            } else {
                return interruptAndSendQueuedIfPossible()
            }
        }
        return true
    }

    private func interruptAndSendQueuedIfPossible() -> Bool {
        session.interruptAndSendQueued()
    }

    private func moveMentionSelection(by delta: Int) {
        guard !mentionResults.isEmpty else { return }
        selectedMentionIndex = (selectedMentionIndex + delta + mentionResults.count)
            % mentionResults.count
    }

    private func dismissMentionPopover() {
        activeMentionQuery = nil
        mentionResults = []
        mentionSearchTask?.cancel()
        mentionSearchInProgress = false
    }

    private func resetDraft() {
        draftSelection = nil
        draft = ""
        selectedMentions = []
        reconciledDraft = nil
        dismissMentionPopover()
    }

    /// Move keyboard focus into the composer shortly after a selection is staged
    /// (Selection→Ask, §5.4). A focus request in the same runloop as a fresh pane
    /// mount doesn't take — the editor isn't in a window yet — so hop a runloop
    /// before requesting focus.
    private func focusComposerSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            editorFocusRequests += 1
        }
    }
}

// MARK: - Floating card (Phase 3a)

enum AssistantSidebarMetrics {
    /// The composer's 13-point single-line control row is the limiting intrinsic
    /// width. This floor keeps the default Agent / provider / model / effort
    /// labels and send control from crowding or forcing the panel wider than its
    /// resize binding reports.
    static let minimumWidth: CGFloat = 420
    static let maximumWidth: CGFloat = 900
    static let widthRange: ClosedRange<CGFloat> = minimumWidth...maximumWidth
}

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
        FloatingPanel(width: $width, range: AssistantSidebarMetrics.widthRange) {
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

/// Home history is deliberately narrower than the reader history browser: the
/// controller's library-context listing filters provider sessions through Rubien's
/// content-free attribution store, so unrelated CLI conversations never appear.
private struct HomeChatHistoryPopover: View {
    let session: ChatSessionController
    let onResumed: () -> Void

    @State private var sessions: [AgentSessionSummary]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Home conversations")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            Group {
                if let sessions {
                    if sessions.isEmpty {
                        Text("No Rubien Home conversations yet.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                        .frame(height: min(CGFloat(sessions.count) * HistoryRow.height, 340))
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
            Divider()
            Text("Only conversations started from Rubien Home are shown.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 320)
        .task { sessions = await session.listRecentSessions(limit: 25) }
    }
}

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

// MARK: - Quick-start suggestions

/// Home keeps the composer as the only card-like object. Suggestions are plain
/// text affordances with no icon, bezel, fill, or resting boundary. Hover uses
/// the same quiet neutral-gray background as Rubien's other borderless buttons.
private struct PlainQuickStartText: View {
    let text: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: ChatSurfaceTypography.controlFontSize))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 40)
                .padding(.trailing, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

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

/// A compact, neutral approval action (Allow / Deny). A soft filled + hairline pill
/// that deepens on hover/press — the normal highlight, no accent or red tint.
private struct ApprovalChoiceButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.85))
            .frame(minWidth: 58)
            .padding(.horizontal, 8)
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
