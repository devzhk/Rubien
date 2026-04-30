import XCTest
@testable import RubienCore

final class PDFContentHasherTests: XCTestCase {

    func testHashesKnownContent() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hasher-\(UUID().uuidString).bin")
        try Data("hello world".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hash = try PDFContentHasher.sha256(of: tmp)

        // Known SHA-256 of "hello world" (lowercase hex).
        XCTAssertEqual(hash, "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
    }

    func testHashesEmptyFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hasher-\(UUID().uuidString).bin")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hash = try PDFContentHasher.sha256(of: tmp)
        XCTAssertEqual(hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testRejectsNonexistentFile() {
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).pdf")
        XCTAssertThrowsError(try PDFContentHasher.sha256(of: bogus))
    }
}
