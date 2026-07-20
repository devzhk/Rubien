import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Dispatch
import XCTest
#if canImport(Network)
import Network
#endif
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
        headers: [String: String] = [:],
        data: Data
    ) {
        let url = URL(string: urlString)!
        var responseHeaders = headers
        responseHeaders["Content-Type"] = contentType
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: responseHeaders
        )!
        stubs[url] = Stub(data: data, response: response)
    }
}

/// Sends headers immediately but holds its body until the test releases it.
/// Its late protocol-client calls intentionally happen after `stopLoading()`.
final class DelayedMarkdownURLProtocol: URLProtocol {
    nonisolated(unsafe) static var response: HTTPURLResponse!
    nonisolated(unsafe) static var data = Data()
    nonisolated(unsafe) static var requestStarted: XCTestExpectation?
    nonisolated(unsafe) static var stopLoadingCalled: XCTestExpectation?
    nonisolated(unsafe) static var delayedCallbackAttempted: XCTestExpectation?
    nonisolated(unsafe) static var gate = DispatchSemaphore(value: 0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didReceive: Self.response, cacheStoragePolicy: .notAllowed)
        Self.requestStarted?.fulfill()

        let gate = Self.gate
        DispatchQueue.global().async { [self] in
            gate.wait()

            client?.urlProtocol(self, didLoad: Self.data)
            client?.urlProtocolDidFinishLoading(self)
            Self.delayedCallbackAttempted?.fulfill()
        }
    }

    override func stopLoading() {
        Self.stopLoadingCalled?.fulfill()
    }

    static func configure(
        url: URL,
        requestStarted: XCTestExpectation,
        stopLoadingCalled: XCTestExpectation,
        delayedCallbackAttempted: XCTestExpectation
    ) {
        response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain"]
        )!
        data = Data("# Delayed note".utf8)
        self.requestStarted = requestStarted
        self.stopLoadingCalled = stopLoadingCalled
        self.delayedCallbackAttempted = delayedCallbackAttempted
        gate = DispatchSemaphore(value: 0)
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedMarkdownURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func releaseDelayedCallback() {
        gate.signal()
    }

    static func reset() {
        response = nil
        data = Data()
        requestStarted = nil
        stopLoadingCalled = nil
        delayedCallbackAttempted = nil
        gate.signal()
    }
}

#if canImport(Network)
/// A loopback HTTP peer that delivers one body chunk, then waits. Unlike a
/// custom URLProtocol, this exercises URLSession's real streaming callbacks.
final class StreamingMarkdownHTTPServer {
    /// URLSession batches very small HTTP body fragments before invoking its
    /// data delegate, so use one modest chunk to observe a real partial write.
    static let initialPayloadByteCount = 64 * 1024
    private static let initialPayload = Data(repeating: 0x61, count: initialPayloadByteCount)
    private static let delayedPayload = Data("# Delayed streamed note\n".utf8)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.rubien.tests.streaming-markdown-server")
    private let releaseGate = DispatchSemaphore(value: 0)
    private let listenerReady: XCTestExpectation
    private let initialPayloadSent: XCTestExpectation
    private let delayedPayloadAttempted: XCTestExpectation
    private var connection: NWConnection?

    init(
        listenerReady: XCTestExpectation,
        initialPayloadSent: XCTestExpectation,
        delayedPayloadAttempted: XCTestExpectation
    ) throws {
        self.listenerReady = listenerReady
        self.initialPayloadSent = initialPayloadSent
        self.delayedPayloadAttempted = delayedPayloadAttempted
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.listenerReady.fulfill()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func url(for filename: String) -> URL? {
        guard let port = listener.port else { return nil }
        return URL(string: "http://127.0.0.1:\(port.rawValue)/notes/\(filename)")
    }

    func releaseDelayedPayload() {
        releaseGate.signal()
    }

    func stop() {
        releaseGate.signal()
        connection?.cancel()
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] _, _, _, error in
            guard let self, error == nil else { return }
            self.sendInitialResponse(on: connection)
        }
    }

    private func sendInitialResponse(on connection: NWConnection) {
        let contentLength = Self.initialPayload.count + Self.delayedPayload.count
        let headers = Data((
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/plain\r\n" +
            "Content-Length: \(contentLength)\r\n" +
            "Connection: close\r\n\r\n"
        ).utf8)
        connection.send(content: headers, completion: .contentProcessed { _ in })
        connection.send(content: Self.initialPayload, completion: .contentProcessed { [weak self] _ in
            self?.initialPayloadSent.fulfill()
        })

        DispatchQueue.global().async { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.releaseGate.wait()
            self.queue.async { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.sendDelayedResponse(on: connection)
            }
        }
    }

    private func sendDelayedResponse(on connection: NWConnection) {
        connection.send(content: Self.delayedPayload, completion: .contentProcessed { _ in })
        connection.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
        delayedPayloadAttempted.fulfill()
    }
}
#endif

