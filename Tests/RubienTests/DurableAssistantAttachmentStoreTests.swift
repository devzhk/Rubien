#if os(macOS)
import GRDB
import XCTest
@testable import Rubien
@testable import RubienCore

final class DurableAssistantAttachmentStoreTests: XCTestCase {
    func testPrepareCopiesHashesResolvesAndRollsBackLibraryOwnedFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.md")
        let data = Data("durable context".utf8)
        try data.write(to: source)
        let attachmentID = UUID()
        let conversationID = UUID()
        let entryID = UUID()
        let store = DurableAssistantAttachmentStore(
            database: fixture.database,
            libraryRoot: fixture.libraryRoot
        )

        let prepared = try await store.prepare([
            ChatAttachment(
                id: attachmentID,
                displayName: "../Notes.md",
                kind: .text,
                stagedURL: source,
                mediaType: "text/markdown",
                byteCount: Int64(data.count),
                sourceIdentity: source.path
            ),
        ], conversationID: conversationID, entryID: entryID)

        let row = try XCTUnwrap(prepared.rows.first)
        XCTAssertEqual(row.relativePath, "\(attachmentID.uuidString.lowercased())/Notes.md")
        XCTAssertEqual(row.byteCount, Int64(data.count))
        XCTAssertNotNil(row.sha256)
        let resolved = await store.resolvedURL(
            conversationID: conversationID.uuidString.lowercased(),
            attachment: row
        )
        XCTAssertEqual(try resolved.map { try Data(contentsOf: $0) }, data)

