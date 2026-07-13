#if os(macOS)
import SwiftUI
import PDFKit
import Combine
import RubienCore

// MARK: - Annotation Tool

enum PDFSidebarTab: String, CaseIterable {
    case outline
    case search
    case annotations
    case info
}

enum PDFReaderMetrics {
    static let sidebarVisibleDividerWidth: CGFloat = 4
    static let sidebarResizeHitTargetWidth = ReaderResizeMetrics.hitTargetWidth

    static var sidebarResizeHitTargetOutset: CGFloat {
        (sidebarResizeHitTargetWidth - sidebarVisibleDividerWidth) / 2
    }

    static func sidebarWidth(
        afterTrailingEdgeTranslation translation: CGFloat,
        from width: CGFloat,
        in range: ClosedRange<CGFloat>
    ) -> CGFloat {
        min(max(width + translation, range.lowerBound), range.upperBound)
    }
}

enum AnnotationTool: String, CaseIterable {
    case cursor = "cursor"
    case highlight = "highlight"
    case underline = "underline"
    case note = "note"

    var icon: String {
        switch self {
        case .cursor: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .note: return "note.text"
        }
    }

    var label: String {
        switch self {
        case .cursor: return String(localized: "Select", bundle: .module)
        case .highlight: return String(localized: "Highlight", bundle: .module)
        case .underline: return String(localized: "Underline", bundle: .module)
        case .note: return String(localized: "Note", bundle: .module)
        }
    }
}

struct AnnotationColor: Identifiable {
    let id: String
    let name: String
    let nsColor: NSColor

    static let palette: [AnnotationColor] = [
        .init(id: "#FFDE59", name: String(localized: "Yellow", bundle: .module), nsColor: NSColor(red: 1.0, green: 0.87, blue: 0.35, alpha: 0.4)),
        .init(id: "#7ED957", name: String(localized: "Green", bundle: .module), nsColor: NSColor(red: 0.49, green: 0.85, blue: 0.34, alpha: 0.4)),
        .init(id: "#5CE1E6", name: String(localized: "Blue", bundle: .module), nsColor: NSColor(red: 0.36, green: 0.88, blue: 0.9, alpha: 0.4)),
        .init(id: "#FF66C4", name: String(localized: "Pink", bundle: .module), nsColor: NSColor(red: 1.0, green: 0.4, blue: 0.77, alpha: 0.4)),
        .init(id: "#FF914D", name: String(localized: "Orange", bundle: .module), nsColor: NSColor(red: 1.0, green: 0.57, blue: 0.3, alpha: 0.4)),
        .init(id: "#CB6CE6", name: String(localized: "Purple", bundle: .module), nsColor: NSColor(red: 0.80, green: 0.42, blue: 0.9, alpha: 0.4)),
    ]

    static func nsColor(for hex: String) -> NSColor {
        palette.first { $0.id == hex }?.nsColor ?? palette[0].nsColor
    }
}

// MARK: - Selection toolbar (PDF anchor + layout)

struct StagedSelectionPDFAnchor: Equatable {
    var pageIndex: Int
    var lastLineBounds: CGRect
}

struct SelectionToolbarLayout: Equatable {
    var center: CGPoint
    var visible: Bool
}

// MARK: - Search match

struct PDFSearchMatch: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let pageLabel: String
    let snippet: AttributedString
    let selection: PDFSelection
}

// MARK: - PDFReader ViewModel

@MainActor
final class PDFReaderViewModel: ObservableObject {
    @Published var annotations: [PDFAnnotationRecord] = []
    @Published var currentColorHex: String = "#FFDE59"
    @Published var selectedAnnotationId: Int64?
    @Published var showNoteEditor = false
    @Published var pendingNoteText = ""
    @Published var pendingNoteSelection: PDFSelection?
    @Published var pendingNotePageIndex: Int = 0
    @Published var pendingNoteRects: [CGRect] = []
    @Published var stagedSelectionText = ""
    @Published var stagedSelectionPDFAnchor: StagedSelectionPDFAnchor?
    @Published var selectionToolbarLayout: SelectionToolbarLayout?
    @Published var currentPageIndex: Int = 0
    @Published var totalPages: Int = 0
    @Published var scaleFactor: CGFloat = 1.0
    @Published var isDocumentLoading: Bool = false
    /// When set, shows a note-edit popover for an existing annotation (e.g. after clicking a highlight).
    @Published var editingAnnotationInPlace: PDFAnnotationRecord?
    /// When set, shows an annotation action toolbar near the clicked highlight.
    @Published var clickedAnnotationRecord: PDFAnnotationRecord?
    @Published var annotationToolbarLayout: SelectionToolbarLayout?

    // MARK: Search state
    @Published var searchQuery: String = ""
    @Published var searchMatches: [PDFSearchMatch] = []
    @Published var activeMatchIndex: Int? = nil
    @Published var searchCaseSensitive: Bool = false
    @Published var isSearchInProgress: Bool = false
    /// Bumped to request the search field steal first responder (e.g. when ⌘F is pressed).
    @Published var searchFocusRequest: UUID = UUID()

    let reference: Reference
    let pdfURL: URL
    private let db: AppDatabase
    private var cancellables = Set<AnyCancellable>()
    private var stagedSelection: PDFSelection?
    private(set) var stagedSelectionPageRects: [Int: [CGRect]] = [:]
    private var searchTask: Task<Void, Never>?

    weak var pdfView: PDFView?

    var jumpToAnnotation: ((PDFAnnotationRecord) -> Void)?
    var clearSelectionInView: (() -> Void)?
    var onPageChanged: ((Int, Int) -> Void)?
    /// Wired by PDFReaderView body; flips the left sidebar to the Search tab and focuses its field.
    var openSearchUI: (() -> Void)?

