import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RubienCore

/// Isolated URLProtocol stub for import-source acquisition tests. Keeping this
/// separate from PaperURLResolverTests avoids coupling unrelated test suites.
final class ImportSourceURLProtocol: URLProtocol {
    struct Stub {
        let data: Data
        let response: HTTPURLResponse
    }

    nonisolated(unsafe) static var stubs: [URL: Stub] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.stubs[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        client?.urlProtocol(self, didReceive: stub.response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        stubs = [:]
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImportSourceURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func stub(
        _ urlString: String,
        status: Int = 200,
        contentType: String,
        data: Data
    ) {
        let url = URL(string: urlString)!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        stubs[url] = Stub(data: data, response: response)
    }
}

final class ImportSourceMaterializerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ImportSourceURLProtocol.reset()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSourceMaterializerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ImportSourceURLProtocol.reset()
        try? FileManager.default.removeItem(at: temporaryRoot)
        temporaryRoot = nil
        try super.tearDownWithError()
    }

    func testLocalMarkdownIsClassifiedWithoutTemporaryCleanupOwnership() async throws {
        let sourceURL = temporaryRoot.appendingPathComponent("note.markdown")
        try Data("# Local note".utf8).write(to: sourceURL)

        let materialized = try await ImportSourceMaterializer.materialize(
            sourceURL.path,
            localPathPolicy: .requireAbsolute,
            session: ImportSourceURLProtocol.makeSession()
        )

        XCTAssertEqual(materialized.input, sourceURL.path)
        XCTAssertEqual(materialized.fileURL, sourceURL)
        XCTAssertEqual(materialized.kind, .markdown)
        XCTAssertNil(materialized.temporaryDirectoryURL)

        materialized.cleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testExistingLocalFileURLRetainsTheSelectedURLWithoutRebuildingItFromPath() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("selected.md")
        try Data("# Selected note".utf8).write(to: sourceURL)
        // A security-scoped URL contains access state not recoverable from
        // `path`. A noncanonical path gives this test a deterministic way to
        // detect the same destructive path → URL reconstruction.
        let selectedURL = URL(fileURLWithPath: temporaryRoot.path + "/./selected.md")
        let reconstructedURL = URL(fileURLWithPath: selectedURL.path).standardizedFileURL
        XCTAssertNotEqual(selectedURL.absoluteString, reconstructedURL.absoluteString)

        let materialized = try ImportSourceMaterializer.materialize(localFileURL: selectedURL)

        XCTAssertEqual(materialized.fileURL.absoluteString, selectedURL.absoluteString)
        XCTAssertEqual(materialized.kind, .markdown)
        XCTAssertNil(materialized.temporaryDirectoryURL)
        materialized.cleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testRemotePlainTextMarkdownUsesOriginalFilenameAndCleansUp() async throws {
        let remoteURL = "https://example.test/notes/research-note.md"
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "text/plain; charset=utf-8",
            data: Data("# Downloaded note".utf8)
        )

        let materialized = try await ImportSourceMaterializer.materialize(
            remoteURL,
            localPathPolicy: .requireAbsolute,
            session: ImportSourceURLProtocol.makeSession()
        )

        XCTAssertEqual(materialized.input, remoteURL)
        XCTAssertEqual(materialized.kind, .markdown)
        XCTAssertEqual(materialized.fileURL.lastPathComponent, "research-note.md")
        XCTAssertEqual(try String(contentsOf: materialized.fileURL, encoding: .utf8), "# Downloaded note")
        XCTAssertTrue(materialized.temporaryDirectoryURL?.lastPathComponent.hasPrefix("RubienImport-") == true)

        let temporaryDirectoryURL = try XCTUnwrap(materialized.temporaryDirectoryURL)
        materialized.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectoryURL.path))
    }

    func testRemotePDFUsesOriginalFilenameAndCleansUp() async throws {
        let remoteURL = "https://example.test/papers/method.pdf"
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "application/pdf",
            data: Data("%PDF-1.7\nexample".utf8)
        )

        let materialized = try await ImportSourceMaterializer.materialize(
            remoteURL,
            localPathPolicy: .requireAbsolute,
            session: ImportSourceURLProtocol.makeSession()
        )

        XCTAssertEqual(materialized.kind, .pdf)
        XCTAssertEqual(materialized.fileURL.lastPathComponent, "method.pdf")
        XCTAssertEqual(try Data(contentsOf: materialized.fileURL), Data("%PDF-1.7\nexample".utf8))

        let temporaryDirectoryURL = try XCTUnwrap(materialized.temporaryDirectoryURL)
        materialized.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectoryURL.path))
    }

    func testRemotePDFRejectsInvalidContentTypeWithLocalizedDescription() async {
        let remoteURL = "https://example.test/papers/error.pdf"
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "text/html",
            data: Data("<html>not a PDF</html>".utf8)
        )

        await assertLocalizedMaterializationError(for: remoteURL)
    }

    func testRemotePDFRejectsInvalidMagicWithLocalizedDescription() async {
        let remoteURL = "https://example.test/papers/invalid.pdf"
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "application/pdf",
            data: Data("not a PDF".utf8)
        )

        await assertLocalizedMaterializationError(for: remoteURL)
    }

    func testRemoteMarkdownRejectsHTMLWithLocalizedDescription() async {
        let remoteURL = "https://example.test/notes/error.md"
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "text/html",
            data: Data("<html>not a note</html>".utf8)
        )

        await assertLocalizedMaterializationError(for: remoteURL)
    }

    func testRemoteMarkdownRejectsInvalidUTF8WithLocalizedDescription() async {
        let remoteURL = "https://example.test/notes/binary.md"
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "text/markdown",
            data: Data([0xFF, 0xFE, 0xFD])
        )

        await assertLocalizedMaterializationError(for: remoteURL)
    }

    func testRemoteMarkdownRejectsNonSuccessStatusWithLocalizedDescription() async {
        let remoteURL = "https://example.test/notes/missing.md"
        ImportSourceURLProtocol.stub(
            remoteURL,
            status: 404,
            contentType: "text/plain",
            data: Data()
        )

        await assertLocalizedMaterializationError(for: remoteURL)
    }

    func testUnsupportedExtensionIsRejectedWithLocalizedDescription() async {
        await assertLocalizedMaterializationError(for: "https://example.test/notes/unsupported.txt")
    }

    func testNonRegularLocalPathIsRejectedWithLocalizedDescription() async throws {
        let directoryURL = temporaryRoot.appendingPathComponent("directory.md", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        await assertLocalizedMaterializationError(for: directoryURL.path)
    }

    func testMarkdownLargerThan50MiBIsRejectedWithLocalizedDescription() async throws {
        let sourceURL = temporaryRoot.appendingPathComponent("large.md")
        FileManager.default.createFile(atPath: sourceURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.truncate(atOffset: 50 * 1024 * 1024 + 1)
        try handle.close()

        await assertLocalizedMaterializationError(for: sourceURL.path)
    }

    private func assertLocalizedMaterializationError(
        for input: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await ImportSourceMaterializer.materialize(
                input,
                localPathPolicy: .requireAbsolute,
                session: ImportSourceURLProtocol.makeSession()
            )
            XCTFail("Expected materialization to fail", file: file, line: line)
        } catch {
            let localizedError = error as? LocalizedError
            XCTAssertNotNil(localizedError?.errorDescription, "Expected LocalizedError text, got: \(error)", file: file, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
    }
}
