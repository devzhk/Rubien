#if os(macOS)
import Foundation
import XCTest
@testable import Rubien

final class AssistantAttachmentManifestTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/ws/.rubien/attachments", isDirectory: true)

    private func attachment(path: String? = nil) -> ChatAttachment {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        return ChatAttachment(
            id: id,
            displayName: "notes \"α\".md",
            kind: .text,
            stagedURL: URL(
                fileURLWithPath: path
                    ?? "/tmp/ws/.rubien/attachments/C/\(id.uuidString)-notes.md"
            ),
            mediaType: "text/markdown",
            byteCount: 42,
            sourceIdentity: "/original/notes.md"
        )
    }

    func testRoundTripKeepsProviderAndVisibleTextSeparate() {
        let prompt = AssistantAttachmentManifest.providerPrompt(
            base: "Inspect the attached files.",
            visibleText: "",
            attachments: [attachment()]
        )
        let parsed = AssistantAttachmentManifest.parse(prompt, managedRoot: root)

        XCTAssertEqual(parsed.visibleText, "")
        XCTAssertEqual(parsed.attachments.map(\.displayName), ["notes \"α\".md"])
        XCTAssertTrue(prompt.contains("<rubien-attachments-v1>"))
    }

    func testMalformedAndOutsideRootManifestsStayVisible() {
        let lookalike = "hello\n<rubien-attachments-v1>\n{}\n</rubien-attachments-v1>"
        XCTAssertEqual(
            AssistantAttachmentManifest.parse(lookalike, managedRoot: root).visibleText,
            lookalike
        )

        let outside = AssistantAttachmentManifest.providerPrompt(
            base: "Q",
            visibleText: "Q",
            attachments: [attachment(path: "/etc/passwd")]
        )
        XCTAssertEqual(
            AssistantAttachmentManifest.parse(outside, managedRoot: root).visibleText,
            outside
        )
    }

    func testMissingStagedFileBecomesUnavailablePresentation() {
        let prompt = AssistantAttachmentManifest.providerPrompt(
            base: "Q",
            visibleText: "Q",
            attachments: [attachment()]
        )

        XCTAssertEqual(
            AssistantAttachmentManifest.parse(prompt, managedRoot: root)
                .attachments.first?.isAvailable,
            false
        )
    }
}
#endif