    init(reference: Reference, pdfURL: URL, db: AppDatabase = .shared) {
        self.reference = reference
        self.pdfURL = pdfURL
        self.db = db

        guard let refId = reference.id else { return }

        db.observeAnnotations(referenceId: refId)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        print("[PDFReaderViewModel] Annotation observation failed: \(error.localizedDescription)")
                    }
                },
                receiveValue: { [weak self] annotations in
                    self?.annotations = annotations
                }
            )
            .store(in: &cancellables)
    }

    deinit {
        searchTask?.cancel()
    }

    func addAnnotation(
        type: AnnotationType,
        selectedText: String?,
        noteText: String? = nil,
        pageIndex: Int,
        rects: [CGRect]
    ) {
        guard let refId = reference.id else { return }
        var record = PDFAnnotationRecord(
            referenceId: refId,
            type: type,
            selectedText: selectedText,
            noteText: noteText,
            color: currentColorHex,
            pageIndex: pageIndex,
            rects: rects
        )
        try? db.saveAnnotation(&record)
    }

    func addAnnotations(
        type: AnnotationType,
        selectedText: String?,
        noteText: String? = nil,
        pageRects: [Int: [CGRect]]
    ) {
        guard let refId = reference.id else { return }
        var records: [PDFAnnotationRecord] = []
        for pageIndex in pageRects.keys.sorted() {
            guard let rects = pageRects[pageIndex], !rects.isEmpty else { continue }
            records.append(
                PDFAnnotationRecord(
                    referenceId: refId,
                    type: type,
                    selectedText: selectedText,
                    noteText: noteText,
                    color: currentColorHex,
                    pageIndex: pageIndex,
                    rects: rects
                )
            )
        }
        try? db.saveAnnotations(&records)
    }

    func deleteAnnotation(_ annotation: PDFAnnotationRecord) {
        guard let id = annotation.id else { return }
        try? db.deleteAnnotation(id: id)
    }

    func updateAnnotationNote(_ annotation: PDFAnnotationRecord, noteText: String) {
        var updated = annotation
        updated.noteText = noteText.isEmpty ? nil : noteText
        try? db.saveAnnotation(&updated)
    }

    func updateAnnotationColor(_ annotation: PDFAnnotationRecord, color: String) {
        var updated = annotation
        updated.color = color
        try? db.saveAnnotation(&updated)
    }

    func dismissAnnotationToolbar() {
        clickedAnnotationRecord = nil
        annotationToolbarLayout = nil
    }

    // MARK: Search

    func runSearch(query: String) {
        searchTask?.cancel()
        searchQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchTask = nil
            searchMatches = []
            activeMatchIndex = nil
            isSearchInProgress = false
            pdfView?.clearSelection()
            return
        }
        guard let document = pdfView?.document else { return }
        isSearchInProgress = true
        let caseSensitive = searchCaseSensitive
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            let selections = document.findString(trimmed, withOptions: opts)
            if Task.isCancelled { return }
            let matches = Self.makeSearchMatches(from: selections, query: trimmed, caseSensitive: caseSensitive)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.searchMatches = matches
                self.activeMatchIndex = matches.isEmpty ? nil : 0
                self.isSearchInProgress = false
                if !matches.isEmpty {
                    self.gotoMatch(at: 0)
                } else {
                    self.pdfView?.clearSelection()
                }
            }
        }
    }

    func gotoMatch(at index: Int) {
        guard index >= 0, index < searchMatches.count, let pdfView else { return }
        activeMatchIndex = index
        let match = searchMatches[index]
        pdfView.setCurrentSelection(match.selection, animate: true)
        pdfView.scrollSelectionToVisible(nil)
    }

    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        let next = ((activeMatchIndex ?? -1) + 1) % searchMatches.count
        gotoMatch(at: next)
    }

    func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        let prev = ((activeMatchIndex ?? 0) - 1 + searchMatches.count) % searchMatches.count
        gotoMatch(at: prev)
    }

    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchQuery = ""
        searchMatches = []
        activeMatchIndex = nil
        isSearchInProgress = false
        pdfView?.clearSelection()
    }

    nonisolated private static func makeSearchMatches(from selections: [PDFSelection], query: String, caseSensitive: Bool) -> [PDFSearchMatch] {
        var matches: [PDFSearchMatch] = []
        matches.reserveCapacity(selections.count)
        var pageStringCache: [ObjectIdentifier: NSString] = [:]
        let contextSize = 40
        for selection in selections {
            guard let page = selection.pages.first,
                  let document = page.document else { continue }
            let pageKey = ObjectIdentifier(page)
            let pageNS: NSString
            if let cached = pageStringCache[pageKey] {
                pageNS = cached
            } else {
                guard let pageString = page.string else { continue }
                pageNS = pageString as NSString
                pageStringCache[pageKey] = pageNS
            }
            let pageRange = selection.range(at: 0, on: page)
            guard pageRange.location != NSNotFound, pageRange.length > 0 else { continue }
            let pageLen = pageNS.length
            let start = max(0, pageRange.location - contextSize)
            let end = min(pageLen, pageRange.location + pageRange.length + contextSize)
            guard end > start else { continue }
            var window = pageNS.substring(with: NSRange(location: start, length: end - start))
            window = window.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = start > 0 ? "…" : ""
            let suffixEllipsis = end < pageLen ? "…" : ""
            var attributed = AttributedString(prefix + window + suffixEllipsis)
            if let matchRange = attributed.range(of: query, options: caseSensitive ? [] : [.caseInsensitive]) {
                attributed[matchRange].inlinePresentationIntent = .stronglyEmphasized
                attributed[matchRange].foregroundColor = .accentColor
            }
            let pageIndex = document.index(for: page)
            let pageLabel = page.label ?? "\(pageIndex + 1)"
            matches.append(PDFSearchMatch(pageIndex: pageIndex, pageLabel: pageLabel, snippet: attributed, selection: selection))
        }
        return matches
    }

    func navigateTo(_ annotation: PDFAnnotationRecord) {
        selectedAnnotationId = annotation.id
        jumpToAnnotation?(annotation)
    }

    var annotationsByPage: [Int: [PDFAnnotationRecord]] {
        Dictionary(grouping: annotations, by: \.pageIndex)
    }

    var hasStagedSelection: Bool {
        !stagedSelectionText.isEmpty && !stagedSelectionPageRects.isEmpty
    }

    func stageSelection(_ selection: PDFSelection, pageRects: [Int: [CGRect]], pdfAnchor: StagedSelectionPDFAnchor?) {
        let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, !pageRects.isEmpty else {
            clearStagedSelection(clearViewSelection: false)
            return
        }

        stagedSelection = selection
        stagedSelectionPageRects = pageRects
        stagedSelectionText = text
        stagedSelectionPDFAnchor = pdfAnchor
    }

    func clearStagedSelection(clearViewSelection: Bool = true) {
        stagedSelection = nil
        stagedSelectionPageRects = [:]
        stagedSelectionText = ""
        stagedSelectionPDFAnchor = nil
        selectionToolbarLayout = nil
        if clearViewSelection {
            clearSelectionInView?()
        }
    }

    func clearPendingNoteDraft() {
        pendingNoteText = ""
        pendingNoteSelection = nil
        pendingNotePageIndex = 0
        pendingNoteRects = []
    }

    func applySelectionAction(_ tool: AnnotationTool) {
        guard tool != .cursor else { return }
        guard hasStagedSelection else { return }

        if tool == .note {
            pendingNoteSelection = stagedSelection
            pendingNoteText = ""
            pendingNotePageIndex = stagedSelectionPageRects.keys.sorted().first ?? 0
            pendingNoteRects = stagedSelectionPageRects[pendingNotePageIndex] ?? []
            showNoteEditor = true
            clearStagedSelection()
            return
        }

        let annotationType: AnnotationType = tool == .underline ? .underline : .highlight
        addAnnotations(
            type: annotationType,
            selectedText: stagedSelectionText,
            pageRects: stagedSelectionPageRects
        )
        clearStagedSelection()
    }
}

