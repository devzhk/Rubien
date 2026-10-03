#if os(macOS)
import AppKit
import WebKit
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

@MainActor
final class AttachmentReaderIntegrationTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var store: ReferenceAttachmentStore!
    private var parent: Reference!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentReaders-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Reader observations can drain after AppKit closes a window. Keep the
        // fixture in memory so teardown never unlinks SQLite under a queued read.
        database = try AppDatabase(DatabaseQueue())
        parent = Reference(title: "Primary paper")
        parent.webContent = Reference.encodeWebContent("Primary content", format: .markdown)
        try database.saveReference(&parent)
        store = ReferenceAttachmentStore(database: database, libraryRoot: root, validatePDF: { _ in })
    }

    override func tearDownWithError() throws {
        ReaderWindowManager.shared.closeAll()
        store = nil
        database = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func attachment(_ name: String, text: String = "Supplementary content") throws -> ReferenceAttachment {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return try store.importFile(at: url, referenceId: parent.id!).attachment
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws {
        for _ in 0..<100 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected reader state was not reached")
    }

    func testMarkdownUsesAttachmentContentAndCannotRefreshParent() async throws {
        let item = try attachment("notes.md")
        let document = try await AttachmentReaderDocument.open(syncId: item.syncId, store: store)
        let model = WebReaderViewModel(reference: parent, db: database, attachment: document)
        XCTAssertEqual(model.documentContent?.body, "Supplementary content")
        XCTAssertEqual(model.reference.webContent, parent.webContent)
        XCTAssertEqual(model.reference.title, parent.title)
        XCTAssertFalse(model.allowsDisplayModeSwitching)
        model.refreshClipContent()
        model.setDisplayMode(.original)
        XCTAssertFalse(model.isExtracting)
        XCTAssertEqual(model.displayMode, .clip)
        let data = try await model.prepareMarkdownExport()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "Supplementary content")
        XCTAssertEqual(try database.fetchReferences(ids: [parent.id!]).first?.webContent, parent.webContent)
        let assistant = ReaderAssistantState(reference: parent, database: database, attachment: document)
        XCTAssertNotNil(assistant.session)
        XCTAssertNotNil(assistant.renderer)
        assistant.session?.teardown()
    }

    func testAttachmentRenameUpdatesReaderTitleWithoutChangingParent() async throws {
        let item = try attachment("notes.md")
        let document = try await AttachmentReaderDocument.open(syncId: item.syncId, store: store)
        let model = WebReaderViewModel(reference: parent, db: database, attachment: document)
        try await waitUntil { !model.isRendering && model.renderedHTML.contains("Supplementary content") }
        let initialHTML = model.renderedHTML
        try store.rename(syncId: item.syncId, to: "Revised supplement")
        try await waitUntil { model.documentTitle == "Revised supplement" }
        XCTAssertEqual(model.renderedHTML, initialHTML, "Renaming must not trigger a reload or restore the opening scroll position")
        XCTAssertEqual(model.reference.title, "Primary paper")
        XCTAssertNil(model.documentSourceURL)
        XCTAssertFalse(model.hasSidebarSummary)
    }

    func testExtractionCacheReusesTextAndRepairsModifiedWorkspaceCopy() async throws {
        let item = try attachment("notes.md", text: "Verified source")
        let context = AssistantConversationContext.attachment(.init(syncId: item.syncId, title: item.displayName))
        let workspace = root.appendingPathComponent("workspace")
        let cache = AttachmentTextCache()
        let first = try await AttachmentChatContext.prepare(context: context, workspace: workspace, store: store, textCache: cache)
        let fullText = workspace.appendingPathComponent(".rubien/reader-documents/\(item.syncId)/\(item.contentHash)/document.txt")
        try Data("Changed by a workspace tool".utf8).write(to: fullText)
        let second = try await AttachmentChatContext.prepare(context: context, workspace: workspace, store: store,
            textExtractor: { _, _ in XCTFail("Unchanged content must reuse extraction"); return "wrong" }, textCache: cache)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try String(contentsOf: fullText, encoding: .utf8), "Verified source")
        let compact = AttachmentChatContext.continuation(from: try XCTUnwrap(second))
        XCTAssertFalse(compact.contains("Verified source"))
        XCTAssertTrue(compact.contains("fullTextPath"))
        XCTAssertTrue(compact.contains("annotationsPath"))
        try Data("Corrupt content".utf8).write(to: store.verifiedFileURL(syncId: item.syncId))
        do {
            _ = try await AttachmentChatContext.prepare(context: context, workspace: workspace, store: store, textCache: cache)
            XCTFail("A cached extraction must not hide source corruption")
        } catch { XCTAssertEqual(error as? ReferenceAttachmentError, .integrityMismatch) }
    }

    func testChatContextReadsOnlySelectedAttachmentAndRejectsRemoval() async throws {
        let first = try attachment("first.md", text: "UNIQUE_SUPPLEMENT_TEXT")
        let second = try attachment("second.md", text: "OTHER_ATTACHMENT_TEXT")
        let workspace = root.appendingPathComponent("workspace")
        let context = AssistantConversationContext.attachment(.init(syncId: first.syncId, title: first.displayName))
        let prepared = try await AttachmentChatContext.prepare(context: context, workspace: workspace, store: store)
        let payload = try XCTUnwrap(prepared)
        XCTAssertTrue(payload.contains("UNIQUE_SUPPLEMENT_TEXT"))
        XCTAssertTrue(payload.contains(first.syncId))
        XCTAssertFalse(payload.contains("OTHER_ATTACHMENT_TEXT"))
        XCTAssertFalse(payload.contains("Primary content"))
        let fullText = workspace.appendingPathComponent(".rubien/reader-documents/\(first.syncId)/\(first.contentHash)/document.txt")
        XCTAssertEqual(try String(contentsOf: fullText, encoding: .utf8), "UNIQUE_SUPPLEMENT_TEXT")
        _ = try await AttachmentChatContext.prepare(context: context, workspace: workspace, store: store)
        try store.remove(syncId: first.syncId)
        do {
            _ = try await AttachmentChatContext.prepare(context: context, workspace: workspace, store: store)
            XCTFail("Removed attachment must not dispatch content")
        } catch { XCTAssertEqual(error as? ReferenceAttachmentError, .removed) }
        XCTAssertNotNil(try store.attachment(syncId: second.syncId))
    }

    func testChatContextRejectsWorkspaceSymlinkEscape() async throws {
        let item = try attachment("notes.md")
        let workspace = root.appendingPathComponent("workspace")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent(".rubien"), withDestinationURL: outside)
        do {
            _ = try await AttachmentChatContext.prepare(
                context: .attachment(.init(syncId: item.syncId, title: item.displayName)),
                workspace: workspace, store: store)
            XCTFail("Must reject a symlinked context directory")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testPDFChatContextExtractsSupplementPages() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("RubienPDFKitTests/Fixtures/PDFs/linear-3pages-text.pdf")
        let item = try store.importFile(at: fixture, referenceId: parent.id!).attachment
        let prepared = try await AttachmentChatContext.prepare(
            context: .attachment(.init(syncId: item.syncId, title: item.displayName)),
            workspace: root.appendingPathComponent("workspace"), store: store)
        let text = try XCTUnwrap(prepared)
        XCTAssertTrue(text.contains("Page 1 body text"))
        XCTAssertTrue(text.contains("Page 3 body text"))
        XCTAssertTrue(text.contains("[Page 3]"))
        XCTAssertFalse(text.contains("Primary content"))
    }

    func testPDFReaderWritesOnlyAttachmentAnnotationsAndObservesEdits() async throws {
        let item = try attachment("supplement.pdf")
        let document = try await AttachmentReaderDocument.open(syncId: item.syncId, store: store)
        let model = PDFReaderViewModel(reference: parent, pdfURL: document.fileURL, db: database, attachment: document)
        model.addAnnotation(type: .highlight, selectedText: "Supplement", pageIndex: 0,
                            rects: [CGRect(x: 1, y: 2, width: 80, height: 12)])
        try await waitUntil { model.annotations.count == 1 }
        let annotation = try XCTUnwrap(model.annotations.first)
        XCTAssertNil(annotation.primaryRecord)
        XCTAssertEqual(annotation.documentID, .attachment(item.syncId))
        model.navigateTo(annotation)
        XCTAssertEqual(model.selectedAnnotationId, annotation.id)
        let primaryReader = PDFReaderViewModel(reference: parent, pdfURL: document.fileURL, db: database)
        primaryReader.updateAnnotationNote(annotation, noteText: "Must not reach parent")
        primaryReader.deleteAnnotation(annotation)
        model.updateAnnotationNote(annotation, noteText: "Attachment note")
        model.updateAnnotationColor(annotation, color: "#7ED957")
        try await waitUntil { model.annotations.first?.noteText == "Attachment note" && model.annotations.first?.color == "#7ED957" }
        XCTAssertTrue(try database.fetchAnnotations(referenceId: parent.id!).isEmpty)
        model.deleteAnnotation(annotation)
        try await waitUntil { model.annotations.isEmpty }
        XCTAssertTrue(try store.annotations(attachmentSyncId: item.syncId).isEmpty)
    }

    func testMarkdownReaderObservesOnlyItsOwnAnnotationsAndRemoval() async throws {
        let first = try attachment("first.md")
        let second = try attachment("second.md", text: "Different notes")
        let document = try await AttachmentReaderDocument.open(syncId: first.syncId, store: store)
        let model = WebReaderViewModel(reference: parent, db: database, attachment: document)
        document.add(type: .note, anchor: .markdown(text: "Supplementary", prefix: nil, suffix: " content"),
                     text: "Supplementary", note: "Note", color: "#FFDE59")
        try await waitUntil { model.annotations.count == 1 }
        let note = try XCTUnwrap(model.annotations.first)
        XCTAssertNil(note.primaryRecord)
        XCTAssertEqual(note.documentID, .attachment(first.syncId))
        let primaryReader = WebReaderViewModel(reference: parent, db: database)
        primaryReader.updateAnnotationNote(note, noteText: "Must not reach parent")
        primaryReader.deleteAnnotation(note)
        model.navigateTo(note)
        XCTAssertEqual(model.selectedAnnotationId, note.id)
        model.updateAnnotationNote(note, noteText: "Changed")
        try await waitUntil { model.annotations.first?.noteText == "Changed" }
        XCTAssertTrue(try store.annotations(attachmentSyncId: second.syncId).isEmpty)
        XCTAssertTrue(try database.fetchWebAnnotations(referenceId: parent.id!).isEmpty)
        try store.remove(syncId: first.syncId)
        try await waitUntil { model.annotations.isEmpty }
        model.updateAnnotationNote(note, noteText: "Too late")
        try await waitUntil { model.persistenceError != nil }
    }

    func testBatchImportsKeepPerFileResultsAndOriginalParent() async throws {
        let other = ReferenceAttachmentsModel(reference: parent, database: database, libraryRoot: root)
        let first = root.appendingPathComponent("first.md")
        let duplicate = root.appendingPathComponent("duplicate.md")
        let unsupported = root.appendingPathComponent("unsupported.txt")
        try Data("Notes".utf8).write(to: first)
        try Data("Notes".utf8).write(to: duplicate)
        try Data("Other".utf8).write(to: unsupported)
        other.add([first, duplicate, unsupported])
        try await waitUntil { !other.isImporting && other.attachments.count == 1 }
        XCTAssertEqual(other.importStatuses.map(\.message).prefix(2), ["Added", "Already attached"])
        XCTAssertTrue(other.importStatuses[2].failed)
        XCTAssertEqual(other.attachments.first?.referenceSyncId, parent.syncId)
    }

    func testTwoAttachmentWindowsReuseIndependentlyAndCloseOnRemoval() async throws {
        _ = NSApplication.shared
        let first = try attachment("first.md", text: Array(repeating: "A supplementary paragraph.\n\n", count: 200).joined())
        let second = try attachment("second.md", text: "Other notes")
        let firstDocument = try await AttachmentReaderDocument.open(syncId: first.syncId, store: store)
        let secondDocument = try await AttachmentReaderDocument.open(syncId: second.syncId, store: store)
        let manager = ReaderWindowManager.shared
        manager.openWebReader(for: parent, db: database)
        try manager.openAttachment(firstDocument, parent: parent)
        try manager.openAttachment(secondDocument, parent: parent)
        let count = NSApp.windows.count
        try manager.openAttachment(firstDocument, parent: parent)
        XCTAssertEqual(NSApp.windows.count, count)
        XCTAssertTrue(manager.isAttachmentOpen(syncId: first.syncId))
        XCTAssertTrue(manager.isAttachmentOpen(syncId: second.syncId))
        manager.openWebReader(for: parent, db: database)
        XCTAssertEqual(NSApp.windows.count, count, "The primary reader has its own reusable identity")
        let readerWindow = try XCTUnwrap(NSApp.windows.first { $0.title == "first.md — Primary paper" })
        func webViews(in view: NSView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
        }
        var article: WKWebView?
        for _ in 0..<100 {
            for candidate in webViews(in: try XCTUnwrap(readerWindow.contentView)) {
                if (try? await candidate.evaluateJavaScript("document.querySelector('.article-header h1')?.textContent")) as? String == "first.md" {
                    article = candidate
                    break
                }
            }
            if article != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let webView = try XCTUnwrap(article)
        _ = try await webView.evaluateJavaScript("window.scrollTo(0, 400)")
        let scrollBefore = try await webView.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertGreaterThan(try XCTUnwrap(scrollBefore), 0)
        let anchorBefore = try await webView.evaluateJavaScript("window.rubienRenameAnchor = [...document.querySelectorAll('p')].find(p => p.getBoundingClientRect().top >= 0); window.rubienRenameAnchor.getBoundingClientRect().top") as? Double
        for name in [String(repeating: "Long renamed supplement ", count: 6) + "notes", "Renamed again"] {
            try store.rename(syncId: first.syncId, to: name)
            try await waitUntil { NSApp.windows.contains { $0.title == "\(name) — Primary paper" && $0.tab.title == "\(name) — Primary paper" } }
            var heading: String?
            for _ in 0..<100 {
                heading = try await webView.evaluateJavaScript("document.querySelector('.article-header h1')?.textContent") as? String
                if heading == name { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(heading, name)
            // A longer title can wrap and change document height. Check the
            // visible passage, not absolute scrollY: renaming must preserve it.
            let anchorAfter = try await webView.evaluateJavaScript("window.rubienRenameAnchor.getBoundingClientRect().top") as? Double
            XCTAssertEqual(try XCTUnwrap(anchorAfter), try XCTUnwrap(anchorBefore), accuracy: 1)
        }
        try store.remove(syncId: first.syncId)
        try await waitUntil { !manager.isAttachmentOpen(syncId: first.syncId) }
        XCTAssertTrue(manager.isAttachmentOpen(syncId: second.syncId))
    }
}
#endif