        await store.rollback(prepared)
        let rolledBack = await store.resolvedURL(
            conversationID: conversationID.uuidString.lowercased(),
            attachment: row
        )
        XCTAssertNil(rolledBack)
    }

    func testPrepareSanitizesBackslashAndSurvivesReconciliation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.md")
        let data = Data("durable context".utf8)
        try data.write(to: source)
        let attachmentID = UUID()
        let conversationID = UUID()
        let store = DurableAssistantAttachmentStore(
            database: fixture.database,
            libraryRoot: fixture.libraryRoot
        )

        let prepared = try await store.prepare([
            ChatAttachment(
                id: attachmentID,
                displayName: "Lab\\Notes.md",
                kind: .text,
                stagedURL: source,
                mediaType: "text/markdown",
                byteCount: Int64(data.count),
                sourceIdentity: source.path
            ),
        ], conversationID: conversationID, entryID: UUID())

        let row = try XCTUnwrap(prepared.rows.first)
        XCTAssertEqual(
            row.relativePath,
            "\(attachmentID.uuidString.lowercased())/Lab-Notes.md"
        )
        AssistantAttachmentFiles.reconcile(
            libraryRoot: fixture.libraryRoot,
            storedPaths: [StoredAssistantAttachmentPath(
                id: row.id,
                conversationId: conversationID.uuidString.lowercased(),
                relativePath: try XCTUnwrap(row.relativePath)
            )]
        )
        let resolved = await store.resolvedURL(
            conversationID: conversationID.uuidString.lowercased(),
            attachment: row
        )
        XCTAssertEqual(try resolved.map { try Data(contentsOf: $0) }, data)
    }

    func testResolvedURLRejectsAbsoluteTraversalMismatchedIDAndSymlinkEscape() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = DurableAssistantAttachmentStore(
            database: fixture.database,
            libraryRoot: fixture.libraryRoot
        )
        let conversationID = UUID().uuidString.lowercased()
        let attachmentID = UUID().uuidString.lowercased()
        let entryID = UUID().uuidString.lowercased()
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let attachmentRoot = fixture.libraryRoot
            .appendingPathComponent("AssistantAttachments")
            .appendingPathComponent(conversationID)
            .appendingPathComponent(attachmentID)
        try FileManager.default.createDirectory(
            at: attachmentRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: attachmentRoot.appendingPathComponent("escape.txt"),
            withDestinationURL: outside
        )

        func row(_ relativePath: String) -> StoredAssistantAttachment {
            StoredAssistantAttachment(
                id: attachmentID,
                entryId: entryID,
                displayName: "unsafe",
                kind: .text,
                relativePath: relativePath,
                mediaType: "text/plain",
                byteCount: 7
            )
        }

        let absolute = await store.resolvedURL(
            conversationID: conversationID,
            attachment: row(outside.path)
        )
        let traversal = await store.resolvedURL(
            conversationID: conversationID,
            attachment: row("\(attachmentID)/../outside.txt")
        )
        let mismatched = await store.resolvedURL(
            conversationID: conversationID,
            attachment: row("different/escape.txt")
        )
        let escaped = await store.resolvedURL(
            conversationID: conversationID,
            attachment: row("\(attachmentID)/escape.txt")
        )
        XCTAssertNil(absolute)
        XCTAssertNil(traversal)
        XCTAssertNil(mismatched)
        XCTAssertNil(escaped)
    }

    func testPrepareRejectsPreexistingAttachmentDirectorySymlinkEscape() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.md")
        let sourceData = Data("replacement".utf8)
        try sourceData.write(to: source)
        let conversationID = UUID()
        let attachmentID = UUID()
        let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let protected = outside.appendingPathComponent("Notes.md")
        let protectedData = Data("keep me".utf8)
        try protectedData.write(to: protected)
        let conversationDirectory = fixture.libraryRoot
            .appendingPathComponent(AssistantAttachmentFiles.directoryName)
            .appendingPathComponent(conversationID.uuidString.lowercased())
        try FileManager.default.createDirectory(
            at: conversationDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: conversationDirectory.appendingPathComponent(
                attachmentID.uuidString.lowercased()
            ),
            withDestinationURL: outside
        )
        let store = DurableAssistantAttachmentStore(
            database: fixture.database,
            libraryRoot: fixture.libraryRoot
        )

        do {
            _ = try await store.prepare([
                ChatAttachment(
                    id: attachmentID,
                    displayName: "Notes.md",
                    kind: .text,
                    stagedURL: source,
                    mediaType: "text/markdown",
                    byteCount: Int64(sourceData.count),
                    sourceIdentity: source.path
                ),
            ], conversationID: conversationID, entryID: UUID())
            XCTFail("expected the symlink destination to be rejected")
        } catch {
            XCTAssertEqual(try Data(contentsOf: protected), protectedData)
        }
    }

    func testPrepareRejectsSymlinkedAttachmentRoot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.md")
        let sourceData = Data("do not redirect".utf8)
        try sourceData.write(to: source)
        let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let protected = outside.appendingPathComponent("protected.txt")
        let protectedData = Data("keep me".utf8)
        try protectedData.write(to: protected)
        try FileManager.default.createSymbolicLink(
            at: fixture.libraryRoot.appendingPathComponent(
                AssistantAttachmentFiles.directoryName,
                isDirectory: true
            ),
            withDestinationURL: outside
        )
        let store = DurableAssistantAttachmentStore(
            database: fixture.database,
            libraryRoot: fixture.libraryRoot
        )

        do {
            _ = try await store.prepare([
                ChatAttachment(
                    id: UUID(),
                    displayName: "Notes.md",
                    kind: .text,
                    stagedURL: source,
                    mediaType: "text/markdown",
                    byteCount: Int64(sourceData.count),
                    sourceIdentity: source.path
                ),
            ], conversationID: UUID(), entryID: UUID())
            XCTFail("expected the symlinked attachment root to be rejected")
        } catch {
            XCTAssertEqual(try Data(contentsOf: protected), protectedData)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [
                "protected.txt",
            ])
        }
    }

    func testCleanupNeverTraversesAttachmentSymlinks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let protected = outside.appendingPathComponent("protected.txt")
        let protectedData = Data("keep me".utf8)
        try protectedData.write(to: protected)
        let root = fixture.libraryRoot.appendingPathComponent(
            AssistantAttachmentFiles.directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let removalLink = root.appendingPathComponent("remove-me", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: removalLink,
            withDestinationURL: outside
        )
        AssistantAttachmentFiles.removeConversation(
            id: "remove-me",
            libraryRoot: fixture.libraryRoot
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: removalLink.path))
        XCTAssertEqual(try Data(contentsOf: protected), protectedData)

        let pendingLink = root.appendingPathComponent(".pending", isDirectory: true)
        let orphanLink = root.appendingPathComponent("orphan", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: pendingLink,
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: orphanLink,
            withDestinationURL: outside
        )
        AssistantAttachmentFiles.reconcile(
            libraryRoot: fixture.libraryRoot,
            storedPaths: []
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingLink.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanLink.path))
        XCTAssertEqual(try Data(contentsOf: protected), protectedData)
    }

    func testCleanupIgnoresSymlinkedAttachmentRoot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
        let conversation = outside.appendingPathComponent("conversation", isDirectory: true)
        try FileManager.default.createDirectory(
            at: conversation,
            withIntermediateDirectories: true
        )
        let protected = conversation.appendingPathComponent("protected.txt")
        let protectedData = Data("keep me".utf8)
        try protectedData.write(to: protected)
        let rootLink = fixture.libraryRoot.appendingPathComponent(
            AssistantAttachmentFiles.directoryName,
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: rootLink,
            withDestinationURL: outside
        )

        AssistantAttachmentFiles.reconcile(
            libraryRoot: fixture.libraryRoot,
            storedPaths: []
        )
        AssistantAttachmentFiles.removeConversation(
            id: "conversation",
            libraryRoot: fixture.libraryRoot
        )

        XCTAssertEqual(try Data(contentsOf: protected), protectedData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootLink.path))
    }

    func testReconcileRemovesPendingAndUnreferencedFinalFiles() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = DurableAssistantAttachmentStore(
            database: fixture.database,
            libraryRoot: fixture.libraryRoot
        )
        let root = fixture.libraryRoot.appendingPathComponent("AssistantAttachments")
        let pending = root.appendingPathComponent(".pending")
        let orphan = root
            .appendingPathComponent("orphan-conversation")
            .appendingPathComponent("orphan-attachment")
            .appendingPathComponent("orphan.txt")
        let hiddenOrphan = root
            .appendingPathComponent("hidden-conversation")
            .appendingPathComponent("hidden-attachment")
            .appendingPathComponent(".notes")
        try FileManager.default.createDirectory(
            at: pending,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: orphan.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: hiddenOrphan.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pendingFile = pending.appendingPathComponent("copy.pending")
        try Data("pending".utf8).write(to: pendingFile)
        try Data("orphan".utf8).write(to: orphan)
        try Data("hidden orphan".utf8).write(to: hiddenOrphan)

        try await store.reconcile()

        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hiddenOrphan.path))
    }

    func testTranscriptThumbnailRegenerationIsBounded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-thumbnail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("pixel.png")
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try png.write(to: image)

        XCTAssertNil(AssistantImageNormalizer.transcriptThumbnailDataURL(
            fileURL: image,
            maxBytes: 1
        ))
        XCTAssertTrue(AssistantImageNormalizer.transcriptThumbnailDataURL(
            fileURL: image,
            maxBytes: 256 * 1_024
        )?.hasPrefix("data:image/") == true)
    }

    private func makeFixture() throws -> (
        root: URL, libraryRoot: URL, database: AppDatabase
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-assistant-attachments-\(UUID().uuidString)")
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(
            at: libraryRoot,
            withIntermediateDirectories: true
        )
        return (root, libraryRoot, try AppDatabase(DatabaseQueue()))
    }
}
#endif