// MARK: - Main Reader

struct PDFReaderView: View {
    @StateObject private var viewModel: PDFReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showOutlineSidebar = true
    @State private var outlineSidebarWidth: CGFloat = 240
    @State private var outlineDragOffset: CGFloat = 0
    @State private var outlineSidebarTab: PDFSidebarTab = .outline
    @State private var isEditingPage = false
    @State private var pageInputText = ""
    /// Note-draft text for the selection popover. Lifted from the deleted SelectionActionBar
    /// so the shared AnnotationSelectionPopover can take a Binding into the same state across
    /// rebuilds, and so `.onChange(of: viewModel.stagedSelectionText)` below can reset it on
    /// external dismissal paths (selection cleared from PDFKit, etc.).
    @State private var noteMarkdownForSelection: String = ""
    private let onClose: (() -> Void)?

    // Assistant chat (Phase 3a): one renderer + session controller per reader
    // window; conversation state is in-memory only (D5). Floats as a card over
    // the content (details-panel idiom), not a docked pane.
    @State private var showChatSidebar: Bool
    @State private var chatPanelWidth: CGFloat = 380

    @StateObject private var chatRenderer: ChatTranscriptController
    @StateObject private var chatSession: ChatSessionController

    init(reference: Reference, pdfURL: URL, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        self._showChatSidebar = State(initialValue: RubienPreferences.assistantSidebarVisible)
        self._viewModel = StateObject(wrappedValue: PDFReaderViewModel(reference: reference, pdfURL: pdfURL))
        // Live session from the user's Assistant settings via the shared production
        // factory (Phase 2c-5) — same path as the web reader.
        let renderer = ChatTranscriptController()
        self._chatRenderer = StateObject(wrappedValue: renderer)
        self._chatSession = StateObject(wrappedValue: ReaderChatSession.make(
            reference: reference, transcript: renderer))
    }

