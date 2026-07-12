#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import Rubien

/// Locks in the composer's pasteboard routing (what attaches vs. what stays native
/// text editing) and the exact-⌘↩ send chord. The priorities are deliberate and
/// asymmetric — see `ComposerPasteboardRouter`'s doc comment.
final class ComposerTextViewTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("rubien-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private var pngData: Data {
        // Smallest valid 1×1 PNG.
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQAB"
            + "h6FO1AAAAABJRU5ErkJggg==")!
    }

    private func write(fileURL: URL) {
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
    }

    // MARK: Paste routing

    func testPasteWithFileURLAttachesFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-paste-\(UUID().uuidString).png")
        try pngData.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        write(fileURL: file)

        guard case .attachFiles(let urls) = ComposerPasteboardRouter.pasteAction(for: pasteboard)
        else { return XCTFail("expected .attachFiles") }
        XCTAssertEqual(urls.map(\.standardizedFileURL.path), [file.standardizedFileURL.path])
    }

    func testPasteImageOnlyAttachesImageData() {
        pasteboard.setData(pngData, forType: .png)
        XCTAssertEqual(
            ComposerPasteboardRouter.pasteAction(for: pasteboard),
            .attachImageData(pngData))
    }

    /// Spreadsheet-cell / rich-text copies carry an image render *alongside* the
    /// string; the string is what the user meant, so text paste must win.
    func testPasteImageAlongsideStringPassesThrough() {
        pasteboard.declareTypes([.string, .png], owner: nil)
        pasteboard.setString("A1\tB1", forType: .string)
        pasteboard.setData(pngData, forType: .png)
        XCTAssertEqual(ComposerPasteboardRouter.pasteAction(for: pasteboard), .passthrough)
    }

    func testPasteStringOnlyPassesThrough() {
        pasteboard.setString("plain text", forType: .string)
        XCTAssertEqual(ComposerPasteboardRouter.pasteAction(for: pasteboard), .passthrough)
    }

    func testPasteEmptyPasteboardPassesThrough() {
        XCTAssertEqual(ComposerPasteboardRouter.pasteAction(for: pasteboard), .passthrough)
    }

    // MARK: Drop routing

    /// Unlike paste, a *dragged* image is unambiguous: image data outranks the URL
    /// string browsers put on the same drag pasteboard.
    func testDropImageAlongsideStringAttachesImage() {
        pasteboard.declareTypes([.string, .tiff], owner: nil)
        pasteboard.setString("https://example.com/cat.png", forType: .string)
        pasteboard.setData(pngData, forType: .tiff)
        XCTAssertEqual(
            ComposerPasteboardRouter.dropAction(for: pasteboard),
            .attachImageData(pngData))
    }

    func testDropFileURLOutranksImageData() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-drop-\(UUID().uuidString).md")
        try Data("# hi".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        write(fileURL: file)
        pasteboard.setData(pngData, forType: .png)

        guard case .attachFiles = ComposerPasteboardRouter.dropAction(for: pasteboard)
        else { return XCTFail("expected .attachFiles") }
    }

    func testDropPlainTextPassesThroughToTextInsertion() {
        pasteboard.setString("dragged words", forType: .string)
        XCTAssertEqual(ComposerPasteboardRouter.dropAction(for: pasteboard), .passthrough)
    }

    /// Image detection is by dynamic `.image` conformance (in lockstep with what
    /// AssistantAttachmentStore accepts for files), not a baked format list — a
    /// BMP-only pasteboard must attach even though BMP is never spelled out.
    func testImageDetectionIsByUTTypeConformanceNotAFixedList() {
        pasteboard.setData(pngData, forType: NSPasteboard.PasteboardType(UTType.bmp.identifier))
        XCTAssertEqual(
            ComposerPasteboardRouter.pasteAction(for: pasteboard),
            .attachImageData(pngData))
        XCTAssertEqual(
            ComposerPasteboardRouter.dropAction(for: pasteboard),
            .attachImageData(pngData))
    }

    /// The materialization-free feasibility predicates (used on menu-validation and
    /// drag-entry hot paths) must always agree with the full extraction routing.
    func testWouldAttachPredicatesMatchFullRouting() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-parity-\(UUID().uuidString).png")
        try pngData.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let fixtures: [(String, (NSPasteboard) -> Void)] = [
            ("empty", { _ in }),
            ("string only", { $0.setString("words", forType: .string) }),
            ("image only", { $0.setData(self.pngData, forType: .png) }),
            ("string + image", { pb in
                pb.declareTypes([.string, .png], owner: nil)
                pb.setString("words", forType: .string)
                pb.setData(self.pngData, forType: .png)
            }),
            ("file URL", { XCTAssertTrue($0.writeObjects([file as NSURL])) }),
        ]
        for (name, populate) in fixtures {
            let board = NSPasteboard(name: NSPasteboard.Name("rubien-parity-\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.clearContents()
            populate(board)
            XCTAssertEqual(
                ComposerPasteboardRouter.pasteWouldAttach(board),
                ComposerPasteboardRouter.pasteAction(for: board) != .passthrough,
                "paste feasibility diverged from routing for: \(name)")
            XCTAssertEqual(
                ComposerPasteboardRouter.dropWouldAttach(board),
                ComposerPasteboardRouter.dropAction(for: board) != .passthrough,
                "drop feasibility diverged from routing for: \(name)")
        }
    }

    // MARK: ⌘↩ chord

    func testCommandReturnChordMatchesExactlyCommand() {
        let returnKey: UInt16 = 36
        let keypadEnter: UInt16 = 76
        XCTAssertTrue(ComposerNSTextView.isCommandReturnChord(
            keyCode: returnKey, modifierFlags: [.command]))
        // Keyboard-state flags must not dead-key the chord.
        XCTAssertTrue(ComposerNSTextView.isCommandReturnChord(
            keyCode: returnKey, modifierFlags: [.command, .capsLock]))
        XCTAssertTrue(ComposerNSTextView.isCommandReturnChord(
            keyCode: keypadEnter, modifierFlags: [.command, .numericPad, .function]))
        // Only ⌘ exactly — every other modifier combination stays a newline.
        XCTAssertFalse(ComposerNSTextView.isCommandReturnChord(
            keyCode: returnKey, modifierFlags: []))
        XCTAssertFalse(ComposerNSTextView.isCommandReturnChord(
            keyCode: returnKey, modifierFlags: [.command, .shift]))
        XCTAssertFalse(ComposerNSTextView.isCommandReturnChord(
            keyCode: returnKey, modifierFlags: [.command, .option]))
        XCTAssertFalse(ComposerNSTextView.isCommandReturnChord(
            keyCode: returnKey, modifierFlags: [.shift]))
        // Non-return keys never send.
        XCTAssertFalse(ComposerNSTextView.isCommandReturnChord(
            keyCode: 0, modifierFlags: [.command]))
    }
}
#endif
