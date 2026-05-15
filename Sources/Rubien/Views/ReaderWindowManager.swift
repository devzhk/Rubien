import AppKit
import os.log
import SwiftUI
import RubienCore

private let readerWindowLog = Logger(subsystem: "Rubien", category: "reader-window")

// MARK: - ReaderWindowManager

/// Manages independent reader windows (PDF / Web) so the main library window
/// stays in place and multiple documents can be read side-by-side.
///
/// Design goals:
/// - One window per reference (re-activates if already open).
/// - Each window hosts the full `PDFReaderView` or `WebReaderView` with all
///   existing annotation/toolbar functionality intact.
/// - Zero coupling to `ContentView` reader-mode state — the main window never
///   enters reader mode when using this manager.
/// - Deterministic cleanup: windows are removed from the registry on close.
@MainActor
final class ReaderWindowManager {
    static let shared = ReaderWindowManager()

    // MARK: - Storage

    /// Open reader windows keyed by reference ID.
    private var windows: [Int64: NSWindow] = [:]
    /// Close-notification observers, keyed by reference ID.
    private var closeObservers: [Int64: NSObjectProtocol] = [:]
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
        if let existing = windows[refId],
           existing.isVisible || existing.isMiniaturized || existing.tabGroup != nil {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        recordReaderOpen(referenceId: refId, db: db)

        let title = windowTitle(for: reference, suffix: "PDF")
        let window = makeWindow(
            title: title,
            autosaveName: "RubienPDFReader-\(refId)",
            minSize: NSSize(width: 800, height: 600)
        )

        let readerView = PDFReaderView(reference: reference, pdfURL: pdfURL) { [weak self] in
            self?.closeWindow(forReferenceId: refId)
        }
        .frame(minWidth: 800, minHeight: 600)

        window.contentViewController = NSHostingController(rootView: readerView)
        registerWindow(window, title: title, forReferenceId: refId)
    }

    /// Open (or re-activate) a Web reader window for the given reference.
    func openWebReader(for reference: Reference, db: AppDatabase) {
        guard let refId = reference.id, reference.canOpenWebReader else { return }

        // Already open → bring to front (select its tab if tabbed).
        if let existing = windows[refId],
           existing.isVisible || existing.isMiniaturized || existing.tabGroup != nil {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        recordReaderOpen(referenceId: refId, db: db)

        let title = windowTitle(for: reference, suffix: "Web")
        let window = makeWindow(
            title: title,
            autosaveName: "RubienWebReader-\(refId)",
            minSize: NSSize(width: 800, height: 600)
        )

        let readerView = WebReaderView(reference: reference) { [weak self] in
            self?.closeWindow(forReferenceId: refId)
        }
        .frame(minWidth: 800, minHeight: 600)

        window.contentViewController = NSHostingController(rootView: readerView)
        registerWindow(window, title: title, forReferenceId: refId)
    }

    /// Returns true if a reader window is currently open for the given reference.
    func isOpen(referenceId: Int64) -> Bool {
        windows[referenceId]?.isVisible == true
    }

    /// Close all reader windows (e.g. on app termination).
    func closeAll() {
        for (refId, window) in windows {
            window.close()
            removeObserver(forReferenceId: refId)
        }
        windows.removeAll()
    }

    // MARK: - Private helpers

    /// Stamp a reader-open event on the reference. Pulled into its own
    /// function so the two reader paths share identical "open side effects"
    /// (timestamp bump + os.Logger trace on failure) and so tests can verify
    /// the wiring without spinning up an NSWindow.
    func recordReaderOpen(referenceId: Int64, db: AppDatabase) {
        do {
            try db.markReferenceRead(id: referenceId)
        } catch {
            // Fire-and-forget by design — a transient DB failure must not
            // block the user from opening their PDF. Log so persistent
            // failures still surface in Console.app under the "reader-window"
            // category.
            readerWindowLog.error(
                "markReferenceRead failed for reference \(referenceId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func makeWindow(title: String, autosaveName: String, minSize: NSSize) -> NSWindow {
        let preferredSize = preferredWindowSize(minSize: minSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: preferredSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
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

        window.setFrameAutosaveName(autosaveName)

        // Restore saved frame; if none, use preferred size centered on screen
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }

        return window
    }

    private func registerWindow(_ window: NSWindow, title: String, forReferenceId refId: Int64) {
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

        // Observe close to clean up
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.windows.removeValue(forKey: refId)
                self.removeObserver(forReferenceId: refId)
            }
        }
        closeObservers[refId] = observer
    }

    private func closeWindow(forReferenceId refId: Int64) {
        windows[refId]?.close()
        // Observer callback handles cleanup
    }

    private func removeObserver(forReferenceId refId: Int64) {
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
        let width = min(max(minSize.width, 1000), visibleFrame.width - 100)
        let height = min(max(minSize.height, 800), visibleFrame.height - 100)
        return NSSize(width: width, height: height)
    }
}