    /// Convenience initializer that resolves the PDF URL via the cache.
    /// Returns nil if the reference has no materialized PDF on disk —
    /// callers should render a "no PDF" placeholder instead.
    init?(reference: Reference, db: AppDatabase, onClose: (() -> Void)? = nil) {
        guard let id = reference.id,
              let filename = try? db.pdfFilename(for: id) else { return nil }
        let url = AppDatabase.pdfStorageURL.appendingPathComponent(filename)
        self.init(reference: reference, pdfURL: url, onClose: onClose)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar: TOC / Info
            if showOutlineSidebar {
                PDFReaderSidebarView(reference: viewModel.reference, viewModel: viewModel, selectedTab: $outlineSidebarTab)
                    .frame(width: min(max(outlineSidebarWidth + outlineDragOffset, 200), 400))
                    .transition(.move(edge: .leading))

                ZStack {
                    ReaderResizeHandle(
                        onDragChanged: { translation in
                            outlineDragOffset = translation
                        },
                        onDragEnded: { translation in
                            outlineSidebarWidth = PDFReaderMetrics.sidebarWidth(
                                afterTrailingEdgeTranslation: translation,
                                from: outlineSidebarWidth,
                                in: 200...400
                            )
                            outlineDragOffset = 0
                        }
                    )
                        .frame(width: PDFReaderMetrics.sidebarResizeHitTargetWidth)
                        .frame(maxHeight: .infinity)

                    Rectangle()
                        .fill(pdfContainerBackground)
                        .frame(width: PDFReaderMetrics.sidebarVisibleDividerWidth)
                        .frame(maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
                    .padding(.horizontal, -PDFReaderMetrics.sidebarResizeHitTargetOutset)
            }

            // Elevated plane: center PDF + right annotation sidebar
            HStack(spacing: 0) {
                ZStack {
                    AnnotatablePDFView(viewModel: viewModel)
                        .padding(6)
                        .overlay {
                            selectionActionBarOverlay
                        }
                        .overlay {
                            annotationActionBarOverlay
                        }

                    if viewModel.isDocumentLoading {
                        ProgressView(String(localized: "Loading PDF…", bundle: .module))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .liquidGlassSurface(in: Capsule(), fallback: .regularMaterial)
                            .padding(.top, 14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 6, x: 0, y: 2)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 8)
                // Reflow, don't occlude: shrink the white plane by the chat
                // card's width so the page refits beside it. +4 keeps a 6 pt gap
                // to the card given the 8 pt gutter above and the card's insets.
                // (Tracks committed widths — during a card-resize drag the plane
                // reflows on release, not per frame.)
                .padding(.trailing, showChatSidebar ? chatPanelWidth + 4 : 0)
                .background(pdfContainerBackground)
                .ignoresSafeArea(.container, edges: .top)

            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background {
            pdfContainerBackground
                .ignoresSafeArea(.container, edges: .top)
        }
        // The assistant floats over the PDF as a resizable card (Phase 3a,
        // details-panel idiom). It owns the trailing edge — all document aids
        // (outline/search/notes/info) live in the LEFT sidebar's tabs.
        .overlay(alignment: .trailing) {
            if showChatSidebar {
                FloatingChatPanel(session: chatSession, renderer: chatRenderer, width: $chatPanelWidth) {
                    setChatSidebarVisible(false)
                }
                .padding(.trailing, 6)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showChatSidebar)
        .animation(.easeInOut(duration: 0.22), value: chatPanelWidth)
        // Window closing (the root view disappears): kill any in-flight agent
        // turn's process group (§4.4 step 9).
        .onDisappear { chatSession.teardown() }
        .animation(
            .spring(response: 0.3, dampingFraction: 0.82),
            value: showOutlineSidebar
        )
        .animation(
            .spring(response: 0.3, dampingFraction: 0.82),
            value: viewModel.hasStagedSelection && viewModel.selectionToolbarLayout?.visible == true
        )
        .navigationTitle(viewModel.reference.title)
        .legacyToolbarBackground(pdfContainerBackground, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    withAnimation { showOutlineSidebar.toggle() }
                } label: {
                    Label(String(localized: "Outline", bundle: .module), systemImage: "sidebar.left")
                }
                .help(String(localized: "Toggle outline sidebar", bundle: .module))

                Button(action: zoomOut) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help(String(localized: "Zoom out", bundle: .module))

                Button(action: zoomIn) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help(String(localized: "Zoom in", bundle: .module))

                Button(action: fitToWidth) {
                    Label(String(localized: "Fit width", bundle: .module), systemImage: "arrow.left.and.right")
                }
                .help(String(localized: "Fit width", bundle: .module))

                pageIndicator
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // No annotations button — the left sidebar's Notes tab is the
                // (sole, sufficient) way in; the right edge belongs to the assistant.
                Button {
                    setChatSidebarVisible(!showChatSidebar)
                } label: {
                    Label(String(localized: "Assistant", bundle: .module), systemImage: "bubble.left.and.text.bubble.right")
                }
                .help(String(localized: "Chat about this document", bundle: .module))
            }
        }
        .onAppear {
            NoteEditorPool.shared.warmUp()
            viewModel.openSearchUI = {
                if !showOutlineSidebar {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        showOutlineSidebar = true
                    }
                }
                outlineSidebarTab = .search
                viewModel.searchFocusRequest = UUID()
            }
        }
        // Reset the lifted note draft whenever the staged-selection text changes
        // (cleared, replaced, or transitioned to empty) so external dismissal paths
        // — i.e. anything that clears selection without going through our onDismiss
        // closure — don't leak stale note text into the next selection's popover.
        .onChange(of: viewModel.stagedSelectionText) { _, _ in
            noteMarkdownForSelection = ""
        }
    }

    /// `persist` writes the global default (the toolbar toggle and explicit close do).
    /// Selection→Ask passes `persist: false` so a one-off Ask reveals the panel for THIS
    /// window without overwriting a user who deliberately hid the assistant.
    private func setChatSidebarVisible(_ visible: Bool, persist: Bool = true) {
        showChatSidebar = visible
        if persist { RubienPreferences.assistantSidebarVisible = visible }
    }

    @ViewBuilder
    private var selectionActionBarOverlay: some View {
        let shouldShow = viewModel.hasStagedSelection
            && viewModel.selectionToolbarLayout?.visible == true
        if shouldShow, let layout = viewModel.selectionToolbarLayout {
            GeometryReader { geo in
                AnnotationSelectionPopover(
                    currentColorHex: $viewModel.currentColorHex,
                    noteMarkdown: $noteMarkdownForSelection,
                    onHighlight: { viewModel.applySelectionAction(.highlight) },
                    onUnderline: { viewModel.applySelectionAction(.underline) },
                    onPickColor: { _ in viewModel.applySelectionAction(.highlight) },
                    onSaveNote: { md in
                        viewModel.addAnnotations(
                            type: .note,
                            selectedText: viewModel.stagedSelectionText,
                            noteText: md,
                            pageRects: viewModel.stagedSelectionPageRects
                        )
                        viewModel.clearStagedSelection()
                        noteMarkdownForSelection = ""
                    },
                    onDismiss: {
                        viewModel.clearStagedSelection()
                        noteMarkdownForSelection = ""
                    },
                    onAsk: {
                        let text = viewModel.stagedSelectionText
                        guard !text.isEmpty else { return }
                        // 0-based PDFKit page index → the 1-based "(p. N)" label (§5.4).
                        chatSession.stageSelection(
                            text,
                            pageNumber: (viewModel.stagedSelectionPDFAnchor?.pageIndex).map { $0 + 1 })
                        viewModel.clearStagedSelection()
                        noteMarkdownForSelection = ""
                        setChatSidebarVisible(true, persist: false)
                    }
                )
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(
                    x: clampedPopoverX(center: layout.center.x, containerWidth: geo.size.width),
                    y: layout.center.y - 17
                )
                .allowsHitTesting(true)
            }
            .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
            .animation(.spring(response: 0.25, dampingFraction: 0.82), value: layout.center)
        }
    }

    @ViewBuilder
    private var annotationActionBarOverlay: some View {
        if let annotation = viewModel.clickedAnnotationRecord,
           let layout = viewModel.annotationToolbarLayout, layout.visible {
            GeometryReader { geo in
                ExistingAnnotationPopover(
                    annotationId: AnyHashable(annotation.id ?? -1),
                    currentColor: annotation.color,
                    initialNoteText: annotation.noteText,
                    onPickColor: { hex in
                        viewModel.updateAnnotationColor(annotation, color: hex)
                        if let updated = viewModel.annotations.first(where: { $0.id == annotation.id }) {
                            viewModel.clickedAnnotationRecord = updated
                        }
                    },
                    onDelete: {
                        viewModel.deleteAnnotation(annotation)
                        viewModel.dismissAnnotationToolbar()
                    },
                    onNoteAutosave: { trimmed in
                        if let ann = viewModel.clickedAnnotationRecord {
                            viewModel.updateAnnotationNote(ann, noteText: trimmed)
                        }
                    },
                    onDismiss: { viewModel.dismissAnnotationToolbar() }
                )
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(
                    x: clampedPopoverX(center: layout.center.x, containerWidth: geo.size.width),
                    y: layout.center.y - 17
                )
                .allowsHitTesting(true)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var pageIndicator: some View {
        if isEditingPage {
            TextField("", text: $pageInputText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .frame(width: 44)
                .textFieldStyle(.plain)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
                .onSubmit {
                    if let page = Int(pageInputText), page >= 1, page <= viewModel.totalPages {
                        if let pdfView = findPDFView(),
                           let doc = pdfView.document,
                           let target = doc.page(at: page - 1) {
                            pdfView.go(to: target)
                        }
                    }
                    isEditingPage = false
                }
        } else {
            Text(pageDisplayText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .frame(minWidth: 54)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .onTapGesture {
                    pageInputText = "\(viewModel.currentPageIndex + 1)"
                    isEditingPage = true
                }
        }
    }

    private var pageDisplayText: String {
        guard viewModel.totalPages > 0 else { return "PDF" }
        return "\(viewModel.currentPageIndex + 1)/\(viewModel.totalPages)"
    }

    private var pdfContainerBackground: Color {
        Color(nsColor: NSColor(name: nil) { trait in
            trait.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.15, alpha: 1.0)
                : NSColor(calibratedWhite: 0.90, alpha: 1.0)
        })
    }

    private func zoomIn() {
        guard let pdfView = findPDFView() else { return }
        let newScale = min(pdfView.scaleFactor * 1.2, 5.0)
        pdfView.scaleFactor = newScale
        viewModel.scaleFactor = newScale
    }

    private func zoomOut() {
        guard let pdfView = findPDFView() else { return }
        let newScale = max(pdfView.scaleFactor * 0.8, 0.5)
        pdfView.scaleFactor = newScale
        viewModel.scaleFactor = newScale
    }

    private func fitToWidth() {
        guard let pdfView = findPDFView() else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.0
        viewModel.scaleFactor = 1.0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pdfView.autoScales = true
        }
    }

    private func findPDFView() -> PDFView? {
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return nil }
        return findPDFViewInView(contentView)
    }

    private func findPDFViewInView(_ view: NSView) -> PDFView? {
        if let pdfView = view as? PDFView {
            return pdfView
        }
        for subview in view.subviews {
            if let found = findPDFViewInView(subview) {
                return found
            }
        }
        return nil
    }
}

// Popover chrome lives in `AnnotationPopovers.swift` (shared with WebReaderView).
// Adapters are constructed inline at the overlay call sites
// (`selectionActionBarOverlay`, `annotationActionBarOverlay`).

// MARK: - PDFKit Bridge

final class CommitAwarePDFView: PDFView {
    var onSelectionCommitted: ((PDFSelection) -> Void)?
    var onSelectionCleared: (() -> Void)?
    var onAnnotationClicked: ((PDFAnnotation) -> Void)?
    var onShowSearchUI: (() -> Void)?
    var onLinkHoverChanged: ((PDFAnnotation?, CGRect) -> Void)?

    /// Arrow key codes (left, right, down, up) for keyboard text-selection extension.
    private static let arrowKeyCodes: ClosedRange<Int> = 0x7B...0x7E

    private var userIsSelecting = false
    private var hoverTrackingArea: NSTrackingArea?
    private weak var hoveredLinkAnnotation: PDFAnnotation?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "f" {
            onShowSearchUI?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        userIsSelecting = true
        resetHoveredLinkPreview()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)

        let wasUserSelecting = userIsSelecting
        userIsSelecting = false

        if wasUserSelecting,
           let selection = currentSelection,
           let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            commitSelectionIfNeeded()
            return
        }

        if let ann = annotationAtClick(event) {
            onAnnotationClicked?(ann)
            return
        }

        if wasUserSelecting {
            onSelectionCleared?()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)

        guard !userIsSelecting else {
            resetHoveredLinkPreview()
            return
        }

        guard let (annotation, page) = linkAnnotation(at: event) else {
            resetHoveredLinkPreview()
            return
        }

        if hoveredLinkAnnotation === annotation {
            return
        }

        hoveredLinkAnnotation = annotation
        let rectInView = convert(annotation.bounds.standardized, from: page)
        onLinkHoverChanged?(annotation, rectInView)
    }

    override func mouseExited(with event: NSEvent) {
        resetHoveredLinkPreview()
        super.mouseExited(with: event)
    }

    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        // Only commit on shift+arrow (keyboard text-selection extend); never on bare keystrokes,
        // which would fire on every keystroke after a programmatic selection (search, outline jump).
        let isArrow = Self.arrowKeyCodes.contains(Int(event.keyCode))
        if event.modifierFlags.contains(.shift), isArrow, currentSelection != nil {
            commitSelectionIfNeeded()
        }
    }

    private func annotationAtClick(_ event: NSEvent) -> PDFAnnotation? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: true) else { return nil }
        let pagePoint = convert(point, to: page)
        return page.annotation(at: pagePoint)
    }

    func resetHoveredLinkPreview(notify: Bool = true) {
        let hadHoveredLink = hoveredLinkAnnotation != nil
        hoveredLinkAnnotation = nil
        if notify, hadHoveredLink {
            onLinkHoverChanged?(nil, .zero)
        }
    }

    private func linkAnnotation(at event: NSEvent) -> (annotation: PDFAnnotation, page: PDFPage)? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: true) else { return nil }
        let pagePoint = convert(point, to: page)
        guard let annotation = page.annotation(at: pagePoint),
              PDFLinkPreviewResolver.isPreviewableLink(annotation) else {
            return nil
        }
        return (annotation, page)
    }

    private func commitSelectionIfNeeded() {
        guard let selection = currentSelection,
              let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            onSelectionCleared?()
            return
        }

        if let copiedSelection = selection.copy() as? PDFSelection {
            onSelectionCommitted?(copiedSelection)
        } else {
            onSelectionCommitted?(selection)
        }
    }
}

