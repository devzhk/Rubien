#if os(macOS)
import AppKit
import PDFKit
import os.log
import SwiftUI
import WebKit
import RubienCore
import Combine
import GRDB

private let readerWindowLog = Logger(subsystem: "Rubien", category: "reader-window")

/// Reader windows own the print shortcut so it works even when a PDF page,
/// webpage, note editor, or Assistant field has keyboard focus.
private final class ReaderWindow: NSWindow {
    enum DocumentKind {
        case pdf
        case web
    }

    var documentKind: DocumentKind = .pdf

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.isARepeat, Self.isPrintShortcut(event) {
            printDocument()
            return
        }
        super.sendEvent(event)
    }

    private static func isPrintShortcut(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "p" else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return modifiers == .control || modifiers == .command
    }

    private func printDocument() {
        guard let contentView else { return }
        switch documentKind {
        case .pdf:
            guard let pdfView = findView(in: contentView, ofType: PDFView.self),
                  pdfView.document != nil else { return }
            pdfView.print(with: NSPrintInfo.shared, autoRotate: true)
        case .web:
            guard let webView = findView(
                in: contentView,
                ofType: WKWebView.self,
                identifier: "RubienWebReaderContent"
            ) else { return }
            let operation = webView.printOperation(with: NSPrintInfo.shared)
            operation.showsPrintPanel = true
            operation.run()
        }
    }

    private func findView<T: NSView>(in view: NSView, ofType type: T.Type, identifier: String? = nil) -> T? {
        if let match = view as? T, identifier == nil || view.identifier?.rawValue == identifier {
            return match
        }
        for subview in view.subviews {
            if let match = findView(in: subview, ofType: type, identifier: identifier) {
                return match
            }
        }
        return nil
    }
}

enum ReaderWindowMetrics {
    static let defaultPreferredWidth: CGFloat = 1200
    static let defaultPreferredHeight: CGFloat = 800
    static let visibleFrameInset: CGFloat = 100

    /// The size to open a reader at: the caller's `desired` size (the user's last
    /// remembered reader size) when present, else the defaults — clamped to the window
    /// minimum and the visible screen so it never opens smaller than usable or wider
    /// than the display. When the screen cap itself falls below the minimum (tiny
    /// display), the minimum wins — matching what AppKit enforces via `window.minSize`.
    static func preferredWindowSize(minSize: NSSize, desired: NSSize? = nil, visibleFrame: NSRect) -> NSSize {
        let maxWidth = max(minSize.width, visibleFrame.width - visibleFrameInset)
        let maxHeight = max(minSize.height, visibleFrame.height - visibleFrameInset)
        let width = min(max(minSize.width, desired?.width ?? defaultPreferredWidth), maxWidth)
        let height = min(max(minSize.height, desired?.height ?? defaultPreferredHeight), maxHeight)
        return NSSize(width: width, height: height)
    }
}

// MARK: - ReaderWindowManager

/// Manages independent reader windows (PDF / Web) so the main library window
/// stays in place and multiple documents can be read side-by-side.
///
/// Design goals:
/// - One window per primary reference or attachment (re-activates if already open).
/// - Each window hosts the full `PDFReaderView` or `WebReaderView` with all
///   existing annotation/toolbar functionality intact.
/// - Zero coupling to `ContentView` reader-mode state — the main window never
///   enters reader mode when using this manager.
/// - Deterministic cleanup: windows are removed from the registry on close.
@MainActor
final class ReaderWindowManager {
    static let shared = ReaderWindowManager()

    // MARK: - Storage

    /// Primary references and supplementary documents have separate identities.
    private var windows: [ReaderDocumentIdentity: NSWindow] = [:]
    /// Close and metadata observers share the window's document identity.
    private var attachmentObservers: [ReaderDocumentIdentity: AnyCancellable] = [:]
    private var closeObservers: [ReaderDocumentIdentity: NSObjectProtocol] = [:]
    /// Shared tabbing identifier so all reader windows group into the same tab bar.
    private let readerTabbingIdentifier = "com.rubien.reader-window"

    private init() {}

    // MARK: - Public API