final class ImportSourceMaterializerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ImportSourceURLProtocol.reset()
        DelayedMarkdownURLProtocol.reset()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSourceMaterializerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ImportSourceURLProtocol.reset()
        DelayedMarkdownURLProtocol.reset()
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

    func testRelativeFilenameWithColonClassifiesAsLocalNotURL() async throws {
        // A colon is legal in POSIX filenames, and the relative form
        // "notes:2026.md" parses as scheme "notes" under URL(string:). Only
        // explicit `scheme://` syntax may classify as a URL — a bare `name:`
        // prefix must take the local-path route and import.
        let sourceURL = temporaryRoot.appendingPathComponent("notes:2026.md")
        try Data("# Colon note".utf8).write(to: sourceURL)

        let materialized = try await ImportSourceMaterializer.materialize(
            "notes:2026.md",
            localPathPolicy: .resolveRelative(to: temporaryRoot),
            session: ImportSourceURLProtocol.makeSession()
        )

        XCTAssertEqual(materialized.input, "notes:2026.md")
        XCTAssertEqual(materialized.fileURL.standardizedFileURL, sourceURL.standardizedFileURL)
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

    func testTemporaryLocalCopySurvivesSourceRemovalAndOwnsCleanup() throws {
        let sourceURL = temporaryRoot.appendingPathComponent("browser-download.pdf")
        let contents = Data("%PDF-1.7\n".utf8)
        try contents.write(to: sourceURL)

        let materialized = try ImportSourceMaterializer.materializeTemporaryCopy(
            localFileURL: sourceURL,
            originalInput: "https://example.test/browser-download.pdf"
        )
        try FileManager.default.removeItem(at: sourceURL)

        XCTAssertEqual(materialized.input, "https://example.test/browser-download.pdf")
        XCTAssertEqual(materialized.kind, .pdf)
        XCTAssertEqual(try Data(contentsOf: materialized.fileURL), contents)
        XCTAssertNotNil(materialized.temporaryDirectoryURL)

        let temporaryDirectoryURL = try XCTUnwrap(materialized.temporaryDirectoryURL)
        materialized.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectoryURL.path))
    }

    // The remote-import tests below drive ImportSourceURLProtocol; its normal
    // client callbacks (urlProtocolDidFinishLoading) crash swift-corelibs
    // FoundationNetworking on Linux (TaskRegistry "task not in registry"), a
    // known limitation of custom URLProtocol support there. Darwin-only via the
    // file's canImport(Network) convention; the local-path tests stay on Linux.
    #if canImport(Network)
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

    func testGitHubBlobPDFRequestsRawDownloadAndPreservesInput() async throws {
        let input = "https://github.com/acme/research/blob/main/paper.pdf?raw=0&download=1"
        let requestedRawURL = "https://github.com/acme/research/blob/main/paper.pdf?download=1&raw=1"
        ImportSourceURLProtocol.stub(
            requestedRawURL,
            contentType: "application/octet-stream",
            data: Data("%PDF-1.7\nGitHub raw".utf8)
        )

        let materialized = try await ImportSourceMaterializer.materialize(
            input,
            localPathPolicy: .requireAbsolute,
            session: ImportSourceURLProtocol.makeSession()
        )

        XCTAssertEqual(materialized.input, input)
        XCTAssertEqual(materialized.kind, .pdf)
        XCTAssertEqual(try Data(contentsOf: materialized.fileURL), Data("%PDF-1.7\nGitHub raw".utf8))

        let temporaryDirectoryURL = try XCTUnwrap(materialized.temporaryDirectoryURL)
        materialized.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectoryURL.path))
    }

    func testGitHubBlobMarkdownRequestsRawDownloadAndPreservesInput() async throws {
        let input = "https://github.com/acme/research/blob/feature/docs/notes/reading-list.md"
        let requestedRawURL = "https://github.com/acme/research/blob/feature/docs/notes/reading-list.md?raw=1"
        ImportSourceURLProtocol.stub(
            requestedRawURL,
            contentType: "text/plain",
            data: Data("# GitHub raw note".utf8)
        )

        let materialized = try await ImportSourceMaterializer.materialize(
            input,
            localPathPolicy: .requireAbsolute,
            session: ImportSourceURLProtocol.makeSession()
        )

        XCTAssertEqual(materialized.input, input)
        XCTAssertEqual(materialized.kind, .markdown)
        XCTAssertEqual(try String(contentsOf: materialized.fileURL, encoding: .utf8), "# GitHub raw note")

        let temporaryDirectoryURL = try XCTUnwrap(materialized.temporaryDirectoryURL)
        materialized.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectoryURL.path))
    }

    func testRemoteMarkdownRejectsDecodedTraversalFilenameWithoutEscapingOwnedDirectory() async {
        let escapedName = "escaped-\(UUID().uuidString).md"
        let remoteURL = "https://example.test/%2E%2E%2F\(escapedName)"
        let escapedURL = FileManager.default.temporaryDirectory.appendingPathComponent(escapedName)
        defer { try? FileManager.default.removeItem(at: escapedURL) }
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "text/plain",
            data: Data("# Attempted traversal".utf8)
        )

        do {
            let materialized = try await ImportSourceMaterializer.materialize(
                remoteURL,
                localPathPolicy: .requireAbsolute,
                session: ImportSourceURLProtocol.makeSession()
            )
            materialized.cleanup()
            XCTFail("Expected decoded traversal filename to be rejected")
        } catch {
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedURL.path))
    }
    #endif

    // Darwin-only: this test forces a URLProtocol client callback after
    // stopLoading() to prove production ignores it. swift-corelibs
    // FoundationNetworking (Linux) fatal-errors on such late callbacks
    // (TaskRegistry "task not in registry"), so the scenario is unexercisable
    // there — guarded with this file's canImport(Network) Mac-only convention.
    #if canImport(Network)
    func testDelayedProtocolCallbacksAfterCancellationDoNotResumeMaterialization() async throws {
        // Darwin buffers custom URLProtocol body delivery until it finishes,
        // so this isolates the forced stale-callback race. The loopback test
        // below covers cleanup of a real, partially written source file.
        let filename = "delayed-\(UUID().uuidString).md"
        let remoteURL = URL(string: "https://example.test/notes/\(filename)")!
        let requestStarted = expectation(description: "request started")
        let stopLoadingCalled = expectation(description: "URLProtocol stopped")
        let delayedCallbackAttempted = expectation(description: "delayed callback attempted")
        DelayedMarkdownURLProtocol.configure(
            url: remoteURL,
            requestStarted: requestStarted,
            stopLoadingCalled: stopLoadingCalled,
            delayedCallbackAttempted: delayedCallbackAttempted
        )
        defer { DelayedMarkdownURLProtocol.releaseDelayedCallback() }

        let importTask = Task {
            try await ImportSourceMaterializer.materialize(
                remoteURL.absoluteString,
                localPathPolicy: .requireAbsolute,
                session: DelayedMarkdownURLProtocol.makeSession()
            )
        }
        let completion = expectation(description: "cancelled import completes")
        _ = Task {
            _ = await importTask.result
            completion.fulfill()
        }

        await fulfillment(of: [requestStarted], timeout: 1)
        importTask.cancel()
        await fulfillment(of: [completion, stopLoadingCalled], timeout: 1)
        DelayedMarkdownURLProtocol.releaseDelayedCallback()
        await fulfillment(of: [delayedCallbackAttempted], timeout: 1)

        switch await importTask.result {
        case .success(let materialized):
            materialized.cleanup()
            XCTFail("Cancellation returned a materialized source")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got: \(error)")
        }
    }
    #endif

    #if canImport(Network)
    func testCancellingStreamedRemoteMarkdownRemovesTemporarySource() async throws {
        let filename = "streamed-\(UUID().uuidString).md"
        let listenerReady = expectation(description: "loopback listener ready")
        let initialPayloadSent = expectation(description: "initial payload sent")
        let delayedPayloadAttempted = expectation(description: "late payload and finish attempted")
        let server = try StreamingMarkdownHTTPServer(
            listenerReady: listenerReady,
            initialPayloadSent: initialPayloadSent,
            delayedPayloadAttempted: delayedPayloadAttempted
        )
        defer { server.stop() }

        await fulfillment(of: [listenerReady], timeout: 1)
        let remoteURL = try XCTUnwrap(server.url(for: filename))
        let session = URLSession(configuration: .ephemeral)
        let importTask = Task {
            try await ImportSourceMaterializer.materialize(
                remoteURL.absoluteString,
                localPathPolicy: .requireAbsolute,
                session: session
            )
        }
        let completion = expectation(description: "cancelled import completes")
        _ = Task {
            _ = await importTask.result
            completion.fulfill()
        }

        await fulfillment(of: [initialPayloadSent], timeout: 1)
        guard let ownedDirectory = await waitForTemporaryImportDirectory(
            containing: filename,
            minimumFileSize: StreamingMarkdownHTTPServer.initialPayloadByteCount
        ) else {
            importTask.cancel()
            await fulfillment(of: [completion], timeout: 1)
            server.releaseDelayedPayload()
            await fulfillment(of: [delayedPayloadAttempted], timeout: 1)
            if case .success(let materialized) = await importTask.result {
                materialized.cleanup()
            }
            XCTFail("Expected a test-owned temporary Markdown file before cancellation")
            return
        }
        defer { try? FileManager.default.removeItem(at: ownedDirectory) }
        let partialFile = ownedDirectory.appendingPathComponent(filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialFile.path))
        let partialValues = try partialFile.resourceValues(forKeys: [.fileSizeKey])
        let partialSize = try XCTUnwrap(partialValues.fileSize)
        XCTAssertGreaterThanOrEqual(
            partialSize,
            StreamingMarkdownHTTPServer.initialPayloadByteCount
        )

        importTask.cancel()
        await fulfillment(of: [completion], timeout: 1)
        server.releaseDelayedPayload()
        await fulfillment(of: [delayedPayloadAttempted], timeout: 1)

        switch await importTask.result {
        case .success(let materialized):
            materialized.cleanup()
            XCTFail("Cancellation returned a materialized source")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedDirectory.path))
    }
    #endif

    #if canImport(Network)
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

    func testRemoteMarkdownRejectsAdvertisedContentLengthAboveLimit() async {
        let remoteURL = "https://example.test/notes/advertised-large.md"
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "text/plain",
            headers: ["Content-Length": String(maximumMarkdownBytes + 1)],
            data: Data("small body".utf8)
        )

        await assertMarkdownTooLarge(for: remoteURL)
    }

    func testRemoteMarkdownRejectsOverLimitBodyWithoutContentLength() async {
        let remoteURL = "https://example.test/notes/chunked-large.md"
        ImportSourceURLProtocol.stub(
            remoteURL,
            contentType: "text/plain",
            data: Data(repeating: 0x61, count: maximumMarkdownBytes + 1)
        )

        await assertMarkdownTooLarge(for: remoteURL)
    }

    func testUnsupportedExtensionIsRejectedWithLocalizedDescription() async {
        await assertLocalizedMaterializationError(for: "https://example.test/notes/unsupported.txt")
    }
    #endif

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

    private func assertMarkdownTooLarge(
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
            XCTFail("Expected Markdown size limit failure", file: file, line: line)
        } catch let error as ImportSourceMaterializer.MaterializationError {
            guard case .markdownTooLarge = error else {
                XCTFail("Expected markdownTooLarge, got: \(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("Expected markdownTooLarge, got: \(error)", file: file, line: line)
        }
    }

    private let maximumMarkdownBytes = 50 * 1024 * 1024

    private func waitForTemporaryImportDirectory(
        containing filename: String,
        minimumFileSize: Int
    ) async -> URL? {
        for _ in 0..<100 {
            let temporaryDirectory = FileManager.default.temporaryDirectory
            let names = (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? []
            for name in names where name.hasPrefix("RubienImport-") {
                let directoryURL = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
                let fileURL = directoryURL.appendingPathComponent(filename)
                let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if fileSize >= minimumFileSize {
                    return directoryURL
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

}