struct AnnotatablePDFView: NSViewRepresentable {
    @ObservedObject var viewModel: PDFReaderViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = CommitAwarePDFView()
        let canvasBackgroundColor = NSColor(name: nil) { trait in
            trait.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.18, alpha: 1.0)
                : NSColor(calibratedWhite: 0.94, alpha: 1.0)
        }
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.pageShadowsEnabled = false
        pdfView.backgroundColor = canvasBackgroundColor
        pdfView.applyElegantScrollers()

        // Remove NSScrollView bezel border and keep the inner PDF canvas subtly gray.
        DispatchQueue.main.async { [weak pdfView] in
            guard let sv = pdfView?.internalScrollView else { return }
            sv.borderType = .noBorder
            sv.backgroundColor = canvasBackgroundColor
            sv.drawsBackground = true
            sv.contentView.backgroundColor = canvasBackgroundColor
        }

        context.coordinator.pdfView = pdfView
        viewModel.pdfView = pdfView
        context.coordinator.loadDocument(from: viewModel.pdfURL, into: pdfView)
        pdfView.onSelectionCommitted = { [weak coordinator = context.coordinator] selection in
            coordinator?.handleCommittedSelection(selection)
        }
        pdfView.onAnnotationClicked = { [weak coordinator = context.coordinator] ann in
            coordinator?.handleAnnotationClicked(ann)
        }
        pdfView.onSelectionCleared = { [weak coordinator = context.coordinator] in
            coordinator?.handleClearedSelection()
        }
        pdfView.onShowSearchUI = { [weak viewModel = self.viewModel] in
            viewModel?.openSearchUI?()
        }
        pdfView.onLinkHoverChanged = { [weak coordinator = context.coordinator] annotation, sourceRect in
            coordinator?.handleLinkHoverChanged(annotation, sourceRectInView: sourceRect)
        }

        DispatchQueue.main.async { [weak coordinator = context.coordinator, weak pdfView] in
            guard let coordinator, let pdfView else { return }
            coordinator.ensureObservers(for: pdfView)
        }

        viewModel.clearSelectionInView = { [weak pdfView] in
            pdfView?.clearSelection()
        }

        viewModel.jumpToAnnotation = { [weak pdfView] annotation in
            guard let pdfView = pdfView,
                  let document = pdfView.document,
                  annotation.pageIndex < document.pageCount,
                  let page = document.page(at: annotation.pageIndex) else { return }
            navigateToAnnotation(in: pdfView, page: page, bounds: annotation.unionBounds)
        }

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.viewModel = viewModel

        guard let pdfView = pdfView as? CommitAwarePDFView else { return }

        pdfView.onSelectionCommitted = { [weak coordinator = context.coordinator] selection in
            coordinator?.handleCommittedSelection(selection)
        }
        pdfView.onAnnotationClicked = { [weak coordinator = context.coordinator] ann in
            coordinator?.handleAnnotationClicked(ann)
        }
        pdfView.onSelectionCleared = { [weak coordinator = context.coordinator] in
            coordinator?.handleClearedSelection()
        }
        pdfView.onShowSearchUI = { [weak viewModel = context.coordinator.viewModel] in
            viewModel?.openSearchUI?()
        }
        pdfView.onLinkHoverChanged = { [weak coordinator = context.coordinator] annotation, sourceRect in
            coordinator?.handleLinkHoverChanged(annotation, sourceRectInView: sourceRect)
        }

        context.coordinator.ensureObservers(for: pdfView)
        viewModel.pdfView = pdfView
        viewModel.clearSelectionInView = { [weak pdfView] in
            pdfView?.clearSelection()
        }

        context.coordinator.loadDocument(from: viewModel.pdfURL, into: pdfView)

        pdfView.applyElegantScrollers()

        // Skip syncAnnotations if annotations haven't changed (hash check)
        let currentHash = viewModel.annotations.hashValue
        if currentHash != context.coordinator.lastAnnotationsHash {
            context.coordinator.lastAnnotationsHash = currentHash
            syncAnnotations(pdfView: pdfView, records: viewModel.annotations, coordinator: context.coordinator)
        }
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.teardownObservers()
        coordinator.cancelDocumentLoad()
        coordinator.closeLinkPreview()
        pdfView.document = nil
    }

    private func syncAnnotations(pdfView: PDFView, records: [PDFAnnotationRecord], coordinator: Coordinator) {
        guard let document = pdfView.document else { return }

        let existingKeys = Set(coordinator.trackedAnnotations.keys)
        let recordKeys = Set(records.compactMap { $0.id })

        let removedKeys = existingKeys.subtracting(recordKeys)
        for key in removedKeys {
            if let tracked = coordinator.trackedAnnotations[key],
               let page = document.page(at: tracked.pageIndex) {
                page.removeAnnotation(tracked.annotation)
            }
            coordinator.trackedAnnotations.removeValue(forKey: key)
        }

        for record in records {
            guard let recordId = record.id else { continue }
            let recordHash = record.renderHash

            if let tracked = coordinator.trackedAnnotations[recordId],
               tracked.renderHash == recordHash {
                continue
            }

            if let tracked = coordinator.trackedAnnotations[recordId],
               let existingPage = document.page(at: tracked.pageIndex) {
                existingPage.removeAnnotation(tracked.annotation)
            }

            if record.pageIndex < document.pageCount,
               let page = document.page(at: record.pageIndex) {
                let annotation = createPDFAnnotation(from: record)
                page.addAnnotation(annotation)
                coordinator.trackedAnnotations[recordId] = TrackedAnnotation(
                    annotation: annotation,
                    pageIndex: record.pageIndex,
                    renderHash: recordHash
                )
            }
        }
    }

    private func createPDFAnnotation(from record: PDFAnnotationRecord) -> PDFAnnotation {
        let bounds = record.unionBounds
        let color = AnnotationColor.nsColor(for: record.color)
        let rects = record.rects

        let annotation: PDFAnnotation
        switch record.type {
        case .highlight:
            annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = color
        case .underline:
            annotation = PDFAnnotation(bounds: bounds, forType: .underline, withProperties: nil)
            annotation.color = color.withAlphaComponent(0.8)
        case .note:
            annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = color
        }

        if !rects.isEmpty {
            annotation.quadrilateralPoints = buildQuadrilateralPoints(from: rects, relativeTo: bounds)
        }

        if let noteText = record.noteText, !noteText.isEmpty {
            annotation.contents = noteText
        }

        return annotation
    }

    private func buildQuadrilateralPoints(from rects: [CGRect], relativeTo union: CGRect) -> [NSValue] {
        rects.flatMap { rect -> [NSValue] in
            let relativeRect = rect.offsetBy(dx: -union.minX, dy: -union.minY)
            let topLeft = CGPoint(x: relativeRect.minX, y: relativeRect.maxY)
            let topRight = CGPoint(x: relativeRect.maxX, y: relativeRect.maxY)
            let bottomLeft = CGPoint(x: relativeRect.minX, y: relativeRect.minY)
            let bottomRight = CGPoint(x: relativeRect.maxX, y: relativeRect.minY)
            return [topLeft, topRight, bottomLeft, bottomRight].map(NSValue.init(point:))
        }
    }

    private func navigateToAnnotation(in pdfView: PDFView, page: PDFPage, bounds: CGRect) {
        let focusRect = bounds.insetBy(dx: -120, dy: -200)
        pdfView.go(to: focusRect, on: page)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            flashAnnotation(in: pdfView, page: page, bounds: bounds)
        }
    }

    private func flashAnnotation(in pdfView: PDFView, page: PDFPage, bounds: CGRect) {
        let flashBounds = bounds.insetBy(dx: -1.5, dy: -1.5)
        let flashAnnotation = PDFAnnotation(bounds: flashBounds, forType: .highlight, withProperties: nil)
        flashAnnotation.color = NSColor.systemBlue.withAlphaComponent(0.22)
        page.addAnnotation(flashAnnotation)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            page.removeAnnotation(flashAnnotation)
        }
    }

    struct TrackedAnnotation {
        let annotation: PDFAnnotation
        let pageIndex: Int
        let renderHash: Int
    }

    class Coordinator: NSObject {
        var viewModel: PDFReaderViewModel
        weak var pdfView: PDFView?
        var trackedAnnotations: [Int64: TrackedAnnotation] = [:]
        var lastAnnotationsHash: Int = 0

        private var scrollObserver: NSObjectProtocol?
        private var scaleObserver: NSObjectProtocol?
        private var pageChangedObserver: NSObjectProtocol?
        private weak var observedClipView: NSClipView?
        private weak var scaleObservedPDFView: PDFView?
        private weak var pageObservedPDFView: PDFView?
        private var loadedPDFURL: URL?
        private var documentLoadTask: Task<Void, Never>?
        private var toolbarDebounceTask: Task<Void, Never>?
        private var linkPreviewTask: Task<Void, Never>?
        private let linkPreviewPopover = PDFLinkPreviewPopoverController()
        private var lastToolbarCenter: CGPoint = .zero
        private var lastToolbarVisible: Bool = false

        init(viewModel: PDFReaderViewModel) {
            self.viewModel = viewModel
        }

        deinit {
            teardownObservers()
            cancelDocumentLoad()
            toolbarDebounceTask?.cancel()
            linkPreviewTask?.cancel()
            linkPreviewPopover.close()
        }

        func ensureObservers(for pdfView: PDFView) {
            if let clip = pdfView.internalScrollView?.contentView, observedClipView !== clip {
                removeScrollObserver()
                observedClipView = clip
                clip.postsBoundsChangedNotifications = true
                scrollObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clip,
                    queue: .main
                ) { [weak self] _ in
                    self?.closeLinkPreview(resetHoverState: true)
                    self?.requestToolbarLayoutUpdate()
                }
            }

            if scaleObservedPDFView !== pdfView {
                removeScaleObserver()
                scaleObservedPDFView = pdfView
                scaleObserver = NotificationCenter.default.addObserver(
                    forName: .PDFViewScaleChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self] _ in
                    self?.closeLinkPreview(resetHoverState: true)
                    self?.requestToolbarLayoutUpdate()
                }
            }

            if pageObservedPDFView !== pdfView {
                removePageChangedObserver()
                pageObservedPDFView = pdfView
                pageChangedObserver = NotificationCenter.default.addObserver(
                    forName: .PDFViewPageChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self, weak pdfView] _ in
                    self?.closeLinkPreview(resetHoverState: true)
                    guard let self, let pdfView,
                          let document = pdfView.document,
                          let firstPage = document.page(at: 0) else { return }
                    let currentPage = document.index(for: pdfView.currentPage ?? firstPage)
                    self.updatePageInfo(current: currentPage, total: document.pageCount)
                }
            }
        }

        @MainActor
        func loadDocument(from url: URL, into pdfView: PDFView) {
            // Same URL: skip if doc already loaded OR a load task is already in flight.
            // The in-flight check prevents re-entrancy: setting `isDocumentLoading = true`
            // below fires objectWillChange, which re-renders body → updateNSView → here.
            // Without this guard we'd cancel and restart the task on every re-render.
            if loadedPDFURL == url, pdfView.document != nil || documentLoadTask != nil {
                return
            }

            cancelDocumentLoad()
            closeLinkPreview(resetHoverState: true)
            loadedPDFURL = url
            self.pdfView = pdfView
            viewModel.isDocumentLoading = true

            documentLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
                let document = PDFDocument(url: url)
                guard !Task.isCancelled else { return }
                await self?.finishLoadingDocument(document, for: url)
            }
        }

        @MainActor
        private func finishLoadingDocument(_ document: PDFDocument?, for url: URL) {
            guard loadedPDFURL == url, let pdfView else { return }
            pdfView.document = document
            viewModel.isDocumentLoading = false
            let canvasBackgroundColor = NSColor(name: nil) { trait in
                trait.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(calibratedWhite: 0.18, alpha: 1.0)
                    : NSColor(calibratedWhite: 0.94, alpha: 1.0)
            }
            if let scrollView = pdfView.internalScrollView {
                scrollView.backgroundColor = canvasBackgroundColor
                scrollView.contentView.backgroundColor = canvasBackgroundColor
            }
            ensureObservers(for: pdfView)
            if let document,
               let firstPage = document.page(at: 0) {
                let currentPage = document.index(for: pdfView.currentPage ?? firstPage)
                updatePageInfo(current: currentPage, total: document.pageCount)
            } else {
                viewModel.currentPageIndex = 0
                viewModel.totalPages = 0
            }
        }

        func cancelDocumentLoad() {
            documentLoadTask?.cancel()
            documentLoadTask = nil
        }

        func teardownObservers() {
            closeLinkPreview(resetHoverState: true)
            removeScrollObserver()
            removeScaleObserver()
            removePageChangedObserver()
        }

        private func removeScrollObserver() {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            scrollObserver = nil
            observedClipView = nil
        }

        private func removeScaleObserver() {
            if let scaleObserver {
                NotificationCenter.default.removeObserver(scaleObserver)
            }
            scaleObserver = nil
            scaleObservedPDFView = nil
        }

        private func removePageChangedObserver() {
            if let pageChangedObserver {
                NotificationCenter.default.removeObserver(pageChangedObserver)
            }
            pageChangedObserver = nil
            pageObservedPDFView = nil
        }

        private func requestToolbarLayoutUpdate() {
            toolbarDebounceTask?.cancel()
            toolbarDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 16_000_000) // ~1 frame (16ms)
                guard !Task.isCancelled else { return }
                self?.updateSelectionToolbarLayout()
            }
        }

        @MainActor
        func updateSelectionToolbarLayout() {
            let barW: CGFloat = 168
            let barH: CGFloat = 34
            let gap: CGFloat = 2
            let margin: CGFloat = 8

            guard viewModel.hasStagedSelection,
                  let anchor = viewModel.stagedSelectionPDFAnchor,
                  let pdfView,
                  let document = pdfView.document,
                  anchor.pageIndex >= 0,
                  anchor.pageIndex < document.pageCount,
                  let page = document.page(at: anchor.pageIndex) else {
                viewModel.selectionToolbarLayout = nil
                lastToolbarVisible = false
                return
            }

            // convert(_:from: page) returns coordinates in PDFView's view space,
            // which has its origin at the lower-left corner (Y increases upward).
            // The SwiftUI overlay has origin at top-left (Y increases downward),
            // so we must flip Y.
            let rectInView = pdfView.convert(anchor.lastLineBounds, from: page)
            guard !rectInView.isNull, !rectInView.isEmpty else {
                viewModel.selectionToolbarLayout = SelectionToolbarLayout(center: .zero, visible: false)
                return
            }

            let overlayW = pdfView.bounds.width
            let overlayH = pdfView.bounds.height

            if !rectInView.intersects(pdfView.bounds) {
                viewModel.selectionToolbarLayout = SelectionToolbarLayout(center: .zero, visible: false)
                return
            }

            // Flip Y: PDFView origin is bottom-left, SwiftUI overlay origin is top-left
            let lineTopSwift = overlayH - rectInView.maxY
            let lineBottomSwift = overlayH - rectInView.minY

            var centerY: CGFloat
            let belowY = lineBottomSwift + gap + barH / 2
            let aboveY = lineTopSwift - gap - barH / 2
            if belowY + barH / 2 <= overlayH - margin {
                centerY = belowY
            } else if aboveY - barH / 2 >= margin {
                centerY = aboveY
            } else {
                centerY = max(margin + barH / 2, min(belowY, overlayH - barH / 2 - margin))
            }
            centerY = min(max(centerY, barH / 2 + margin), overlayH - barH / 2 - margin)

            var centerX = rectInView.maxX
            centerX = min(max(centerX, barW / 2 + margin), overlayW - barW / 2 - margin)

            let newCenter = CGPoint(x: centerX, y: centerY)
            // Skip SwiftUI re-render if position unchanged
            if lastToolbarVisible && lastToolbarCenter == newCenter {
                return
            }
            lastToolbarCenter = newCenter
            lastToolbarVisible = true

            viewModel.selectionToolbarLayout = SelectionToolbarLayout(
                center: newCenter,
                visible: true
            )
        }

        func handleCommittedSelection(_ selection: PDFSelection) {
            let pageRects = rectsByPage(for: selection)
            let pdfAnchor: StagedSelectionPDFAnchor?
            if let doc = pdfView?.document {
                pdfAnchor = Self.lastLinePDFAnchor(for: selection, document: doc)
            } else {
                pdfAnchor = nil
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                viewModel.dismissAnnotationToolbar()
                viewModel.stageSelection(selection, pageRects: pageRects, pdfAnchor: pdfAnchor)
                updateSelectionToolbarLayout()
            }
        }

        func handleAnnotationClicked(_ annotation: PDFAnnotation) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                closeLinkPreview(resetHoverState: true)
                // Clear any active text selection toolbar
                viewModel.clearStagedSelection(clearViewSelection: true)
                for (id, tracked) in trackedAnnotations where tracked.annotation === annotation {
                    viewModel.selectedAnnotationId = id
                    if let record = viewModel.annotations.first(where: { $0.id == id }) {
                        viewModel.clickedAnnotationRecord = record
                        computeAnnotationToolbarLayout(for: record)
                    }
                    return
                }
            }
        }

        func handleLinkHoverChanged(_ annotation: PDFAnnotation?, sourceRectInView: CGRect) {
            linkPreviewTask?.cancel()
            linkPreviewTask = nil

            guard let annotation else {
                closeLinkPreview()
                return
            }

            guard let pdfView,
                  let document = pdfView.document,
                  let target = PDFLinkPreviewResolver.target(
                      for: annotation,
                      in: document,
                      displayBox: pdfView.displayBox
                  ) else {
                closeLinkPreview()
                return
            }

            let anchorRect = sourceRectInView.standardized.insetBy(dx: -2, dy: -2)
            linkPreviewTask = Task { @MainActor [weak self, weak pdfView] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                guard let self, let pdfView else { return }
                guard !self.viewModel.hasStagedSelection,
                      self.viewModel.annotationToolbarLayout?.visible != true else {
                    self.closeLinkPreview(resetHoverState: true)
                    return
                }
                guard let document = pdfView.document,
                      target.destinationPageIndex >= 0,
                      target.destinationPageIndex < document.pageCount,
                      let page = document.page(at: target.destinationPageIndex),
                      let image = self.previewImage(for: target, page: page, in: pdfView) else {
                    self.closeLinkPreview(resetHoverState: true)
                    return
                }

                self.linkPreviewPopover.show(
                    image: image,
                    target: target,
                    relativeTo: anchorRect,
                    of: pdfView
                )
            }
        }

        func closeLinkPreview(resetHoverState: Bool = false) {
            linkPreviewTask?.cancel()
            linkPreviewTask = nil
            linkPreviewPopover.close()

            if resetHoverState {
                (pdfView as? CommitAwarePDFView)?.resetHoveredLinkPreview(notify: false)
            }
        }

        private func previewImage(for target: PDFLinkPreviewTarget, page: PDFPage, in pdfView: PDFView) -> NSImage? {
            let backingScale = pdfView.window?.backingScaleFactor
                ?? pdfView.window?.screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2

            guard let image = PDFLinkPreviewResolver.renderPreview(
                page: page,
                cropRect: target.cropRect,
                backingScale: backingScale,
                appearance: pdfView.effectiveAppearance,
                displayBox: target.displayBox
            ) else {
                return nil
            }

            return image
        }

        /// Compute position for the annotation action toolbar based on annotation bounds.
        @MainActor
        func computeAnnotationToolbarLayout(for annotation: PDFAnnotationRecord) {
            let margin: CGFloat = 8

            guard let pdfView,
                  let document = pdfView.document,
                  annotation.pageIndex >= 0,
                  annotation.pageIndex < document.pageCount,
                  let page = document.page(at: annotation.pageIndex) else {
                viewModel.annotationToolbarLayout = nil
                return
            }

            let bounds = annotation.unionBounds
            let rectInView = pdfView.convert(bounds, from: page)
            guard !rectInView.isNull, !rectInView.isEmpty else {
                viewModel.annotationToolbarLayout = nil
                return
            }

            let overlayW = pdfView.bounds.width
            let overlayH = pdfView.bounds.height

            guard rectInView.intersects(pdfView.bounds) else {
                viewModel.annotationToolbarLayout = nil
                return
            }

            // Flip Y
            let lineBottomSwift = overlayH - rectInView.minY
            let barH: CGFloat = 34
            let gap: CGFloat = 4
            var centerY = lineBottomSwift + gap + barH / 2
            centerY = min(max(centerY, barH / 2 + margin), overlayH - barH / 2 - margin)

            var centerX = rectInView.midX
            let barW: CGFloat = 200
            centerX = min(max(centerX, barW / 2 + margin), overlayW - barW / 2 - margin)

            viewModel.annotationToolbarLayout = SelectionToolbarLayout(
                center: CGPoint(x: centerX, y: centerY),
                visible: true
            )
        }

        static func lastLinePDFAnchor(for selection: PDFSelection, document: PDFDocument) -> StagedSelectionPDFAnchor? {
            let lines = selection.selectionsByLine()
            guard let lastLine = lines.last else { return nil }

            var chosenPage: PDFPage?
            var chosenBounds: CGRect = .null
            for page in lastLine.pages {
                let bounds = lastLine.bounds(for: page).standardized
                guard !bounds.isNull, !bounds.isEmpty, bounds.width > 0, bounds.height > 0 else { continue }
                chosenPage = page
                chosenBounds = bounds
            }
            guard let page = chosenPage, !chosenBounds.isNull else { return nil }
            let idx = document.index(for: page)
            return StagedSelectionPDFAnchor(pageIndex: idx, lastLineBounds: chosenBounds)
        }

        func handleClearedSelection() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                viewModel.clearStagedSelection(clearViewSelection: false)
                viewModel.dismissAnnotationToolbar()
            }
        }

        func updatePageInfo(current: Int, total: Int) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                viewModel.currentPageIndex = current
                viewModel.totalPages = total
                viewModel.scaleFactor = pdfView?.scaleFactor ?? viewModel.scaleFactor
                viewModel.onPageChanged?(current, total)
            }
        }

        private func rectsByPage(for selection: PDFSelection) -> [Int: [CGRect]] {
            guard let document = pdfView?.document else { return [:] }

            var pageRects: [Int: [CGRect]] = [:]
            for lineSelection in selection.selectionsByLine() {
                for page in lineSelection.pages {
                    let bounds = lineSelection.bounds(for: page).standardized
                    guard !bounds.isNull, !bounds.isEmpty, bounds.width > 0, bounds.height > 0 else {
                        continue
                    }
                    let pageIndex = document.index(for: page)
                    pageRects[pageIndex, default: []].append(bounds)
                }
            }

            return pageRects
        }
    }
}

#endif
