#if os(macOS)
import XCTest
@testable import Rubien
@testable import RubienCore

final class ReferenceDetailContentRevealWorkerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceDetailContentRevealWorkerTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testMaterializesContentAddressedMarkdownWithoutOverwritingPriorCopy() throws {
        var reference = Reference(
            id: 42,
            title: "A note",
            webContent: Reference.encodeWebContent("First body", format: .markdown),
            referenceType: .markdown
        )

        let firstURL = try ReferenceDetailContentRevealWorker.materialize(
            reference: reference,
            storageRoot: temporaryRoot
        )

        XCTAssertTrue(firstURL.lastPathComponent.hasPrefix("Reference-42-"))
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "First body")

        let repeatedURL = try ReferenceDetailContentRevealWorker.materialize(
            reference: reference,
            storageRoot: temporaryRoot
        )
        XCTAssertEqual(repeatedURL, firstURL)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: repeatedURL.path
        )
        let readOnlyURL = try ReferenceDetailContentRevealWorker.materialize(
            reference: reference,
            storageRoot: temporaryRoot
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: readOnlyURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o444)

        reference.webContent = Reference.encodeWebContent("Updated body", format: .markdown)
        let secondURL = try ReferenceDetailContentRevealWorker.materialize(
            reference: reference,
            storageRoot: temporaryRoot
        )

        XCTAssertNotEqual(secondURL, firstURL)
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "First body")
        XCTAssertEqual(try String(contentsOf: secondURL, encoding: .utf8), "Updated body")
    }

    func testPreservesUserModifiedCopyAndCreatesFreshCurrentCopy() throws {
        let reference = Reference(
            id: 42,
            title: "A note",
            webContent: Reference.encodeWebContent("Stored body", format: .markdown),
            referenceType: .markdown
        )
        let firstURL = try ReferenceDetailContentRevealWorker.materialize(
            reference: reference,
            storageRoot: temporaryRoot
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: firstURL.path
        )
        try Data("User edit".utf8).write(to: firstURL, options: .atomic)

        let currentURL = try ReferenceDetailContentRevealWorker.materialize(
            reference: reference,
            storageRoot: temporaryRoot
        )

        XCTAssertNotEqual(currentURL, firstURL)
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "User edit")
        XCTAssertEqual(try String(contentsOf: currentURL, encoding: .utf8), "Stored body")
    }

    func testConcurrentDifferentContentsUseDifferentPaths() async throws {
        let storageRoot = try XCTUnwrap(temporaryRoot)
        let first = Reference(
            id: 42,
            title: "A note",
            webContent: Reference.encodeWebContent("First body", format: .markdown),
            referenceType: .markdown
        )
        let second = Reference(
            id: 42,
            title: "A note",
            webContent: Reference.encodeWebContent("Second body", format: .markdown),
            referenceType: .markdown
        )

        async let firstURL = Task.detached {
            try ReferenceDetailContentRevealWorker.materialize(
                reference: first,
                storageRoot: storageRoot
            )
        }.value
        async let secondURL = Task.detached {
            try ReferenceDetailContentRevealWorker.materialize(
                reference: second,
                storageRoot: storageRoot
            )
        }.value
        let urls = try await (firstURL, secondURL)

        XCTAssertNotEqual(urls.0, urls.1)
        XCTAssertEqual(try String(contentsOf: urls.0, encoding: .utf8), "First body")
        XCTAssertEqual(try String(contentsOf: urls.1, encoding: .utf8), "Second body")
    }

    func testRejectsReferencesWithoutStoredContent() throws {
        let unsaved = Reference(
            title: "Unsaved",
            webContent: Reference.encodeWebContent("Body", format: .markdown),
            referenceType: .markdown
        )
        XCTAssertThrowsError(
            try ReferenceDetailContentRevealWorker.materialize(
                reference: unsaved,
                storageRoot: temporaryRoot
            )
        ) { error in
            XCTAssertEqual(
                error as? ReferenceDetailContentRevealWorker.MaterializationError,
                .missingReferenceID
            )
        }

        let empty = Reference(
            id: 7,
            title: "Empty",
            referenceType: .markdown
        )
        XCTAssertThrowsError(
            try ReferenceDetailContentRevealWorker.materialize(
                reference: empty,
                storageRoot: temporaryRoot
            )
        ) { error in
            XCTAssertEqual(
                error as? ReferenceDetailContentRevealWorker.MaterializationError,
                .missingContent
            )
        }
    }

    func testMaterializesStoredHTMLRegardlessOfReferenceType() throws {
        let webClip = Reference(
            id: 9,
            title: "Web clip",
            webContent: Reference.encodeWebContent("Body", format: .markdown),
            referenceType: .webpage
        )
        let reclassified = Reference(
            id: 10,
            title: "Reclassified note",
            webContent: Reference.encodeWebContent("Body", format: .markdown),
            referenceType: .book
        )
        let htmlClip = Reference(
            id: 11,
            title: "HTML clip",
            webContent: Reference.encodeWebContent("<article>Body</article>", format: .html),
            referenceType: .webpage
        )

        XCTAssertNoThrow(
            try ReferenceDetailContentRevealWorker.materialize(
                reference: webClip,
                storageRoot: temporaryRoot
            )
        )
        XCTAssertNoThrow(
            try ReferenceDetailContentRevealWorker.materialize(
                reference: reclassified,
                storageRoot: temporaryRoot
            )
        )

        let htmlURL = try ReferenceDetailContentRevealWorker.materialize(
            reference: htmlClip,
            storageRoot: temporaryRoot
        )
        XCTAssertEqual(htmlURL.pathExtension, "html")
        XCTAssertEqual(
            try String(contentsOf: htmlURL, encoding: .utf8),
            "<article>Body</article>"
        )
    }
}
#endif