    /// Open (or re-activate) a PDF reader window for the given reference.
    /// No-ops when the reference has no materialized PDF on disk.
    func openPDFReader(for reference: Reference, db: AppDatabase) {
        guard let refId = reference.id,
              let filename = try? db.pdfFilename(for: refId) else { return }
        let pdfURL = AppDatabase.pdfStorageURL.appendingPathComponent(filename)

        // Already open → bring to front (select its tab if tabbed).
        // Check visibility, miniaturized, or part of a tab group to avoid
        // reusing a stale window that is mid-close (async cleanup race).
        if let existing = windows[.reference(refId)],
           existing.isVisible || existing.isMiniaturized || existing.tabGroup != nil {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        recordReaderOpen(referenceId: refId, db: db)

        let title = windowTitle(for: reference, suffix: "PDF")
        let minSize = NSSize(width: 800, height: 600)
        let contentSize = preferredWindowSize(minSize: minSize)
        let window = makeWindow(title: title, minSize: minSize, contentSize: contentSize, documentKind: .pdf)

        let readerView = PDFReaderView(reference: reference, pdfURL: pdfURL, db: db) { [weak self] in
            self?.closeWindow(forReferenceId: refId)
        }
        .frame(minWidth: 800, minHeight: 600)

        window.contentViewController = makeRubienHostingController(rootView: readerView, sizingOptions: [])
        // Assigning the content view controller makes AppKit shrink the window to the
        // SwiftUI content's fitting size — even with empty sizingOptions — clobbering
        // the remembered/default size. Re-assert it, then center (pre-show; no flash).
        window.setContentSize(contentSize)
        window.center()
        registerWindow(window, title: title, forDocument: .reference(refId))
        ReadingActivityWindowMonitor.shared.register(window: window, referenceId: refId, database: db)
    }

    /// Open (or re-activate) a Web reader window for the given reference.
    func openWebReader(for reference: Reference, db: AppDatabase) {
        guard let refId = reference.id, reference.canOpenWebReader else { return }

        // Already open → bring to front (select its tab if tabbed).
        if let existing = windows[.reference(refId)],
           existing.isVisible || existing.isMiniaturized || existing.tabGroup != nil {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        recordReaderOpen(referenceId: refId, db: db)

        let title = windowTitle(for: reference, suffix: "Web")
        // Floor for the panels visible at open (notes always starts visible, assistant
        // per the user's preference); once open, the reader's min-width enforcer keeps
        // the window floor tracking the live panel states (#5/#13).
        let minSize = NSSize(
            width: WebReaderMetrics.initialWindowMinWidth(
                chatVisible: RubienPreferences.assistantSidebarVisible),
            height: WebReaderMetrics.minimumWindowHeight
        )
        let contentSize = preferredWindowSize(minSize: minSize)
        let window = makeWindow(title: title, minSize: minSize, contentSize: contentSize, documentKind: .web)

        let readerView = WebReaderView(reference: reference, db: db) { [weak self] in
            self?.closeWindow(forReferenceId: refId)
        }

        window.contentViewController = makeRubienHostingController(rootView: readerView, sizingOptions: [])
        // Assigning the content view controller makes AppKit shrink the window to the
        // SwiftUI content's fitting size — even with empty sizingOptions — clobbering
        // the remembered/default size. Re-assert it, then center (pre-show; no flash).
        window.setContentSize(contentSize)
        window.center()
        registerWindow(window, title: title, forDocument: .reference(refId))
        ReadingActivityWindowMonitor.shared.register(window: window, referenceId: refId, database: db)
    }

    /// The caller prepares verified bytes away from the main actor before opening.
    func openAttachment(_ document: AttachmentReaderDocument, parent: Reference) throws {
        let item = document.attachment
        guard item.referenceId == parent.id, item.referenceSyncId == parent.syncId,
              item.deletedAt == nil else { throw ReferenceAttachmentError.removed }
        let identity = ReaderDocumentIdentity.attachment(item.syncId)
        if let existing = windows[identity], existing.isVisible || existing.isMiniaturized || existing.tabGroup != nil {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let isPDF = item.supportedKind == .pdf
        let minimum = isPDF ? NSSize(width: 800, height: 600) : NSSize(
            width: WebReaderMetrics.initialWindowMinWidth(
                chatVisible: RubienPreferences.assistantSidebarVisible),
            height: WebReaderMetrics.minimumWindowHeight)
        let size = preferredWindowSize(minSize: minimum)
        let title = "\(item.displayName) — \(parent.title)"
        let window = makeWindow(title: title, minSize: minimum, contentSize: size, documentKind: isPDF ? .pdf : .web)
        let close: () -> Void = { [weak self] in self?.windows[identity]?.close() }
        if isPDF {
            window.contentViewController = makeRubienHostingController(rootView:
                PDFReaderView(reference: parent, pdfURL: document.fileURL, db: document.store.database,
                              attachment: document, onClose: close), sizingOptions: [])
        } else {
            window.contentViewController = makeRubienHostingController(rootView:
                WebReaderView(reference: parent, db: document.store.database, attachment: document, onClose: close), sizingOptions: [])
        }
        window.setContentSize(size)
        window.center()
        registerWindow(window, title: title, forDocument: identity)
        if let parentId = parent.id {
            recordReaderOpen(referenceId: parentId, db: document.store.database)
            ReadingActivityWindowMonitor.shared.register(window: window, referenceId: parentId, database: document.store.database)
        }
        // The document owns the sole database observation. This subscription owns
        // native window/tab titles and closes readers when their attachment disappears.
        attachmentObservers[identity] = document.$attachment.combineLatest(document.$isRemoved)
            .receive(on: DispatchQueue.main)
            .sink { [weak window] current, isRemoved in
                guard !isRemoved, current.deletedAt == nil else { window?.close(); return }
                let title = "\(current.displayName) — \(parent.title)"
                window?.title = title
                window?.tab.title = title
            }
    }

    func isAttachmentOpen(syncId: String) -> Bool {
        guard let window = windows[.attachment(syncId)] else { return false }
        return window.isVisible || window.isMiniaturized || window.tabGroup != nil
    }

    /// Returns true if a reader window is currently open for the given reference.
    func isOpen(referenceId: Int64) -> Bool {
        windows[.reference(referenceId)]?.isVisible == true
    }

    /// Close all reader windows (e.g. on app termination).
    func closeAll() {
        for (refId, window) in Array(windows) {
            ReadingActivityWindowMonitor.shared.unregister(window: window)
            window.close()
            removeObserver(forDocument: refId)
        }
        windows.removeAll()
    }

    // MARK: - Private helpers

    /// Stamp a reader-open event on the reference. Pulled into its own
    /// function so the two reader paths share identical "open side effects"
    /// (timestamp bump + os.Logger trace on failure) and so tests can verify
    /// the wiring without spinning up an NSWindow.
    func recordReaderOpen(referenceId: Int64, db: AppDatabase) {
        guard RubienPreferences.recordReadingActivity else { return }
        // Fire-and-forget. markReferenceRead is a dbWriter.write; if a sync
        // commit briefly holds the writer queue, a synchronous call from
        // the main actor would freeze "tap to open." The stamp is a usage
        // metric — strict ordering isn't required.
        Task.detached(priority: .utility) {
            do {
                try db.markReferenceRead(id: referenceId)
            } catch {
                readerWindowLog.error(
                    "markReferenceRead failed for reference \(referenceId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func makeWindow(
        title: String,
        minSize: NSSize,
        contentSize: NSSize,
        documentKind: ReaderWindow.DocumentKind
    ) -> ReaderWindow {
        let window = ReaderWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.documentKind = documentKind
        // Intentionally leave `window.appearance` nil: these reader windows
        // live outside the SwiftUI scene graph, so they inherit the app-wide
        // theme from `NSApplication.appearance` (set by
        // `RubienPreferences.applyColorScheme`) and repaint live when the user
        // changes the theme. Pinning `window.appearance` here would break that.
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = minSize
        window.titlebarAppearsTransparent = false
        window.titleVisibility = {
            if #available(macOS 26.0, *) { return .hidden }
            return .visible
        }()
        window.tabbingIdentifier = readerTabbingIdentifier
        window.tabbingMode = .preferred

        // A toolbar is required for the unified style to render tab titles.
        let toolbar = NSToolbar(identifier: "ReaderToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Readers no longer autosave a per-document frame — papers/blogs are usually
        // read once, so per-reference memory rarely helps. The window opens at the last
        // size any reader was left at (`contentSize`, from RubienPreferences via the
        // caller); the caller re-asserts it after installing the content view
        // controller and centers. Simultaneous readers tab together (registerWindow).
        return window
    }

    private func registerWindow(_ window: NSWindow, title: String, forDocument refId: ReaderDocumentIdentity) {
        // Store reference
        windows[refId] = window

        // If another reader window is already open, add as a tab
        if let host = windows.values.first(where: { $0 !== window && ($0.isVisible || $0.isMiniaturized) }) {
            if host.isMiniaturized { host.deminiaturize(nil) }
            host.addTabbedWindow(window, ordered: .above)
        }

        // Show window / select tab
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Re-apply title: NSHostingController clears window.title when set
        // as contentViewController, so we must restore it after the window
        // is shown and has joined its tab group.
        window.title = title
        window.tab.title = title

        // Observe close to clean up, and remember the size this reader is closing at so
        // the next reader opens at it (RubienPreferences.readerWindowSize). Content size
        // (not frame) to match makeWindow's contentRect, so the height can't drift by the
        // titlebar height each open/close cycle. The observer runs on `queue: .main`, so
        // `assumeIsolated` gives the main-actor context synchronously — no Task hop.
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                if let window = notification.object as? NSWindow {
                    RubienPreferences.readerWindowSize = window.contentRect(forFrameRect: window.frame).size
                    ReadingActivityWindowMonitor.shared.unregister(window: window)
                }
                guard let self else { return }
                self.windows.removeValue(forKey: refId)
                self.removeObserver(forDocument: refId)
            }
        }
        closeObservers[refId] = observer
    }

    private func closeWindow(forReferenceId refId: Int64) {
        windows[.reference(refId)]?.close()
        // Observer callback handles cleanup
    }

    private func removeObserver(forDocument refId: ReaderDocumentIdentity) {
        attachmentObservers.removeValue(forKey: refId)?.cancel()
        if let observer = closeObservers.removeValue(forKey: refId) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func windowTitle(for reference: Reference, suffix: String) -> String {
        let title = reference.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Reader — \(suffix)" : title
    }

    private func preferredWindowSize(minSize: NSSize) -> NSSize {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 960)
        return ReaderWindowMetrics.preferredWindowSize(
            minSize: minSize, desired: RubienPreferences.readerWindowSize, visibleFrame: visibleFrame)
    }
}
#endif
