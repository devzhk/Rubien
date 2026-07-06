#if os(macOS)
import SwiftUI
import WebKit
import Combine
import AppKit
import OSLog
import RubienCore

/// Online-reading pipeline log. In Console.app filter subsystem `Rubien`, category `OnlineReadable`.
private let onlineReadableLog = Logger(subsystem: "Rubien", category: "OnlineReadable")

// MARK: - Reading mode (clipped markdown / live Defuddle+Readability fallback)

enum WebReaderDisplayMode: String, CaseIterable {
    /// Show the reference's clipped, extracted content (refreshable via toolbar button).
    case clip = "Clip"
    /// Load the source URL in WKWebView with no extraction (read-only browser view).
    case original = "Original"
}

struct WebSelectionSnapshot: Equatable {
    var text: String
    var prefixText: String
    var suffixText: String
    /// 选区在网页视口内的矩形（与 `getBoundingClientRect()` 一致，原点在左上）。
    var viewportSelectionRect: CGRect?
}

@MainActor
final class WebReaderViewModel: ObservableObject {
    @Published var annotations: [WebAnnotationRecord] = []
    @Published var currentColorHex: String = "#FFDE59"
    @Published var selectedAnnotationId: Int64?
    @Published var showNoteEditor = false
    @Published var pendingNoteText = ""
    @Published var pendingSelection: WebSelectionSnapshot?
    @Published var selectionToolbarLayout: SelectionToolbarLayout?
    /// When set, shows a note-edit sheet for an existing annotation.
    @Published var editingAnnotationInPlace: WebAnnotationRecord?
    /// When set, shows an annotation action toolbar near the clicked highlight.
    @Published var clickedAnnotationRecord: WebAnnotationRecord?
    @Published var annotationToolbarLayout: SelectionToolbarLayout?
    @Published var renderedHTML = ""
    @Published var isRendering = false
    @Published var fontSize: Double = 18
    @Published var contentWidth: CGFloat = 860
    @Published var displayMode: WebReaderDisplayMode = .clip
    @Published var isExtracting = false
    @Published var extractionUserMessage: String?
    /// 为 true 时 `WebReaderContentView` 下一次更新会发起对原文 URL 的导航以便抽取正文。
    private(set) var shouldLoadOriginalURLForExtraction = false
    /// 递增以触发侧栏滚动到「摘要」卡片（正文内摘要被点击时）。
    @Published var sidebarSummaryScrollToken: UInt64 = 0
    /// 侧栏摘要卡片是否处于「正文摘要已点击」高亮。
    @Published var highlightSidebarSummary: Bool = false
    var reference: Reference
    private let db: AppDatabase
    private var cancellables = Set<AnyCancellable>()
    /// 在线阅读整段流程（加载原文 + 注入脚本 + 抽取 + 组 HTML）防挂起超时。
    private var extractionSafetyTask: Task<Void, Never>?
    private var currentArticleBodyHTML: String?
    /// Debounce task for appearance changes (font size / content width).
    private var appearanceDebounceTask: Task<Void, Never>?

    var jumpToAnnotationInView: ((WebAnnotationRecord) -> Void)?
    var jumpToSummaryInWeb: (() -> Void)?
    /// 停止正在进行的原文加载 / Readability 流程（切回「剪藏正文」时调用）。
    var resetExtractionNavigation: (() -> Void)?
    var clearSelectionInView: (() -> Void)?
    var updateAppearanceInView: ((Double, CGFloat) -> Void)?
    var refreshAnnotationsInView: (([WebAnnotationRecord]) -> Void)?

    init(reference: Reference, db: AppDatabase = .shared) {
        self.reference = reference
        self.db = db
        observeAnnotations()
        // Re-fetch the webContent column from disk so a stale snapshot from a
        // list view (captured before a prior persistLiveBodyToReference write
        // committed) doesn't force us back into live mode despite the row on
        // disk already carrying webContent.
        if let refId = reference.id, let fresh = try? db.fetchWebContent(id: refId) {
            self.reference.webContent = fresh
        }
        let clipEmpty = self.reference.decodedWebContent == nil
        let urlStr = self.reference.resolvedWebReaderURLString()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let canAutoExtract = self.reference.referenceType == .webpage && clipEmpty && !urlStr.isEmpty && URL(string: urlStr) != nil
        if canAutoExtract {
            // Fresh add (no webContent yet): show an empty document and
            // auto-trigger a refresh. Stays in .clip mode — the refresh
            // populates webContent and re-renders.
            renderedHTML = Self.emptyDocument(title: self.reference.title)
            Task { @MainActor [weak self] in
                self?.refreshClipContent()
            }
        } else {
            renderContent()
        }
    }

    /// Trigger a fresh extraction of the source URL. Stays in `.clip` mode;
    /// the Coordinator's `updateNSView` will load the URL, didFinish will
    /// inject Defuddle, and `applyReadableExtractionResult` will swap
    /// in the new content + persist it to `reference.webContent`.
    func refreshClipContent() {
        guard displayMode == .clip else { return }
        guard !isExtracting else { return }
        let urlStr = reference.resolvedWebReaderURLString() ?? ""
        guard !urlStr.isEmpty, URL(string: urlStr) != nil else {
            extractionUserMessage = String(localized: "No valid URL available to refresh from.", bundle: .module)
            return
        }
        shouldLoadOriginalURLForExtraction = true
        isExtracting = true
        scheduleExtractionSafetyTimeout()
        let host = URL(string: urlStr)?.host ?? ""
        onlineReadableLog.notice("Refreshing clip content host=\(host, privacy: .public) using bundled ClipperDefuddle.js")
    }

    var allowsDisplayModeSwitching: Bool {
        reference.referenceType == .webpage
    }

    var hasSelection: Bool {
        !(pendingSelection?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func stageSelection(_ selection: WebSelectionSnapshot?, viewportSize: CGSize) {
        let trimmed = selection?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            if selectionToolbarLayout?.visible == true, pendingSelection != nil { return }
            pendingSelection = nil
            selectionToolbarLayout = nil
            return
        }

        guard let selection else {
            pendingSelection = nil
            selectionToolbarLayout = nil
            return
        }

        // Only dismiss the existing-annotation popover once we know we have a
        // real new selection to stage. Calling it unconditionally above would
        // also tear down the existing-annotation popover on transient empty-
        // selection events that don't end up changing the staged selection.
        dismissAnnotationToolbar()

        pendingSelection = WebSelectionSnapshot(
            text: trimmed,
            prefixText: selection.prefixText,
            suffixText: selection.suffixText,
            viewportSelectionRect: selection.viewportSelectionRect
        )
        selectionToolbarLayout = Self.toolbarLayout(
            viewportSelectionRect: selection.viewportSelectionRect,
            viewportSize: viewportSize
        )
    }

    func clearSelection(clearViewSelection: Bool = true) {
        pendingSelection = nil
        selectionToolbarLayout = nil
        dismissAnnotationToolbar()
        if clearViewSelection {
            clearSelectionInView?()
        }
    }

    func applySelectionAction(_ type: AnnotationType) {
        guard let pendingSelection else { return }

        if type == .note {
            pendingNoteText = ""
            showNoteEditor = true
            return
        }

        addAnnotation(type: type, selection: pendingSelection, noteText: nil)
        clearSelection()
    }

    func commitPendingNote() {
        guard let pendingSelection else { return }
        let trimmed = pendingNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        addAnnotation(type: .note, selection: pendingSelection, noteText: trimmed)
        pendingNoteText = ""
        showNoteEditor = false
        clearSelection()
    }

    func cancelPendingNote() {
        pendingNoteText = ""
        showNoteEditor = false
    }

    func deleteAnnotation(_ annotation: WebAnnotationRecord) {
        guard let id = annotation.id else { return }
        try? db.deleteWebAnnotation(id: id)
    }

    func updateAnnotationNote(_ annotation: WebAnnotationRecord, noteText: String) {
        var updated = annotation
        updated.noteText = noteText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        try? db.saveWebAnnotation(&updated)
    }

    func updateAnnotationColor(_ annotation: WebAnnotationRecord, color: String) {
        var updated = annotation
        updated.color = color
        try? db.saveWebAnnotation(&updated)
    }

    func dismissAnnotationToolbar() {
        clickedAnnotationRecord = nil
        annotationToolbarLayout = nil
    }

    func navigateTo(_ annotation: WebAnnotationRecord) {
        selectedAnnotationId = annotation.id
        highlightSidebarSummary = false
        jumpToAnnotationInView?(annotation)
    }

    /// 侧栏摘要卡片点击：滚动正文到摘要块。
    func scrollArticleToSummary() {
        highlightSidebarSummary = false
        jumpToSummaryInWeb?()
    }

    /// 正文内摘要区域被点击：侧栏滚到摘要卡片并高亮。
    func onArticleSummaryTapped() {
        selectedAnnotationId = nil
        highlightSidebarSummary = true
        sidebarSummaryScrollToken &+= 1
    }

    var hasSidebarSummary: Bool {
        let a = reference.abstract?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !a.isEmpty
    }

    func setDisplayMode(_ mode: WebReaderDisplayMode) {
        guard mode != displayMode else { return }
        extractionUserMessage = nil
        displayMode = mode
        switch mode {
        case .clip:
            // Cancel any in-flight Original-page load; updateNSView will
            // re-render the clipped HTML.
            cancelExtractionSafetyTimeout()
            shouldLoadOriginalURLForExtraction = false
            isExtracting = false
            resetExtractionNavigation?()
            renderContent()
        case .original:
            let u = reference.resolvedWebReaderURLString() ?? ""
            guard !u.isEmpty, URL(string: u) != nil else {
                extractionUserMessage = String(localized: "No valid URL available for the original page.", bundle: .module)
                displayMode = .clip
                return
            }
            // Cancel any in-flight refresh extraction. resetExtractionNavigation
            // clears awaitingReadableExtraction AND stops the WKWebView load —
            // otherwise didFinish would inject Defuddle into the Original-page
            // navigation when it finishes.
            cancelExtractionSafetyTimeout()
            shouldLoadOriginalURLForExtraction = false
            isExtracting = false
            resetExtractionNavigation?()
        }
    }

    private func scheduleExtractionSafetyTimeout() {
        extractionSafetyTask?.cancel()
        let seconds: UInt64 = 90
        extractionSafetyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard displayMode == .clip, isExtracting else { return }
            let fmt = String(localized: "Refreshing the article timed out (~%d seconds). Check your network and try again.", bundle: .module)
            readableExtractionFailed(message: String(format: fmt, seconds))
        }
    }

    private func cancelExtractionSafetyTimeout() {
        extractionSafetyTask?.cancel()
        extractionSafetyTask = nil
    }

    /// 由 Coordinator 在开始加载原文 URL 后调用，避免重复触发导航。
    func acknowledgeOriginalURLLoadStarted() {
        shouldLoadOriginalURLForExtraction = false
    }

    func readableExtractionFailed(message: String) {
        cancelExtractionSafetyTimeout()
        isExtracting = false
        extractionUserMessage = message
        onlineReadableLog.error("Online reading failed: \(message, privacy: .public)")
        displayMode = .clip
        renderContent()
    }

    func applyReadableExtractionResult(
        title: String?,
        contentHTML: String,
        excerpt: String?,
        byline: String?,
        includeClipperTypography: Bool,
        eyebrowText: String = ""
    ) {
        let trimmed = contentHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            readableExtractionFailed(message: String(localized: "Refresh failed: extraction returned no content.", bundle: .module))
            return
        }

        isExtracting = true
        let ref = reference
        let fs = fontSize
        let cw = contentWidth
        let finalBody = trimmed

        Task.detached(priority: .userInitiated) {
            let html = Self.buildHTMLDocument(
                reference: ref,
                articleBodyHTML: finalBody,
                fontSize: fs,
                contentWidth: cw,
                eyebrowText: eyebrowText,
                headerTitle: title,
                summaryText: excerpt,
                authorOverride: byline,
                includeClipperTypography: includeClipperTypography,
                omitReferenceAbstract: false,
                omitArticleHeader: false
            )
            await MainActor.run {
                self.currentArticleBodyHTML = finalBody
                self.renderedHTML = html
                self.isExtracting = false
                self.cancelExtractionSafetyTimeout()
                // Cache the live-extracted body so subsequent reader opens
                // render from storage instead of re-fetching + re-extracting
                // online every time.
                self.persistLiveBodyToReference(finalBody)
            }
        }
    }

    /// Save a freshly live-extracted article body back to `reference.webContent`
    /// so the next reader open displays the clipped copy immediately rather than
    /// kicking off another network fetch + Defuddle/Readability pass.
    private func persistLiveBodyToReference(_ articleBodyHTML: String) {
        guard let referenceID = reference.id,
              let encoded = Reference.encodeWebContent(articleBodyHTML, format: .html) else {
            onlineReadableLog.notice("Skipped persisting live-extracted body refId=\(self.reference.id ?? -1, privacy: .public) (encode failed or no id)")
            return
        }
        // Update the in-memory reference immediately so the user toggling to the
        // Clipped tab in the same session renders from the live-extracted body
        // instead of an empty document. The detached DB write below carries the
        // same encoded value to disk for subsequent sessions.
        reference.webContent = encoded
        let db = self.db
        let length = articleBodyHTML.count
        Task.detached(priority: .utility) {
            do {
                try db.updateReferenceWebContent(id: referenceID, webContent: encoded)
                onlineReadableLog.notice("Persisted live-extracted body refId=\(referenceID, privacy: .public) length=\(length, privacy: .public)")
            } catch {
                onlineReadableLog.error("Failed to persist live-extracted body refId=\(referenceID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func increaseFontSize() {
        fontSize = min(fontSize + 1, 26)
        notifyAppearanceChanged()
    }

    func decreaseFontSize() {
        fontSize = max(fontSize - 1, 13)
        notifyAppearanceChanged()
    }

    func narrowContent() {
        contentWidth = max(contentWidth - 60, 620)
        notifyAppearanceChanged()
    }

    func widenContent() {
        contentWidth = min(contentWidth + 60, 1200)
        notifyAppearanceChanged()
    }

    /// 与 PDF 选区工具栏相同的尺寸与上下优先策略（坐标为 SwiftUI 自上而下、视口与 WKWebView 对齐）。
    static func toolbarLayout(viewportSelectionRect: CGRect?, viewportSize: CGSize) -> SelectionToolbarLayout? {
        let barW: CGFloat = 180
        let barH: CGFloat = 50
        let gap: CGFloat = 12
        let margin: CGFloat = 6

        let overlayW = viewportSize.width
        let overlayH = viewportSize.height

        if overlayW <= 0 || overlayH <= 0 {
            return nil
        }

        guard let rect = viewportSelectionRect, rect.width >= 1, rect.height >= 1 else {
            return SelectionToolbarLayout(
                center: CGPoint(x: overlayW / 2, y: barH / 2 + margin),
                visible: true
            )
        }

        let visibleRect = CGRect(origin: .zero, size: viewportSize)
        guard rect.intersects(visibleRect) else {
            return SelectionToolbarLayout(center: .zero, visible: false)
        }

        let midX = rect.midX
        let lineTopSwift = rect.minY
        let lineBottomSwift = rect.maxY

        var centerY: CGFloat
        let belowY = lineBottomSwift + gap + barH / 2
        let aboveY = lineTopSwift - gap - barH / 2
        if belowY + barH / 2 <= overlayH - margin {
            centerY = belowY
        } else if aboveY - barH / 2 >= margin {
            centerY = aboveY
        } else {
            centerY = belowY
        }
        centerY = min(max(centerY, barH / 2 + margin), overlayH - barH / 2 - margin)

        var centerX = midX
        centerX = min(max(centerX, barW / 2 + margin), overlayW - barW / 2 - margin)

        return SelectionToolbarLayout(center: CGPoint(x: centerX, y: centerY), visible: true)
    }

    private func observeAnnotations() {
        guard let refId = reference.id else { return }

        db.observeWebAnnotations(referenceId: refId)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        onlineReadableLog.error("Web annotation observation failed: \(error.localizedDescription, privacy: .public)")
                    }
                },
                receiveValue: { [weak self] annotations in
                    guard let self else { return }
                    self.annotations = annotations
                    self.refreshAnnotationsInView?(annotations)
                }
            )
            .store(in: &cancellables)
    }

    func addAnnotation(type: AnnotationType, selection: WebSelectionSnapshot, noteText: String?) {
        guard let refId = reference.id else { return }
        var annotation = WebAnnotationRecord(
            referenceId: refId,
            type: type,
            noteText: noteText,
            color: currentColorHex,
            anchorText: selection.text,
            prefixText: selection.prefixText.nilIfBlank,
            suffixText: selection.suffixText.nilIfBlank
        )
        try? db.saveWebAnnotation(&annotation)
    }

    private func notifyAppearanceChanged() {
        // Debounce: wait 80 ms so rapid button taps are coalesced into one JS call.
        appearanceDebounceTask?.cancel()
        let fs = fontSize
        let cw = contentWidth
        appearanceDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 80_000_000) // 80 ms
            guard !Task.isCancelled else { return }
            self.updateAppearanceInView?(fs, cw)
        }
    }

    private func renderContent() {
        guard let storedContent = reference.decodedWebContent else {
            renderedHTML = Self.emptyDocument(title: reference.title)
            return
        }

        isRendering = true
        let reference = self.reference
        let fontSize = self.fontSize
        let contentWidth = self.contentWidth

        Task.detached(priority: .userInitiated) {
            let includeClipperTypography = storedContent.format == .html
            let bodyHTML: String
            switch storedContent.format {
            case .markdown:
                bodyHTML = Self.renderedMarkdownHTML(
                    from: storedContent.body,
                    baseURL: reference.resolvedWebReaderURLString().flatMap(URL.init(string:))
                )
            case .html:
                bodyHTML = storedContent.body
            }

            let html = Self.buildHTMLDocument(
                reference: reference,
                articleBodyHTML: bodyHTML,
                fontSize: fontSize,
                contentWidth: contentWidth,
                eyebrowText: "Clipped",
                includeClipperTypography: includeClipperTypography,
                omitReferenceAbstract: false,
                omitArticleHeader: false
            )
            await MainActor.run {
                self.currentArticleBodyHTML = bodyHTML
                self.renderedHTML = html
                self.isRendering = false
            }
        }
    }

    /// 合并 Obsidian Web Clipper 的 `reader.css` 与 `highlighter.css`（打包于 Resources）。
    nonisolated private static func bundledClipperReaderStyleBlock() -> String? {
        guard let urlR = Bundle.module.url(forResource: "ClipperReader", withExtension: "css"),
              let urlH = Bundle.module.url(forResource: "ClipperHighlighter", withExtension: "css"),
              let r = try? String(contentsOf: urlR, encoding: .utf8),
              let h = try? String(contentsOf: urlH, encoding: .utf8) else {
            return nil
        }
        return r + "\n" + h
    }

    /// KaTeX (math typesetting) head injection. CSS + JS + auto-render are inlined
    /// directly into the rendered HTML; woff2 fonts are base64-data-URI substituted
    /// in the CSS so we don't need a custom WKURLSchemeHandler and the rendering
    /// works offline. One-time-cached at first access.
    nonisolated private static let bundledKaTeXHeadInjection: String = {
        guard
            let cssURL = Bundle.module.url(forResource: "katex.min", withExtension: "css"),
            let jsURL  = Bundle.module.url(forResource: "katex.min", withExtension: "js"),
            let arURL  = Bundle.module.url(forResource: "auto-render.min", withExtension: "js"),
            let rawCSS = try? String(contentsOf: cssURL, encoding: .utf8),
            let jsBody = try? String(contentsOf: jsURL,  encoding: .utf8),
            let arBody = try? String(contentsOf: arURL,  encoding: .utf8)
        else { return "" }
        let inlined = inlineKaTeXFontsAsDataURIs(in: rawCSS)
        return """
          <style>\(inlined)</style>
          <script>\(jsBody)</script>
          <script>\(arBody)</script>
        """
    }()

    /// Rewrites `url(KaTeX_*.woff2)` references in KaTeX CSS to inline `data:` URIs
    /// by looking each woff2 up at the bundle root (flat layout — see CLAUDE.md
    /// resource attachment notes). Unknown filenames are left untouched so KaTeX
    /// degrades to default browser fonts for that variant.
    nonisolated private static func inlineKaTeXFontsAsDataURIs(in css: String) -> String {
        let pattern = #"url\(\s*["']?([^"')]+\.woff2)["']?\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return css
        }
        let ns = css as NSString
        var output = ""
        var cursor = 0
        let matches = regex.matches(in: css, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            guard m.numberOfRanges >= 2 else { continue }
            let full = m.range(at: 0)
            let fileRel = ns.substring(with: m.range(at: 1))
            output += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            let filename = (fileRel as NSString).lastPathComponent
            let stem = (filename as NSString).deletingPathExtension
            if let fontURL = Bundle.module.url(forResource: stem, withExtension: "woff2"),
               let data = try? Data(contentsOf: fontURL) {
                output += "url(data:font/woff2;base64,\(data.base64EncodedString()))"
            } else {
                output += ns.substring(with: full)
            }
            cursor = full.location + full.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    /// - Parameters:
    ///   - articleBodyHTML: 已生成的 HTML 片段（Markdown 渲染结果或 Readability 的 `content`），不做 HTML 转义。
    ///   - headerTitle/summaryText/authorOverride: 在线阅读时可用抽取结果覆盖条目元数据展示。
    ///   - omitReferenceAbstract: 为 true 时头部摘要仅使用 `summaryText`（可为空），不回退到 `reference.abstract`。
    ///   - includeClipperTypography: 为 true 时注入 Obsidian Clipper 的 `reader.css` / `highlighter.css` 及主题 class（与 Defuddle 在线阅读配套）。
    nonisolated private static func buildHTMLDocument(
        reference: Reference,
        articleBodyHTML: String,
        fontSize: Double,
        contentWidth: CGFloat,
        eyebrowText: String = "Web Article",
        headerTitle: String? = nil,
        summaryText: String? = nil,
        authorOverride: String? = nil,
        includeClipperTypography: Bool = false,
        omitReferenceAbstract: Bool = false,
        omitArticleHeader: Bool = false
    ) -> String {
        let rawHeaderTitle = (headerTitle ?? reference.title).trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = rawHeaderTitle.isEmpty ? reference.title : rawHeaderTitle
        let title = htmlEscape(displayTitle)

        let rawAuthor = authorOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = htmlEscape(rawAuthor.isEmpty ? reference.authors.displayString : rawAuthor)

        let rawSummary: String
        if omitReferenceAbstract {
            rawSummary = (summaryText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            rawSummary = (summaryText ?? reference.abstract ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let summary = htmlEscape(rawSummary)

        let siteRaw = (reference.siteName ?? reference.journal ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let urlRaw = (reference.resolvedWebReaderURLString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let site = htmlEscape(siteRaw)
        let url = htmlEscape(urlRaw)
        let showURLInMeta = !urlRaw.isEmpty && !metaSiteAndURLAreRedundant(site: siteRaw, url: urlRaw)
        let eyebrow = htmlEscape(eyebrowText)
        let bodyHTML = articleBodyHTML
        let articleHeaderHTML = omitArticleHeader ? "" : """
              <header class="article-header">
                <div class="eyebrow">\(eyebrow)</div>
                <h1>\(title)</h1>
                <div class="meta">
                  \(author.isEmpty ? "" : "<span>\(author)</span>")
                  \(site.isEmpty ? "" : "<span>\(site)</span>")
                  \(showURLInMeta ? "<span>\(url)</span>" : "")
                </div>
                \(summary.isEmpty ? "" : "<div id=\"rubien-article-summary\" class=\"summary\" title=\"View abstract in the sidebar\">\(summary)</div>")
              </header>
"""

        let htmlOpeningTag = includeClipperTypography ? #"<html class="obsidian-reader-active theme-light">"# : "<html>"
        let clipperHeadInjection: String = {
            guard includeClipperTypography else { return "" }
            let vars = """
          <style>
            html.obsidian-reader-active {
              --obsidian-reader-font-size: \(fontSize)px;
              --obsidian-reader-line-height: 1.65;
              --obsidian-reader-line-width: \(Int(contentWidth))px;
            }
          </style>
"""
            guard let bundled = bundledClipperReaderStyleBlock() else { return vars }
            return vars + "\n          <style>\(bundled)</style>\n"
        }()
        // Keep the clipper's `.theme-light`/`.theme-dark` class in sync with the
        // live OS/app appearance. The bundled ClipperReader.css themes by class,
        // not `@media`, so on a theme flip (NSApp.appearance) we re-toggle the
        // class from `prefers-color-scheme` — which WebKit re-fires via `matchMedia`
        // `change` as the web view's effectiveAppearance changes.
        let bodyLeadScript = includeClipperTypography
            ? """
          <script>
          (function () {
            try {
              var root = document.documentElement;
              var mq = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)");
              function applyTheme(isDark) {
                root.classList.toggle("theme-dark", isDark);
                root.classList.toggle("theme-light", !isDark);
              }
              if (mq) {
                applyTheme(mq.matches);
                mq.addEventListener("change", function (e) { applyTheme(e.matches); });
              }
            } catch (_) {}
          })();
          </script>

"""
            : ""

        return """
        <!doctype html>
        \(htmlOpeningTag)
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root {
              color-scheme: light dark;
              --reader-font-size: \(fontSize)px;
              --reader-max-width: \(Int(contentWidth))px;
              --reader-line-height: 1.8;
            }

            html, body {
              margin: 0;
              padding: 0;
            }

            body {
              background: #ffffff;
              color: #1b1d21;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            }

            #reader-root {
              padding: 28px 32px 48px;
            }

            .article {
              max-width: var(--reader-max-width);
              margin: 0 auto;
              background: transparent;
              padding: 6px 0 46px;
            }

            .article-header {
              margin-bottom: 28px;
              border-bottom: 1px solid rgba(15, 23, 42, 0.08);
              padding-bottom: 22px;
            }

            .eyebrow {
              display: inline-flex;
              align-items: center;
              gap: 8px;
              font-size: 12px;
              font-weight: 600;
              color: #4b5563;
              background: rgba(99, 102, 241, 0.08);
              border-radius: 999px;
              padding: 5px 10px;
            }

            .article-header h1 {
              margin: 14px 0 10px;
              font-size: 34px;
              line-height: 1.22;
              letter-spacing: -0.02em;
            }

            .meta {
              display: flex;
              flex-wrap: wrap;
              gap: 10px 16px;
              color: #6b7280;
              font-size: 14px;
            }

            .summary {
              margin-top: 14px;
              color: #4b5563;
              font-size: 15px;
              line-height: 1.7;
            }

            #rubien-article-summary {
              cursor: pointer;
              border-radius: 8px;
              margin-left: -6px;
              margin-right: -6px;
              padding: 6px 8px;
              transition: background-color 0.15s ease;
            }

            #rubien-article-summary:hover {
              background: rgba(15, 23, 42, 0.04);
            }

            @keyframes rubienSummaryPulse {
              0%, 100% { background-color: transparent; }
              50% { background-color: rgba(99, 102, 241, 0.14); }
            }

            #rubien-article-summary.rubien-summary-flash {
              animation: rubienSummaryPulse 0.55s ease 0s 2;
            }

            html {
              scrollbar-width: thin;
              scrollbar-color: rgba(100, 116, 139, 0.24) transparent;
            }

            html::-webkit-scrollbar,
            body::-webkit-scrollbar {
              width: 9px;
              height: 9px;
            }

            html::-webkit-scrollbar-track,
            body::-webkit-scrollbar-track {
              background: transparent;
            }

            html::-webkit-scrollbar-thumb,
            body::-webkit-scrollbar-thumb {
              background-color: rgba(100, 116, 139, 0.22);
              border-radius: 999px;
              border: 2px solid transparent;
              background-clip: padding-box;
            }

            html::-webkit-scrollbar-thumb:hover,
            body::-webkit-scrollbar-thumb:hover {
              background-color: rgba(100, 116, 139, 0.34);
            }

            html::-webkit-scrollbar-corner,
            body::-webkit-scrollbar-corner {
              background: transparent;
            }

            #article-content {
              font-size: var(--reader-font-size);
              line-height: var(--reader-line-height);
              word-break: break-word;
            }

            #article-content h1,
            #article-content h2,
            #article-content h3,
            #article-content h4 {
              line-height: 1.3;
              margin-top: 1.55em;
              margin-bottom: 0.7em;
              letter-spacing: -0.015em;
            }

            #article-content p,
            #article-content ul,
            #article-content ol,
            #article-content blockquote,
            #article-content pre,
            #article-content table,
            #article-content hr,
            #article-content figure,
            #article-content .rubien-md-media-block {
              margin-top: 0;
              margin-bottom: 1em;
            }

            #article-content ul,
            #article-content ol {
              padding-left: 1.5em;
            }

            #article-content li + li {
              margin-top: 0.35em;
            }

            #article-content img {
              max-width: 100%;
              height: auto;
              border-radius: 12px;
            }

            #article-content hr {
              border: 0;
              border-top: 1px solid rgba(15, 23, 42, 0.12);
            }

            #article-content pre {
              background: rgba(15, 23, 42, 0.06);
              border-radius: 12px;
              padding: 14px 16px;
              overflow-x: auto;
            }

            #article-content code {
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
              font-size: 0.92em;
            }

            #article-content blockquote {
              border-left: 4px solid rgba(59, 130, 246, 0.35);
              padding-left: 14px;
              color: #4b5563;
            }

            #article-content a {
              color: #2563eb;
              text-decoration: none;
            }

            #article-content a:hover {
              text-decoration: underline;
            }

            .rubien-cover-image {
              margin: 0 0 1.6em 0;
            }
            .rubien-cover-image img {
              display: block;
              width: 100%;
              height: auto;
              border-radius: 8px;
            }

            .rubien-annotation {
              border-radius: 5px;
              cursor: pointer;
              transition: box-shadow 0.15s ease, background-color 0.15s ease;
            }

            .rubien-annotation.active {
              box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.35);
            }

            @media (prefers-color-scheme: dark) {
              html {
                scrollbar-color: rgba(148, 163, 184, 0.28) transparent;
              }

              html::-webkit-scrollbar-thumb,
              body::-webkit-scrollbar-thumb {
                background-color: rgba(148, 163, 184, 0.24);
              }

              html::-webkit-scrollbar-thumb:hover,
              body::-webkit-scrollbar-thumb:hover {
                background-color: rgba(148, 163, 184, 0.36);
              }

              body {
                background: #1e1e1e;
                color: #eceef2;
              }

              #rubien-article-summary:hover {
                background: rgba(255, 255, 255, 0.06);
              }

              @keyframes rubienSummaryPulseDark {
                0%, 100% { background-color: transparent; }
                50% { background-color: rgba(99, 102, 241, 0.22); }
              }

              #rubien-article-summary.rubien-summary-flash {
                animation: rubienSummaryPulseDark 0.55s ease 0s 2;
              }

              .article {
                background: transparent;
              }

              .article-header {
                border-bottom-color: rgba(255, 255, 255, 0.08);
              }

              .eyebrow {
                color: #d1d5db;
                background: rgba(99, 102, 241, 0.16);
              }

              .meta,
              .summary,
              #article-content blockquote {
                color: #aeb6c2;
              }

              #article-content pre {
                background: rgba(255, 255, 255, 0.06);
              }

              #article-content hr {
                border-top-color: rgba(255, 255, 255, 0.12);
              }

              #article-content a {
                color: #7fb3ff;
              }
            }
          </style>
        \(clipperHeadInjection)
        \(Self.bundledKaTeXHeadInjection)
        </head>
        <body>
        \(bodyLeadScript)<main id="reader-root">
            <article class="article">
              \(articleHeaderHTML)
              <div id="article-content">\(bodyHTML)</div>
            </article>
          </main>
          <script>
            (function () {
              const article = document.getElementById('article-content');
              let activeId = null;

              function send(name, payload) {
                try {
                  window.webkit.messageHandlers[name].postMessage(payload);
                } catch (_) {}
              }

              function hexToRgba(hex, alpha) {
                const normalized = (hex || '#FFDE59').replace('#', '');
                const safe = normalized.length === 6 ? normalized : 'FFDE59';
                const r = parseInt(safe.slice(0, 2), 16);
                const g = parseInt(safe.slice(2, 4), 16);
                const b = parseInt(safe.slice(4, 6), 16);
                return `rgba(${r}, ${g}, ${b}, ${alpha})`;
              }

              function unwrapAnnotations() {
                const nodes = Array.from(document.querySelectorAll('span[data-annotation-id]'));
                nodes.forEach((span) => {
                  const parent = span.parentNode;
                  if (!parent) return;
                  while (span.firstChild) {
                    parent.insertBefore(span.firstChild, span);
                  }
                  parent.removeChild(span);
                  parent.normalize();
                });
              }

              function collectTextNodes(root) {
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
                  acceptNode(node) {
                    if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
                    if (node.parentElement && node.parentElement.closest('[data-annotation-id]')) return NodeFilter.FILTER_REJECT;
                    return NodeFilter.FILTER_ACCEPT;
                  }
                });

                const result = [];
                while (walker.nextNode()) {
                  result.push(walker.currentNode);
                }
                return result;
              }

              function buildIndex(root) {
                const nodes = collectTextNodes(root);
                const map = [];
                let text = '';

                nodes.forEach((node) => {
                  const start = text.length;
                  const value = node.nodeValue || '';
                  text += value;
                  map.push({ node, start, end: text.length });
                });

                return { text, map };
              }

              function resolvePoint(map, target) {
                for (const entry of map) {
                  if (target >= entry.start && target <= entry.end) {
                    return { node: entry.node, offset: target - entry.start };
                  }
                }
                return null;
              }

              function scoreMatch(fullText, index, annotation) {
                let score = 0;
                if (annotation.prefixText) {
                  const actualPrefix = fullText.slice(Math.max(0, index - annotation.prefixText.length), index);
                  if (actualPrefix.endsWith(annotation.prefixText)) score += annotation.prefixText.length * 2;
                }
                if (annotation.suffixText) {
                  const actualSuffix = fullText.slice(
                    index + annotation.anchorText.length,
                    index + annotation.anchorText.length + annotation.suffixText.length
                  );
                  if (actualSuffix.startsWith(annotation.suffixText)) score += annotation.suffixText.length * 2;
                }
                return score;
              }

              function locateRange(annotation) {
                if (!annotation.anchorText) return null;
                const indexed = buildIndex(article);
                const fullText = indexed.text;
                if (!fullText) return null;

                let bestIndex = -1;
                let bestScore = -1;
                let searchFrom = 0;
                while (searchFrom <= fullText.length) {
                  const idx = fullText.indexOf(annotation.anchorText, searchFrom);
                  if (idx === -1) break;
                  const score = scoreMatch(fullText, idx, annotation);
                  if (score > bestScore) {
                    bestScore = score;
                    bestIndex = idx;
                  }
                  searchFrom = idx + Math.max(annotation.anchorText.length, 1);
                }

                if (bestIndex === -1) return null;
                const start = resolvePoint(indexed.map, bestIndex);
                const end = resolvePoint(indexed.map, bestIndex + annotation.anchorText.length);
                if (!start || !end) return null;

                const range = document.createRange();
                range.setStart(start.node, start.offset);
                range.setEnd(end.node, end.offset);
                return range;
              }

              function applyAnnotationStyle(span, annotation) {
                const color = annotation.color || '#FFDE59';
                const highlightColor = hexToRgba(color, annotation.type === 'underline' ? 0 : 0.3);
                span.className = `rubien-annotation ${annotation.type}`;
                span.dataset.annotationId = String(annotation.id || '');
                span.style.backgroundColor = annotation.type === 'underline' ? 'transparent' : highlightColor;
                span.style.borderBottom = annotation.type === 'underline' ? `3px solid ${color}` : 'none';
                span.style.paddingBottom = annotation.type === 'underline' ? '1px' : '0';
                if (annotation.noteText) {
                  span.title = annotation.noteText;
                }
              }

              function wrapRange(range, annotation) {
                // Single-text-node range: surroundContents works and is cheapest.
                if (
                  range.startContainer === range.endContainer &&
                  range.startContainer.nodeType === Node.TEXT_NODE
                ) {
                  const span = document.createElement('span');
                  applyAnnotationStyle(span, annotation);
                  try {
                    range.surroundContents(span);
                    return true;
                  } catch (_) {
                    // fall through to per-slice path below
                  }
                }

                // Multi-element range (paragraphs, list items, blockquotes, etc.).
                // DO NOT use range.extractContents()/insertNode here — pulling
                // <li>/<p>/etc. out of their parent <ul>/<ol> and rewrapping in
                // a <span> orphans block elements (renders stray bullets / loses
                // layout). Instead, walk the text nodes the range covers and
                // wrap EACH text-node slice in its own annotation span. The
                // element tree stays untouched; only the text gets new spans
                // around it.
                const slices = [];
                const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT, {
                  acceptNode(node) {
                    if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
                    if (node.parentElement && node.parentElement.closest('[data-annotation-id]')) return NodeFilter.FILTER_REJECT;
                    return NodeFilter.FILTER_ACCEPT;
                  }
                });
                while (walker.nextNode()) {
                  const node = walker.currentNode;
                  if (!range.intersectsNode(node)) continue;
                  const value = node.nodeValue;
                  let s = 0, e = value.length;
                  if (node === range.startContainer) s = range.startOffset;
                  if (node === range.endContainer) e = range.endOffset;
                  if (s >= e) continue;
                  slices.push({ node, start: s, end: e });
                }
                if (slices.length === 0) return false;
                try {
                  for (const slice of slices) {
                    let target = slice.node;
                    if (slice.end < target.nodeValue.length) {
                      target.splitText(slice.end);
                    }
                    if (slice.start > 0) {
                      target = target.splitText(slice.start);
                    }
                    const span = document.createElement('span');
                    applyAnnotationStyle(span, annotation);
                    target.parentNode.insertBefore(span, target);
                    span.appendChild(target);
                  }
                  return true;
                } catch (err) {
                  send('RubienClipperDebug', {
                    phase: 'wrap_range_failed',
                    detail: JSON.stringify({
                      annId: annotation.id,
                      error: String(err && err.message || err)
                    })
                  });
                  return false;
                }
              }

              function setActive(id) {
                activeId = id;
                document.querySelectorAll('[data-annotation-id]').forEach((node) => {
                  const matches = Number(node.dataset.annotationId) === Number(id);
                  node.classList.toggle('active', matches);
                });
              }

              let mathRendered = false;
              function renderMath() {
                if (mathRendered) return;
                if (typeof renderMathInElement !== 'function') return;
                try {
                  // Pass 1: re-render <math data-latex="..."> elements via katex.render().
                  // Defuddle/full converts page LaTeX into MathML at extraction time,
                  // but temml drops LaTeX styling commands (\\textcolor, \\color, etc.)
                  // during the conversion. KaTeX's own renderer handles them, so we
                  // re-render from the preserved data-latex attribute. Per-element
                  // try/catch: a single bad expression falls back to native MathML
                  // rendering of the surviving <math>, doesn't break siblings.
                  //
                  // Annotation safety: skip any <math> that contains a wrapped
                  // annotation span (data-annotation-id). wrapRange (above) does
                  // not refuse math-internal text nodes, so an annotation CAN
                  // land inside a <math> element; replaceWith would silently
                  // drop it. Leaving such math as native MathML (colorless) is
                  // the lesser harm vs. destroying user annotations.
                  if (typeof katex !== 'undefined' && typeof katex.render === 'function') {
                    const mathNodes = article.querySelectorAll('math[data-latex]');
                    for (let i = 0; i < mathNodes.length; i++) {
                      const mathEl = mathNodes[i];
                      if (mathEl.querySelector('[data-annotation-id]')) continue;
                      const latex = mathEl.getAttribute('data-latex');
                      if (!latex) continue;
                      const displayMode = mathEl.getAttribute('display') === 'block';
                      const span = document.createElement('span');
                      try {
                        katex.render(latex, span, { displayMode: displayMode, throwOnError: false });
                        mathEl.replaceWith(span);
                      } catch (_) { /* leave <math> intact; browser falls back */ }
                    }
                  }
                  // Pass 2: legacy delimited-text path for clips whose source HTML
                  // contained `$..$` / `\\(..\\)` / etc. without going through Defuddle's
                  // LaTeX→MathML conversion. `ignoredClasses: ['katex']` is critical:
                  // KaTeX's output includes a hidden <annotation encoding="application/x-tex">
                  // node carrying the ORIGINAL LaTeX source for accessibility. If that
                  // source contains $, \\[, \\(, auto-render would recurse into it and
                  // double-render. Excluding the .katex subtree prevents that.
                  // Delimiter escaping: this JS lives inside a Swift triple-quoted
                  // string. Swift collapses two backslashes to one before the JS
                  // engine sees the source, and JS then collapses two backslashes
                  // to one again. Hence the four backslashes here, which produce
                  // a single backslash in the runtime string KaTeX matches against.
                  renderMathInElement(article, {
                    delimiters: [
                      { left: '$$',     right: '$$',     display: true  },
                      { left: '\\\\[',  right: '\\\\]',  display: true  },
                      { left: '$',      right: '$',      display: false },
                      { left: '\\\\(',  right: '\\\\)',  display: false }
                    ],
                    throwOnError: false,
                    ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code'],
                    ignoredClasses: ['katex']
                  });
                  mathRendered = true;
                } catch (_) {}
              }

              function setAnnotations(annotations) {
                // Safety net: snapshot the article body before mutating so we
                // can roll back if anything throws unexpectedly. The article DOM
                // is the user's primary content — losing it is catastrophic; a
                // missed highlight is recoverable.
                const snapshot = article.innerHTML;
                try {
                  unwrapAnnotations();
                  (annotations || []).forEach((annotation) => {
                    const range = locateRange(annotation);
                    if (range) {
                      wrapRange(range, annotation);
                    } else if (annotation.anchorText) {
                      diagnoseLocateFailure(annotation);
                    }
                  });
                  if (activeId !== null) {
                    setActive(activeId);
                  }
                  // Render math AFTER annotation wrapping. The first effective
                  // call (post-didFinish) sees raw LaTeX text so legacy anchors
                  // whose anchorText contains LaTeX source still locate. KaTeX's
                  // auto-render is idempotent (skips already-rendered .katex
                  // nodes), so re-calling on subsequent annotation updates is safe.
                  renderMath();
                } catch (err) {
                  article.innerHTML = snapshot;
                  send('RubienClipperDebug', {
                    phase: 'set_annotations_failed',
                    detail: JSON.stringify({ error: String(err && err.message || err) })
                  });
                }
              }

              function diagnoseLocateFailure(annotation) {
                try {
                  const indexed = buildIndex(article);
                  const anchor = annotation.anchorText;
                  const sample = function(s, n) {
                    return s.length > n ? s.slice(0, n) + '…+' + (s.length - n) : s;
                  };
                  const collapsedAnchor = anchor.replace(/\\s+/g, ' ');
                  const collapsedText = indexed.text.replace(/\\s+/g, ' ');
                  const collapsedIdx = collapsedText.indexOf(collapsedAnchor);
                  let nfcIdx = -1;
                  try {
                    nfcIdx = indexed.text.normalize('NFC').indexOf(anchor.normalize('NFC'));
                  } catch (_) {}
                  const head32 = anchor.slice(0, 32).replace(/\\s+/g, ' ');
                  const headIdx = collapsedText.indexOf(head32);
                  const vicinity = headIdx >= 0
                    ? collapsedText.slice(Math.max(0, headIdx - 20), headIdx + 160)
                    : null;
                  const detail = JSON.stringify({
                    annId: annotation.id,
                    anchorLen: anchor.length,
                    anchorHead: sample(anchor, 80),
                    anchorTail: anchor.length > 80 ? anchor.slice(-40) : null,
                    fullTextLen: indexed.text.length,
                    collapsedMatchIdx: collapsedIdx,
                    nfcMatchIdx: nfcIdx,
                    headVicinity: vicinity ? sample(vicinity, 200) : null,
                    anchorHasNBSP: / /.test(anchor),
                    textHasNBSP: / /.test(indexed.text),
                    katexNodeCount: document.querySelectorAll('.katex').length
                  });
                  send('RubienClipperDebug', { phase: 'annotation_locate_failed', detail: detail });
                } catch (_) {}
              }

              // Walk Text descendants of the article in document order, slicing
              // on the range's start/end offsets, and concatenate nodeValues
              // with NO separator. This intentionally mirrors buildIndex so the
              // saved anchorText is byte-identical to what locateRange sees.
              // Avoids WebKit's range.toString / selection.toString quirk where
              // block boundaries get a line break that nodeValue concatenation
              // never produces, which silently breaks multi-paragraph anchors.
              function collectRangeText(range) {
                if (!range || range.collapsed) return '';
                const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT, {
                  acceptNode(node) {
                    if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
                    if (node.parentElement && node.parentElement.closest('[data-annotation-id]')) return NodeFilter.FILTER_REJECT;
                    return NodeFilter.FILTER_ACCEPT;
                  }
                });
                let text = '';
                while (walker.nextNode()) {
                  const node = walker.currentNode;
                  if (!range.intersectsNode(node)) continue;
                  const value = node.nodeValue;
                  let s = 0, e = value.length;
                  if (node === range.startContainer) s = range.startOffset;
                  if (node === range.endContainer) e = range.endOffset;
                  text += value.slice(s, e);
                }
                return text;
              }

              function currentSelectionPayload() {
                const selection = window.getSelection();
                if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
                const range = selection.getRangeAt(0);
                if (!article.contains(range.commonAncestorContainer)) return null;

                const text = collectRangeText(range).trim();
                if (!text) return null;

                const prefixRange = range.cloneRange();
                prefixRange.selectNodeContents(article);
                prefixRange.setEnd(range.startContainer, range.startOffset);

                const suffixRange = range.cloneRange();
                suffixRange.selectNodeContents(article);
                suffixRange.setStart(range.endContainer, range.endOffset);

                const domRect = range.getBoundingClientRect();
                const rect =
                  domRect.width >= 1 && domRect.height >= 1
                    ? { left: domRect.left, top: domRect.top, width: domRect.width, height: domRect.height }
                    : null;

                return {
                  text,
                  prefixText: prefixRange.toString().slice(-48),
                  suffixText: suffixRange.toString().slice(0, 48),
                  rect
                };
              }

              function emitSelectionState() {
                const payload = currentSelectionPayload();
                if (payload) {
                  send('selectionChanged', payload);
                } else {
                  send('selectionCleared', null);
                }
              }

              let selectionScrollScheduled = false;
              function scheduleSelectionEmitOnScroll() {
                if (selectionScrollScheduled) return;
                selectionScrollScheduled = true;
                requestAnimationFrame(() => {
                  selectionScrollScheduled = false;
                  if (currentSelectionPayload()) {
                    emitSelectionState();
                  }
                });
              }

              document.addEventListener('mouseup', () => setTimeout(emitSelectionState, 0));
              document.addEventListener('keyup', () => setTimeout(emitSelectionState, 0));
              window.addEventListener('scroll', scheduleSelectionEmitOnScroll, true);
              window.addEventListener('resize', scheduleSelectionEmitOnScroll);

              article.addEventListener('click', (event) => {
                const target = event.target;
                if (!(target instanceof Element)) return;
                const marker = target.closest('[data-annotation-id]');
                if (!marker) {
                  // The click event fires at the end of a drag-selection
                  // gesture too, with the freshly staged selection still
                  // active. Suppressing articleClickEmpty in that case avoids
                  // racing the selectionChanged that's about to open the
                  // popover. A genuine click-elsewhere collapses the prior
                  // selection on mousedown, so by `click` time it IS collapsed.
                  const sel = window.getSelection();
                  if (sel && sel.rangeCount > 0 && !sel.isCollapsed) return;
                  send('articleClickEmpty', {});
                  return;
                }
                const id = Number(marker.dataset.annotationId);
                setActive(id);
                const rect = marker.getBoundingClientRect();
                send('annotationActivated', {
                  id,
                  rectX: rect.x,
                  rectY: rect.y,
                  rectW: rect.width,
                  rectH: rect.height
                });
              });

              const summaryBlock = document.getElementById('rubien-article-summary');
              if (summaryBlock) {
                summaryBlock.addEventListener('click', (event) => {
                  event.preventDefault();
                  send('summarySectionClicked', {});
                });
              }

              window.RubienReader = {
                setAnnotations,
                clearSelection() {
                  const selection = window.getSelection();
                  if (selection) selection.removeAllRanges();
                  emitSelectionState();
                },
                scrollToAnnotation(id) {
                  const target = document.querySelector(`[data-annotation-id="${id}"]`);
                  if (!target) return;
                  setActive(id);
                  target.scrollIntoView({ behavior: 'smooth', block: 'center' });
                },
                scrollToSummary() {
                  const el = document.getElementById('rubien-article-summary');
                  if (!el) return;
                  el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                  el.classList.remove('rubien-summary-flash');
                  void el.offsetWidth;
                  el.classList.add('rubien-summary-flash');
                  window.setTimeout(() => el.classList.remove('rubien-summary-flash'), 1300);
                },
                updateAppearance(fontSize, maxWidth) {
                  document.documentElement.style.setProperty('--reader-font-size', `${fontSize}px`);
                  document.documentElement.style.setProperty('--reader-max-width', `${maxWidth}px`);
                  requestAnimationFrame(() => emitSelectionState());
                }
              };
            })();
          </script>
        </body>
        </html>
        """
    }

    nonisolated static func renderedMarkdownHTML(from markdown: String, baseURL: URL? = nil) -> String {
        MarkdownHTMLRenderer.render(markdown: markdown, baseURL: baseURL)
    }

    nonisolated private static func emptyDocument(title: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; padding: 40px; background: #ffffff; color: #1f2937; }
            .empty { max-width: 720px; margin: 40px auto; padding: 32px; text-align: center; }
          </style>
        </head>
        <body>
          <div class="empty">
            <h2>\(htmlEscape(title))</h2>
            <p>This web entry doesn't have any clipped content yet.</p>
          </div>
        </body>
        </html>
        """
    }


    /// `site` 与 `url` 是否指向同一 http(s) 资源，避免元信息区重复展示同一链接。
    nonisolated private static func metaSiteAndURLAreRedundant(site: String, url: String) -> Bool {
        let s = site.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !u.isEmpty else { return false }
        if s.caseInsensitiveCompare(u) == .orderedSame { return true }
        return httpURLsAreEquivalent(s, u)
    }

    nonisolated private static func httpURLsAreEquivalent(_ a: String, _ b: String) -> Bool {
        guard let ua = URL(string: a), let ub = URL(string: b) else { return false }
        let sa = (ua.scheme ?? "").lowercased()
        let sb = (ub.scheme ?? "").lowercased()
        guard ["http", "https"].contains(sa), ["http", "https"].contains(sb) else { return false }
        func normHost(_ h: String?) -> String {
            let x = h?.lowercased() ?? ""
            if x.hasPrefix("www.") { return String(x.dropFirst(4)) }
            return x
        }
        guard normHost(ua.host) == normHost(ub.host) else { return false }
        return ua.path == ub.path && (ua.query ?? "") == (ub.query ?? "")
    }

    nonisolated private static func htmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

struct WebReaderView: View {
    @StateObject private var viewModel: WebReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAnnotationSidebar = true
    @State private var showChatSidebar = false
    @State private var chatPanelWidth: CGFloat = 380
    /// Note-draft text for the selection popover. Lifted from the deleted WebSelectionActionBar
    /// so the shared AnnotationSelectionPopover can take a Binding into the same state across
    /// rebuilds. The `.onChange(of: viewModel.pendingSelection?.text ?? "")` modifier below
    /// resets it on any external dismissal path (JS-driven selection clear, annotation
    /// activation, highlight/underline buttons) without going through onDismiss.
    @State private var noteMarkdownForSelection: String = ""
    private let onClose: (() -> Void)?

    // Assistant chat (Phase 2c, floating card since Phase 3a): one renderer +
    // session controller per reader window; conversation state is in-memory
    // only (D5).
    @StateObject private var chatRenderer: ChatTranscriptController
    @StateObject private var chatSession: ChatSessionController

    init(reference: Reference, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        self._viewModel = StateObject(wrappedValue: WebReaderViewModel(reference: reference))

        // The first production provider construction: Claude wrapped with the
        // read-only MCP content channel (Phase 2b), so the agent reads THIS
        // document through Rubien's own tools. Reader windows always hold a
        // persisted reference; `?? 0` is unreachable in practice.
        // Build the live session from the user's Assistant settings via the shared
        // production factory (Phase 2c-5) — the PDF reader (Phase 3) reuses the same
        // path, so the wiring lives in one place. Each seeded value stays editable
        // per-conversation in the sidebar.
        let renderer = ChatTranscriptController()
        self._chatRenderer = StateObject(wrappedValue: renderer)
        self._chatSession = StateObject(wrappedValue: ReaderChatSession.make(
            reference: reference, transcript: renderer))
    }

    var body: some View {
        HSplitView {
            // Annotations dock on the LEFT (the trailing edge belongs to the
            // floating assistant card — two right-side panels felt unbalanced).
            if showAnnotationSidebar {
                WebAnnotationSidebarView(viewModel: viewModel)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)
                    .overlay(alignment: .trailing) {
                        LinearGradient(
                            colors: [.clear, Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 6)
                        .allowsHitTesting(false)
                    }
            }

            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    WebReaderContentView(viewModel: viewModel)
                        .overlay {
                            webSelectionToolbarOverlay
                        }
                        .overlay {
                            webAnnotationToolbarOverlay
                        }
                }

                if viewModel.isRendering || viewModel.isExtracting {
                    ProgressView(viewModel.isExtracting ? String(localized: "Loading and extracting…", bundle: .module) : String(localized: "Rendering markdown…", bundle: .module))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .liquidGlassSurface(in: Capsule(), fallback: .regularMaterial)
                        .padding(.top, 14)
                }
            }
            // Reflow, don't occlude: inset the document by the card's width so
            // the text rewraps beside it — docked semantics, floating look.
            // 12 = the card's 6 pt trailing gutter + a 6 pt gap. (The inset
            // tracks committed widths; during a card-resize drag the content
            // reflows on release, not per frame.)
            .padding(.trailing, showChatSidebar ? chatPanelWidth + 12 : 0)
            .frame(minWidth: 540)
            // The assistant floats over the document pane as a resizable card
            // (Phase 3a, details-panel idiom) — anchored to this pane, not the
            // window, so it never covers the annotation sidebar.
            .overlay(alignment: .trailing) {
                if showChatSidebar {
                    FloatingChatPanel(session: chatSession, renderer: chatRenderer, width: $chatPanelWidth) {
                        showChatSidebar = false
                    }
                    .padding(.trailing, 6)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: showChatSidebar)
            .animation(.easeInOut(duration: 0.22), value: chatPanelWidth)
        }
        .frame(minWidth: 900, minHeight: 620)
        // Window closing (the root view disappears): kill any in-flight agent
        // turn's process group (§4.4 step 9).
        .onDisappear { chatSession.teardown() }
        .animation(
            .spring(response: 0.3, dampingFraction: 0.82),
            value: viewModel.hasSelection && viewModel.selectionToolbarLayout?.visible == true
        )
        // Reset the lifted note draft on every selection-text transition (cleared,
        // emptied, or replaced with different text). Catches JS-driven dismissals,
        // annotation-activation transitions, and highlight/underline button clears
        // — paths that don't run our onDismiss closure.
        .onChange(of: viewModel.pendingSelection?.text ?? "") { _, _ in
            noteMarkdownForSelection = ""
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if viewModel.allowsDisplayModeSwitching {
                    Picker(String(localized: "Reading mode", bundle: .module), selection: Binding(
                        get: { viewModel.displayMode },
                        set: { viewModel.setDisplayMode($0) }
                    )) {
                        ForEach(WebReaderDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }

                // Refresh button — only visible in Clip mode.
                if viewModel.allowsDisplayModeSwitching, viewModel.displayMode == .clip {
                    Button {
                        viewModel.refreshClipContent()
                    } label: {
                        if viewModel.isExtracting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(String(localized: "Refresh", bundle: .module), systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isExtracting || viewModel.reference.resolvedWebReaderURLString() == nil)
                    .help(String(localized: "Re-extract from the source URL", bundle: .module))
                }

                fontControls
                widthControls
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation { showAnnotationSidebar.toggle() }
                } label: {
                    Label(String(localized: "Sidebar", bundle: .module), systemImage: "sidebar.left")
                }

                Button {
                    showChatSidebar.toggle()
                } label: {
                    Label(String(localized: "Assistant", bundle: .module), systemImage: "bubble.left.and.text.bubble.right")
                }
                .help(String(localized: "Chat about this document", bundle: .module))
            }
        }
        .onAppear {
            NoteEditorPool.shared.warmUp()
        }
        .onChange(of: viewModel.sidebarSummaryScrollToken) { _, new in
            if new > 0, viewModel.hasSidebarSummary {
                showAnnotationSidebar = true
            }
        }
        .navigationTitle(viewModel.reference.title)
        .alert(String(localized: "Refresh", bundle: .module), isPresented: Binding(
            get: { viewModel.extractionUserMessage != nil },
            set: { if !$0 { viewModel.extractionUserMessage = nil } }
        )) {
            Button(String(localized: "common.ok", bundle: .module), role: .cancel) {}
        } message: {
            Text(viewModel.extractionUserMessage ?? "")
        }
    }

    @ViewBuilder
    private var webSelectionToolbarOverlay: some View {
        let shouldShow = viewModel.hasSelection
            && viewModel.selectionToolbarLayout?.visible == true
        if shouldShow, let layout = viewModel.selectionToolbarLayout {
            GeometryReader { geo in
                AnnotationSelectionPopover(
                    currentColorHex: $viewModel.currentColorHex,
                    noteMarkdown: $noteMarkdownForSelection,
                    onHighlight: { viewModel.applySelectionAction(.highlight) },
                    onUnderline: { viewModel.applySelectionAction(.underline) },
                    onPickColor: { _ in viewModel.applySelectionAction(.highlight) },
                    onCopy: {
                        guard let text = viewModel.pendingSelection?.text, !text.isEmpty else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    },
                    onSaveNote: { md in
                        if let sel = viewModel.pendingSelection {
                            viewModel.addAnnotation(type: .note, selection: sel, noteText: md)
                        }
                        viewModel.clearSelection()
                        noteMarkdownForSelection = ""
                    },
                    onDismiss: {
                        viewModel.clearSelection()
                        noteMarkdownForSelection = ""
                    },
                    onAsk: {
                        // `pendingSelection.text` is stored pre-trimmed & non-empty
                        // (the popover only exists for a live selection); compose-time
                        // trimming re-normalizes it, so no trim is needed here.
                        guard let text = viewModel.pendingSelection?.text, !text.isEmpty else { return }
                        chatSession.stageSelection(text)
                        viewModel.clearSelection()
                        noteMarkdownForSelection = ""
                        showChatSidebar = true
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
    private var webAnnotationToolbarOverlay: some View {
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

    private var fontControls: some View {
        HStack(spacing: 3) {
            Button { viewModel.decreaseFontSize() } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)

            Button { viewModel.increaseFontSize() } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private var widthControls: some View {
        HStack(spacing: 3) {
            Button { viewModel.narrowContent() } label: {
                Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)

            Button { viewModel.widenContent() } label: {
                Image(systemName: "arrow.left.and.line.vertical.and.arrow.right.circle")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}


// Popover chrome lives in `AnnotationPopovers.swift` (shared with PDFReaderView).
// Adapters are constructed inline at the overlay call sites
// (`webSelectionToolbarOverlay`, `webAnnotationToolbarOverlay`).

private struct WebReaderContentView: NSViewRepresentable {
    @ObservedObject var viewModel: WebReaderViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "selectionChanged")
        controller.add(context.coordinator, name: "selectionCleared")
        controller.add(context.coordinator, name: "annotationActivated")
        controller.add(context.coordinator, name: "articleClickEmpty")
        controller.add(context.coordinator, name: "summarySectionClicked")
        controller.add(context.coordinator, name: "RubienClipperDebug")
        controller.add(context.coordinator.extractionManager, name: ReaderExtractionManager.readerResultHandlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = ReaderExtractionManager.safariLikeUserAgent
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false

        DispatchQueue.main.async {
            Self.applyElegantScrollers(to: webView)
        }

        context.coordinator.webView = webView
        context.coordinator.extractionManager.hostWebView = webView
        context.coordinator.bind(to: viewModel)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.bind(to: viewModel)

        // Case 1: Refresh-triggered URL load while in Clip mode. didFinish
        // injects Defuddle; result delivered via postMessage updates webContent.
        // currentlyLoadedMode stays nil until the extraction completes and
        // Case 4 swaps in the clipped HTML.
        if viewModel.shouldLoadOriginalURLForExtraction,
           viewModel.displayMode == .clip,
           let urlString = viewModel.reference.resolvedWebReaderURLString(),
           let pageURL = URL(string: urlString) {
            viewModel.acknowledgeOriginalURLLoadStarted()
            context.coordinator.extractionManager.resetForNewNavigation()
            context.coordinator.awaitingReadableExtraction = true
            context.coordinator.lastLoadedHTML = ""
            context.coordinator.currentlyLoadedMode = nil
            context.coordinator.loadedOriginalURLString = nil
            context.coordinator.pendingOriginalLoad = nil
            nsView.stopLoading()
            nsView.load(URLRequest(url: pageURL))
            return
        }

        // Case 2: Original-tab URL load. NO extraction. Clear any stale
        // awaiting flag first — a prior refresh's flag would otherwise cause
        // didFinish to inject Defuddle into the Original page load.
        if viewModel.displayMode == .original,
           let urlString = viewModel.reference.resolvedWebReaderURLString(),
           let pageURL = URL(string: urlString) {
            context.coordinator.awaitingReadableExtraction = false
            // Skip if we've already initiated the Original load for this exact
            // URL. We track intent via loadedOriginalURLString rather than
            // nsView.url because (a) clipped HTML uses sourceURL as baseURL so
            // nsView.url == sourceURL for both renders, and (b) nsView.url is
            // transiently about:blank during the two-step load below.
            if context.coordinator.currentlyLoadedMode == .original,
               context.coordinator.loadedOriginalURLString == urlString {
                return
            }
            context.coordinator.extractionManager.resetForNewNavigation()
            context.coordinator.lastLoadedHTML = ""
            context.coordinator.currentlyLoadedMode = .original
            context.coordinator.loadedOriginalURLString = urlString
            nsView.stopLoading()
            // WebKit collapses a load() that differs from the current document
            // URL only by fragment into a same-document navigation (scroll, no
            // reload). The clip is rendered via loadHTMLString(baseURL:
            // sourceURL), so for a fragment URL — e.g. a hash-route SPA like
            // foo.github.io/#/post/x — loading the Original page would no-op and
            // keep showing the clip. Force a real navigation by first resetting
            // to about:blank, then loading the page once that reset finishes
            // (correlated by its WKNavigation token in didFinish).
            if pageURL.fragment != nil,
               let blankNavigation = nsView.load(URLRequest(url: URL(string: "about:blank")!)) {
                context.coordinator.pendingOriginalLoad = (blankNavigation, pageURL)
            } else {
                context.coordinator.pendingOriginalLoad = nil
                nsView.load(URLRequest(url: pageURL))
            }
            return
        }

        // Case 3: Extraction in flight (Clip mode refresh). Don't overwrite
        // the loading WKWebView with cached HTML.
        if viewModel.displayMode == .clip,
           viewModel.isExtracting || context.coordinator.awaitingReadableExtraction {
            return
        }

        // Case 4: Render cached clipped HTML. Re-render when HTML changes
        // OR when we just switched back from Original mode.
        if context.coordinator.currentlyLoadedMode != .clip ||
           context.coordinator.lastLoadedHTML != viewModel.renderedHTML {
            context.coordinator.awaitingReadableExtraction = false
            context.coordinator.lastLoadedHTML = viewModel.renderedHTML
            context.coordinator.currentlyLoadedMode = .clip
            context.coordinator.loadedOriginalURLString = nil
            context.coordinator.pendingOriginalLoad = nil
            context.coordinator.invalidateAnnotationsPushCache()
            nsView.loadHTMLString(viewModel.renderedHTML, baseURL: URL(string: referenceBaseURL))
        } else {
            context.coordinator.pushAppearance()
            context.coordinator.pushAnnotations()
        }
    }

    static func applyElegantScrollers(to view: NSView) {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView {
                scrollView.hasVerticalScroller = true
                scrollView.applyRubienElegantScrollers()
            }
            applyElegantScrollers(to: subview)
        }
    }

    private var referenceBaseURL: String {
        if let url = viewModel.reference.resolvedWebReaderURLString(), !url.isEmpty {
            return url
        }
        return "http://127.0.0.1:23858/"
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebReaderContentView
        weak var webView: WKWebView?
        var lastLoadedHTML = ""
        /// 刚通过 `load(URLRequest)` 打开原文，等待 `didFinish` 后跑 Defuddle / Readability 抽取。
        var awaitingReadableExtraction = false
        /// Which display mode the WKWebView is currently rendering. `nil` until
        /// the first load completes. Used to distinguish "clipped HTML loaded
        /// with sourceURL as baseURL" from "raw Original page loaded from
        /// sourceURL" — `nsView.url` is the same in both cases.
        var currentlyLoadedMode: WebReaderDisplayMode? = nil
        /// The Original-page URL we've initiated a load for. Stable "intent"
        /// flag — unlike `nsView.url`, it stays correct through the
        /// about:blank reset step below, so re-renders don't restart the load.
        var loadedOriginalURLString: String? = nil
        /// Set while a two-step Original load is in flight: we load about:blank
        /// first, then `url` once that finishes — defeats WebKit collapsing a
        /// fragment-only `load()` into a same-document navigation (see Case 2).
        /// The about:blank `WKNavigation` is held so didFinish can correlate the
        /// reset by identity rather than matching the (unreliable) document URL.
        var pendingOriginalLoad: (navigation: WKNavigation, url: URL)? = nil

        let extractionManager = ReaderExtractionManager()

        init(parent: WebReaderContentView) {
            self.parent = parent
        }

        func bind(to viewModel: WebReaderViewModel) {
            extractionManager.isExtractionBusyContext = { [weak self] in
                guard let self else { return false }
                let vm = self.parent.viewModel
                return vm.displayMode == .clip && vm.isExtracting
            }
            extractionManager.onDefuddleSuccess = { [weak self] title, content, excerpt, byline in
                guard let self else { return }
                let vm = self.parent.viewModel
                Task { @MainActor in
                    vm.applyReadableExtractionResult(
                        title: title,
                        contentHTML: content,
                        excerpt: excerpt,
                        byline: byline,
                        includeClipperTypography: true,
                        eyebrowText: "Clipped"
                    )
                }
            }
            extractionManager.onReadabilitySuccess = { [weak self] title, content, excerpt, byline in
                guard let self else { return }
                let vm = self.parent.viewModel
                Task { @MainActor in
                    vm.applyReadableExtractionResult(
                        title: title,
                        contentHTML: content,
                        excerpt: excerpt,
                        byline: byline,
                        includeClipperTypography: false,
                        eyebrowText: "Clipped"
                    )
                }
            }
            extractionManager.onTerminalFailure = { [weak self] message in
                guard let self else { return }
                let vm = self.parent.viewModel
                Task { @MainActor in
                    vm.readableExtractionFailed(message: message)
                }
            }

            viewModel.resetExtractionNavigation = { [weak self] in
                self?.awaitingReadableExtraction = false
                self?.webView?.stopLoading()
            }
            viewModel.jumpToSummaryInWeb = { [weak self] in
                self?.evaluate("window.RubienReader && window.RubienReader.scrollToSummary();")
            }
            viewModel.clearSelectionInView = { [weak self] in
                self?.evaluate("window.RubienReader && window.RubienReader.clearSelection();")
            }
            viewModel.jumpToAnnotationInView = { [weak self] annotation in
                guard let id = annotation.id else { return }
                self?.evaluate("window.RubienReader && window.RubienReader.scrollToAnnotation(\(id));")
            }
            viewModel.updateAppearanceInView = { [weak self] fontSize, contentWidth in
                self?.pushAppearance(fontSize: fontSize, contentWidth: contentWidth)
            }
            viewModel.refreshAnnotationsInView = { [weak self] annotations in
                self?.pushAnnotations(annotations: annotations)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Second step of the two-step Original load: the about:blank reset
            // (matched by its navigation token, so an unrelated didFinish can't
            // be mistaken for it) has finished — now navigate to the real page.
            // If the user switched away from Original meanwhile, just drop it.
            if let pending = pendingOriginalLoad, navigation === pending.navigation {
                pendingOriginalLoad = nil
                if parent.viewModel.displayMode == .original {
                    webView.load(URLRequest(url: pending.url))
                }
                return
            }
            if awaitingReadableExtraction {
                awaitingReadableExtraction = false
                let pageURL = webView.url?.absoluteString ?? "(nil)"
                onlineReadableLog.notice("WK didFinish url=\(pageURL, privacy: .public) — about to inject Defuddle extraction")
                extractionManager.runOnlineArticleExtraction(from: webView)
                return
            }
            pushAppearance()
            pushAnnotations()
            WebReaderContentView.applyElegantScrollers(to: webView)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let vm = parent.viewModel
            // In Clip mode, user-clicked http(s) links open externally — the
            // reader view shows an extracted document; in-WebView navigation
            // would replace the rendered HTML. Allow non-link navigation
            // (initial loadHTMLString, programmatic loads) to proceed.
            guard vm.displayMode == .clip,
                  navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url,
                  url.scheme == "http" || url.scheme == "https" else {
                decisionHandler(.allow)
                return
            }
            // Detect same-document fragment navigation (anchor links).
            // baseURL on loadHTMLString is the source URL, so anchor `#x`
            // resolves to fully-qualified https://host/path#x — we must NOT
            // open these in the system browser. Compare scheme/host/port/
            // path/query explicitly; URL.path is percent-decoded so %20-vs-
            // space differences normalize away.
            if url.fragment != nil,
               let currentURL = webView.url,
               url.scheme == currentURL.scheme,
               url.host?.lowercased() == currentURL.host?.lowercased(),
               url.port == currentURL.port,
               url.path == currentURL.path,
               url.query == currentURL.query {
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finishLiveReadableWithFailureIfNeeded(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // If the about:blank reset step itself failed (degenerate), abandon
            // the two-step load and clear the Original intent so a later switch
            // re-initiates it instead of being short-circuited by the dedupe guard.
            if let pending = pendingOriginalLoad, navigation === pending.navigation {
                pendingOriginalLoad = nil
                loadedOriginalURLString = nil
                return
            }
            finishLiveReadableWithFailureIfNeeded(error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Task { @MainActor in
                let vm = parent.viewModel
                guard vm.displayMode == .clip, vm.isExtracting else { return }
                awaitingReadableExtraction = false
                vm.readableExtractionFailed(message: String(localized: "The web process terminated. Try refreshing again.", bundle: .module))
            }
        }

        private func finishLiveReadableWithFailureIfNeeded(_ message: String) {
            awaitingReadableExtraction = false
            Task { @MainActor in
                let vm = self.parent.viewModel
                guard vm.displayMode == .clip, vm.isExtracting else { return }
                vm.readableExtractionFailed(message: String(format: String(localized: "Page load failed: %@", bundle: .module), message))
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "selectionChanged":
                guard let body = message.body as? [String: Any] else { return }
                let rect = Self.parseViewportRect(from: body["rect"])
                let selection = WebSelectionSnapshot(
                    text: body["text"] as? String ?? "",
                    prefixText: body["prefixText"] as? String ?? "",
                    suffixText: body["suffixText"] as? String ?? "",
                    viewportSelectionRect: rect
                )
                let viewportSize = webView?.bounds.size ?? .zero
                Task { @MainActor in
                    parent.viewModel.stageSelection(selection, viewportSize: viewportSize)
                }
            case "selectionCleared":
                Task { @MainActor in
                    let vm = parent.viewModel
                    // Stickiness: while a staged selection's popover is visible, ignore
                    // transient "selection went away" events from the article webview
                    // (focus shift into the embedded note-editor WKWebView, popover-
                    // internal first-responder changes, etc.). The popover dismisses
                    // only via explicit user action (buttons, ESC) or a real
                    // *non-empty* selectionChanged that replaces the staged selection.
                    if vm.selectionToolbarLayout?.visible == true, vm.pendingSelection != nil {
                        return
                    }
                    // Only touch staged-selection state. Existing-annotation
                    // popover dismissal is driven exclusively by the dedicated
                    // `articleClickEmpty` case below, so a stray selectionCleared
                    // (focus shift, popover-internal mouseup, etc.) cannot race
                    // the existing-annotation popover off-screen.
                    vm.pendingSelection = nil
                    vm.selectionToolbarLayout = nil
                }
            case "articleClickEmpty":
                Task { @MainActor in
                    let vm = parent.viewModel
                    // Click on article (not on an annotation, not on the popover
                    // — popover clicks go to SwiftUI and never reach JS) dismisses
                    // both popovers. clearSelection clears staged-selection state
                    // AND calls dismissAnnotationToolbar internally, so a single
                    // call handles both. clearViewSelection: true also asks JS
                    // to drop the browser's native selection range.
                    if vm.pendingSelection != nil || vm.clickedAnnotationRecord != nil {
                        vm.clearSelection(clearViewSelection: true)
                    }
                }
            case "annotationActivated":
                guard let body = message.body as? [String: Any],
                      let id = body["id"] as? Int64 ?? (body["id"] as? NSNumber)?.int64Value,
                      let annotation = parent.viewModel.annotations.first(where: { $0.id == id }) else { return }
                // Extract the click rect sent from JS
                func cgFloat(_ key: String, fallback: CGFloat) -> CGFloat {
                    if let v = body[key] as? Double { return CGFloat(v) }
                    if let v = body[key] as? NSNumber { return CGFloat(v.doubleValue) }
                    return fallback
                }
                let clickRect = CGRect(
                    x: cgFloat("rectX", fallback: 0),
                    y: cgFloat("rectY", fallback: 0),
                    width: cgFloat("rectW", fallback: 100),
                    height: cgFloat("rectH", fallback: 20)
                )
                let viewportSize = message.webView?.bounds.size ?? CGSize(width: 800, height: 600)
                Task { @MainActor in
                    parent.viewModel.highlightSidebarSummary = false
                    parent.viewModel.selectedAnnotationId = annotation.id
                    // Don't call clearSelection() here: its dismissAnnotationToolbar()
                    // step would null the very clickedAnnotationRecord we set below.
                    parent.viewModel.pendingSelection = nil
                    parent.viewModel.selectionToolbarLayout = nil
                    parent.viewModel.clickedAnnotationRecord = annotation
                    parent.viewModel.annotationToolbarLayout = WebReaderViewModel.toolbarLayout(
                        viewportSelectionRect: clickRect,
                        viewportSize: viewportSize
                    )
                }
            case "summarySectionClicked":
                Task { @MainActor in
                    parent.viewModel.onArticleSummaryTapped()
                }
            case "RubienClipperDebug":
                if let dict = message.body as? [String: Any] {
                    let phase = dict["phase"] as? String ?? "?"
                    let url = dict["url"] as? String ?? ""
                    let detail = dict["detail"] as? String ?? String(describing: dict["extra"] ?? "")
                    onlineReadableLog.notice("[JS] \(phase, privacy: .public) url=\(url, privacy: .public) \(detail, privacy: .public)")
                } else {
                    onlineReadableLog.notice("[JS] \(String(describing: message.body), privacy: .public)")
                }
            default:
                break
            }
        }

        func pushAppearance() {
            pushAppearance(fontSize: parent.viewModel.fontSize, contentWidth: parent.viewModel.contentWidth)
        }

        func pushAppearance(fontSize: Double, contentWidth: CGFloat) {
            // Original mode shows a raw web page that has no window.RubienReader.
            guard parent.viewModel.displayMode == .clip else { return }
            evaluate("window.RubienReader && window.RubienReader.updateAppearance(\(fontSize), \(Int(contentWidth)));")
        }

        func pushAnnotations() {
            pushAnnotations(annotations: parent.viewModel.annotations)
        }

        private var lastPushedAnnotationsJSON: String?

        func invalidateAnnotationsPushCache() {
            lastPushedAnnotationsJSON = nil
        }

        func pushAnnotations(annotations: [WebAnnotationRecord]) {
            // Guard at source: didFinish, updateNSView, AND the annotation
            // observer callback can all reach here. Original mode shows a raw
            // page with no window.RubienReader — the JS would no-op anyway,
            // but skip the evaluateJavaScript bridge call to be cleaner.
            guard parent.viewModel.displayMode == .clip else { return }
            guard let data = try? JSONEncoder().encode(annotations),
                  let json = String(data: data, encoding: .utf8) else { return }
            // Suppress no-op pushes: didFinish, updateNSView, and the DB
            // observer can all fire pushAnnotations with the same payload,
            // each forcing a JS unwrap + walker + KaTeX scan over the article.
            if json == lastPushedAnnotationsJSON { return }
            lastPushedAnnotationsJSON = json
            evaluate("window.RubienReader && window.RubienReader.setAnnotations(\(json));")
        }

        private func evaluate(_ script: String) {
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }

        /// 解析内嵌脚本 `rect: { left, top, width, height }`（`WKScriptMessage` 中数字多为 `NSNumber`）。
        private static func parseViewportRect(from value: Any?) -> CGRect? {
            guard let dict = value as? [String: Any] else { return nil }
            let left = CGFloat((dict["left"] as? NSNumber)?.doubleValue ?? 0)
            let top = CGFloat((dict["top"] as? NSNumber)?.doubleValue ?? 0)
            let width = CGFloat((dict["width"] as? NSNumber)?.doubleValue ?? 0)
            let height = CGFloat((dict["height"] as? NSNumber)?.doubleValue ?? 0)
            guard width >= 1, height >= 1 else { return nil }
            return CGRect(x: left, y: top, width: width, height: height)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
