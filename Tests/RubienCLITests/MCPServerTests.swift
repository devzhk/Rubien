import XCTest
import Foundation

/// Integration tests for `rubien-cli mcp` — the native MCP-over-stdio server
/// that exposes Rubien's read APIs as tools (the Assistant sidebar's content
/// channel; a Node-free replacement for the `rubien-mcp-server` npm package).
///
/// Black-box, like the rest of RubienCLITests: drive the built binary as a
/// subprocess with an isolated `RUBIEN_LIBRARY_ROOT`, speaking newline-delimited
/// JSON-RPC 2.0 on its stdio. The tool contract mirrors `mcp-server/src/tools/*.ts`.
final class MCPServerTests: XCTestCase {

    private var cliBinaryPath: String {
        let debugPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RubienCLITests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent(".build/debug/rubien-cli")
            .path
        if FileManager.default.isExecutableFile(atPath: debugPath) { return debugPath }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/rubien-cli") {
            return "/usr/local/bin/rubien-cli"
        }
        return debugPath
    }

    private lazy var testLibraryRoot: URL = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rubien-mcp-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: testLibraryRoot)
    }

    private func skipIfBinaryMissing() throws {
        guard FileManager.default.isExecutableFile(atPath: cliBinaryPath) else {
            throw XCTSkip("CLI binary not found at \(cliBinaryPath). Run `swift build` first.")
        }
    }

    // The 8 read-only content tools the native server must advertise, mirroring
    // the read tools in mcp-server/src/tools/*.ts.
    private let expectedToolNames: Set<String> = [
        "rubien_search_references", "rubien_list_references", "rubien_get_reference",
        "rubien_get_pdf_info", "rubien_render_pdf_page",
        "rubien_read_text", "rubien_read_annotations", "rubien_grep_text",
    ]

    // MARK: - Process helpers

    /// Run a one-shot `rubien-cli` subcommand (used to seed / cross-check parity).
    @discardableResult
    private func runCLI(_ arguments: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinaryPath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["RUBIEN_LIBRARY_ROOT"] = testLibraryRoot.path
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        group.enter(); queue.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); queue.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        try process.run()
        process.waitUntilExit()
        group.wait()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self), process.terminationStatus)
    }

    /// Feed newline-delimited JSON-RPC requests to `rubien-cli mcp` and collect
    /// the parsed responses (in order). Closing stdin drives the server to EOF.
    private func runMCP(_ requestLines: [String]) throws -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinaryPath)
        process.arguments = ["mcp", "--read-only"]
        var env = ProcessInfo.processInfo.environment
        env["RUBIEN_LIBRARY_ROOT"] = testLibraryRoot.path
        process.environment = env
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        group.enter(); queue.async { outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); queue.async { errData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        try process.run()
        let input = Data((requestLines.joined(separator: "\n") + "\n").utf8)
        stdinPipe.fileHandleForWriting.write(input)
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        group.wait()
        _ = errData

        var responses: [[String: Any]] = []
        for line in String(decoding: outData, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            if let data = line.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                responses.append(obj)
            }
        }
        return responses
    }

    // MARK: JSON-RPC request builders

    private func req(id: Int, method: String, params: [String: Any]? = nil) -> String {
        var obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { obj["params"] = params }
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    private func toolCall(id: Int, name: String, arguments: [String: Any]) -> String {
        req(id: id, method: "tools/call", params: ["name": name, "arguments": arguments])
    }

    private func response(_ responses: [[String: Any]], id: Int) -> [String: Any]? {
        responses.first { ($0["id"] as? NSNumber)?.intValue == id }
    }

    // MARK: Seeding

    @discardableResult
    private func seedTitle(_ title: String) throws -> Int {
        let result = try runCLI(["add", "--title", title])
        XCTAssertEqual(result.exitCode, 0, "seed add failed: \(result.stderr)")
        let obj = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        let ref = (obj?["items"] as? [[String: Any]])?.first?["reference"] as? [String: Any]
        let id = (ref?["id"] as? NSNumber)?.intValue
        return try XCTUnwrap(id, "could not read seeded reference id from: \(result.stdout)")
    }

    // MARK: - Protocol handshake

    func testInitializeReportsServerInfoAndEchoesProtocol() throws {
        try skipIfBinaryMissing()
        let responses = try runMCP([
            req(id: 1, method: "initialize", params: ["protocolVersion": "2025-06-18", "capabilities": [String: Any]()]),
        ])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18", "server should echo the client's protocol version")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "rubien-cli-mcp")
        XCTAssertFalse((serverInfo["version"] as? String ?? "").isEmpty)
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"], "must advertise tools capability")
    }

    func testToolsListAdvertisesTheEightReadTools() throws {
        try skipIfBinaryMissing()
        let responses = try runMCP([req(id: 1, method: "tools/list")])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])

        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, expectedToolNames, "native tool set must mirror the npm server's read tools")

        for tool in tools {
            let name = tool["name"] as? String ?? "<none>"
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty, "\(name) missing description")
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any], "\(name) missing inputSchema")
            XCTAssertEqual(schema["type"] as? String, "object", "\(name) schema not an object")
            XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true,
                           "\(name) must be annotated readOnlyHint:true")
        }

        // Required-argument contract for a couple of representative tools.
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { t -> (String, [String: Any])? in
            (t["name"] as? String).map { ($0, t) }
        })
        func required(_ name: String) -> [String] {
            ((byName[name]?["inputSchema"] as? [String: Any])?["required"] as? [String]) ?? []
        }
        XCTAssertEqual(Set(required("rubien_render_pdf_page")), ["id", "page"])
        XCTAssertEqual(required("rubien_search_references"), ["query"])
        XCTAssertEqual(required("rubien_read_annotations"), ["id"])
        XCTAssertEqual(required("rubien_read_text"), ["id"])
        XCTAssertEqual(required("rubien_list_references"), [])
    }

    func testPingAndUnknownMethodAndUnknownTool() throws {
        try skipIfBinaryMissing()
        let responses = try runMCP([
            req(id: 1, method: "ping"),
            req(id: 2, method: "totally/bogus"),
            toolCall(id: 3, name: "rubien_nope", arguments: [:]),
        ])
        XCTAssertNotNil(response(responses, id: 1)?["result"] as? [String: Any], "ping should return an empty result object")

        let unknownMethod = try XCTUnwrap(response(responses, id: 2)?["error"] as? [String: Any])
        XCTAssertEqual(unknownMethod["code"] as? NSNumber, -32601)

        let unknownTool = try XCTUnwrap(response(responses, id: 3)?["error"] as? [String: Any])
        XCTAssertEqual(unknownTool["code"] as? NSNumber, -32602)
    }

    func testNotificationProducesNoResponse() throws {
        try skipIfBinaryMissing()
        // A JSON-RPC notification (no id) must never get a response line — for
        // ANY method, including known request methods like ping / tools/list.
        let responses = try runMCP([
            req(id: 1, method: "initialize", params: ["capabilities": [String: Any]()]),
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","method":"ping"}"#,
            #"{"jsonrpc":"2.0","method":"tools/list"}"#,
            req(id: 2, method: "ping"),
        ])
        XCTAssertEqual(responses.count, 2, "only the id'd requests (1,2) should get responses; got \(responses.count)")
        XCTAssertNotNil(response(responses, id: 1))
        XCTAssertNotNil(response(responses, id: 2))
    }

    func testInvalidArgumentTypesAreRejected() throws {
        try skipIfBinaryMissing()
        // Wrong-typed arguments must be rejected as tool errors, not coerced
        // (a JSON bool bridges to NSNumber → would silently become `get 1`) or
        // silently dropped (a string where an int is expected).
        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_get_reference", arguments: ["id": true]),
            toolCall(id: 2, name: "rubien_get_reference", arguments: ["id": "5"]),
            toolCall(id: 3, name: "rubien_search_references", arguments: ["query": 5]),
            toolCall(id: 4, name: "rubien_read_text", arguments: ["id": 1, "maxChars": 1.5]),
        ])
        for id in 1...4 {
            let result = try XCTUnwrap(response(responses, id: id)?["result"] as? [String: Any], "id \(id)")
            XCTAssertEqual(result["isError"] as? Bool, true, "id \(id) should reject the bad argument type")
        }
    }

    func testReadTextPagesAndSectionsAreMutuallyExclusive() throws {
        try skipIfBinaryMissing()
        // The exclusivity check happens before spawning, so it needs no PDF.
        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_read_text", arguments: ["id": 1, "pages": "1-3", "sections": ["Intro"]]),
        ])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.lowercased().contains("mutually exclusive"), "got: \(text)")
    }

    func testReadTextPagesAndStartAreMutuallyExclusive() throws {
        try skipIfBinaryMissing()
        // pages (PDF addressing) and start (web addressing) can't combine; the
        // check runs before spawning, so it needs no attached content.
        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_read_text", arguments: ["id": 1, "pages": "1", "start": 0]),
        ])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.lowercased().contains("mutually exclusive"), "got: \(text)")
    }

    // MARK: - Text tools

    func testGetMatchesDirectCLIOutput() throws {
        try skipIfBinaryMissing()
        let id = try seedTitle("Attention Is All You Need")

        // Direct CLI output.
        let direct = try runCLI(["get", String(id)])
        XCTAssertEqual(direct.exitCode, 0)
        let directJSON = try JSONSerialization.jsonObject(with: Data(direct.stdout.utf8))

        // Same read through the MCP tool.
        let responses = try runMCP([toolCall(id: 1, name: "rubien_get_reference", arguments: ["id": id])])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertNil(result["isError"], "get on an existing ref must not be an error")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let mcpJSON = try JSONSerialization.jsonObject(with: Data(text.utf8))

        // Semantic equality: the MCP text block carries the exact CLI DTO.
        XCTAssertEqual(
            NSDictionary(dictionary: mcpJSON as! [String: Any]),
            NSDictionary(dictionary: directJSON as! [String: Any]),
            "MCP rubien_get must return the identical DTO as `rubien-cli get`"
        )
    }

    func testSearchAndListReturnArrays() throws {
        try skipIfBinaryMissing()
        try seedTitle("Deep Residual Learning")
        try seedTitle("Attention Is All You Need")

        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_search_references", arguments: ["query": "attention"]),
            toolCall(id: 2, name: "rubien_list_references", arguments: ["limit": 10]),
        ])
        for id in [1, 2] {
            let result = try XCTUnwrap(response(responses, id: id)?["result"] as? [String: Any])
            XCTAssertNil(result["isError"])
            let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
            let arr = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any]
            XCTAssertNotNil(arr, "id \(id) should return a JSON array")
        }
        // The search for "attention" should find at least the matching title.
        let searchText = ((response(responses, id: 1)?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(searchText.contains("Attention Is All You Need"))
    }

    func testAnnotationsListEmptyIsSuccessNotError() throws {
        try skipIfBinaryMissing()
        let id = try seedTitle("No Annotations Here")
        let responses = try runMCP([toolCall(id: 1, name: "rubien_read_annotations", arguments: ["id": id])])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertNil(result["isError"], "an empty annotation list is success, not an error")
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let arr = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any]
        XCTAssertEqual(arr?.count, 0)
    }

    func testMissingRequiredArgumentSurfacesAsIsError() throws {
        try skipIfBinaryMissing()
        let responses = try runMCP([toolCall(id: 1, name: "rubien_get_reference", arguments: [:])])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("id"), "message should name the missing argument: \(text)")
    }

    func testCLIErrorSurfacesAsIsError() throws {
        try skipIfBinaryMissing()
        let id = try seedTitle("Metadata-only reference")
        // A metadata-only reference has no readable content → the CLI exits
        // non-zero with {"error":...} → the server maps it to an isError result.
        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_read_text", arguments: ["id": id]),
            toolCall(id: 2, name: "rubien_get_pdf_info", arguments: ["id": id]),
        ])
        let read = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(read["isError"] as? Bool, true)
        XCTAssertTrue(((read["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").lowercased().contains("no readable content"))

        let pdf = try XCTUnwrap(response(responses, id: 2)?["result"] as? [String: Any])
        XCTAssertEqual(pdf["isError"] as? Bool, true)
        XCTAssertTrue(((pdf["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").lowercased().contains("pdf"))
    }

    func testReadTextEmptyPagesTreatedAsAbsent() throws {
        try skipIfBinaryMissing()
        // Two-catalog parity: the Node server drops an empty `pages` string
        // (`Boolean("")` is false), so this catalog must too. A metadata-only
        // ref with pages:"" therefore routes to the neither-available branch
        // ("no readable content"), NOT the pdf-unavailable branch ("source
        // \"pdf\" is not readable") that a stray `--pages ""` would trigger.
        let id = try seedTitle("Empty pages routing")
        let responses = try runMCP([toolCall(id: 1, name: "rubien_read_text", arguments: ["id": id, "pages": ""])])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").lowercased()
        XCTAssertTrue(text.contains("no readable content"),
                      "empty pages must be dropped (route to neither-branch); got: \(text)")
        XCTAssertFalse(text.contains("source \"pdf\""),
                       "empty pages must not imply a pdf source; got: \(text)")
    }

    // MARK: - Grep tool (kind-agnostic body-text search)

    func testGrepTextRequiredArgs() throws {
        try skipIfBinaryMissing()
        // `required(_:)` in testToolsListAdvertisesTheEightReadTools is a LOCAL
        // function; do the lookup locally here.
        let responses = try runMCP([req(id: 1, method: "tools/list")])
        let tools = try XCTUnwrap(
            (response(responses, id: 1)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let grep = try XCTUnwrap(tools.first { ($0["name"] as? String) == "rubien_grep_text" })
        let requiredArgs = (grep["inputSchema"] as? [String: Any])?["required"] as? [String]
        XCTAssertEqual(requiredArgs?.sorted(), ["id", "query"])
    }

    #if os(macOS)
    func testGrepTextPdfFamilyFlagsForwarded() throws {
        try skipIfBinaryMissing()
        // Behavioral proof that regex/pages/maxPages/snippetsPerPage/contextChars
        // all reach the CLI: a fully-flagged pdf-family call succeeds, scoped to
        // page 2, via a regex query.
        let id = try importFixturePDF()
        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_grep_text",
                     arguments: ["id": id, "query": "pa+ge", "regex": true, "pages": "2",
                                 "maxPages": 5, "snippetsPerPage": 2, "contextChars": 80]),
        ])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertNil(result["isError"], "\(result)")
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(json["source"] as? String, "pdf")
        XCTAssertEqual(json["isRegex"] as? Bool, true)
        let hits = json["pages"] as? [[String: Any]] ?? []
        XCTAssertTrue(hits.allSatisfy { ($0["page"] as? NSNumber)?.intValue == 2 }, "\(hits)")
    }
    #endif

    func testGrepTextWebFamilyFlagForwarded() throws {
        try skipIfBinaryMissing()
        // maxMatches implies web; on a metadata-only ref the web source is
        // unavailable — the CLI error proves the flag was forwarded + interpreted.
        let id = try seedTitle("Grep web-family forwarding")
        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_grep_text",
                     arguments: ["id": id, "query": "x", "maxMatches": 3]),
        ])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").lowercased()
        XCTAssertTrue(text.contains("web"), "error must show the web-implied routing: \(text)")
    }

    func testGrepTextMixedScopesRejected() throws {
        try skipIfBinaryMissing()
        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_grep_text",
                     arguments: ["id": 1, "query": "x", "maxPages": 5, "maxMatches": 5]),
        ])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.lowercased().contains("mutually exclusive"), text)
    }

    func testGrepTextEmptyPagesTreatedAsAbsent() throws {
        try skipIfBinaryMissing()
        let id = try seedTitle("Grep empty pages")
        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_grep_text", arguments: ["id": id, "query": "x", "pages": ""]),
        ])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").lowercased()
        XCTAssertTrue(text.contains("no readable content"), text)   // routed to neither-branch, not pdf
    }

    func testGrepTextWebEndToEnd() throws {
        try skipIfBinaryMissing()
        let id = try seedTitle("Grep MCP e2e")
        // no web-content write path via MCP → this metadata-only ref errors;
        // the CLI-level GrepCommandTests own the happy path. Assert the error
        // surfaces as isError with the routing message:
        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_grep_text", arguments: ["id": id, "query": "needle"]),
        ])
        let result = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue((((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "").contains("no readable content"))
    }

    // MARK: - PDF tools (need a rendered page → macOS/PDFKit)

    #if os(macOS)
    /// Build a minimal Zotero export folder that attaches a real fixture PDF,
    /// import it, and return the new reference id.
    private func importFixturePDF() throws -> Int {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()  // Tests/
            .appendingPathComponent("RubienPDFKitTests/Fixtures/PDFs/linear-3pages-text.pdf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path),
                          "fixture PDF missing at \(fixture.path)")

        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-zotero-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("RL", isDirectory: true)
        let filesDir = folder.appendingPathComponent("files/1", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try FileManager.default.copyItem(at: fixture, to: filesDir.appendingPathComponent("paper.pdf"))
        let bib = """
        @article{paper1,
            title = {Linear Three Pages},
            author = {Test, Author},
            file = {PDF:files/1/paper.pdf:application/pdf},
        }
        """
        try bib.write(to: folder.appendingPathComponent("RL.bib"), atomically: true, encoding: .utf8)

        let importResult = try runCLI(["add", "--source", folder.path])
        XCTAssertEqual(importResult.exitCode, 0, "zotero import failed: \(importResult.stderr)")

        // Fresh library → the imported reference is the only one.
        let list = try runCLI(["list", "--limit", "1"])
        let arr = try JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [[String: Any]]
        let id = (arr?.first?["id"] as? NSNumber)?.intValue
        return try XCTUnwrap(id, "no reference after import: \(list.stdout)")
    }

    func testPdfInfoAndTextAndPageImageSplit() throws {
        try skipIfBinaryMissing()
        let id = try importFixturePDF()

        let responses = try runMCP([
            toolCall(id: 1, name: "rubien_get_pdf_info", arguments: ["id": id]),
            toolCall(id: 2, name: "rubien_read_text", arguments: ["id": id, "pages": "1"]),
            toolCall(id: 3, name: "rubien_render_pdf_page", arguments: ["id": id, "page": 1]),
        ])

        // pdf_info → text block carrying pageCount.
        let infoResult = try XCTUnwrap(response(responses, id: 1)?["result"] as? [String: Any])
        XCTAssertNil(infoResult["isError"])
        let infoText = try XCTUnwrap((infoResult["content"] as? [[String: Any]])?.first?["text"] as? String)
        let info = try JSONSerialization.jsonObject(with: Data(infoText.utf8)) as? [String: Any]
        XCTAssertEqual((info?["pageCount"] as? NSNumber)?.intValue, 3)

        // read_text on a PDF ref → page-keyed body, source-tagged pdf.
        let textResult = try XCTUnwrap(response(responses, id: 2)?["result"] as? [String: Any])
        XCTAssertNil(textResult["isError"])
        let textText = try XCTUnwrap((textResult["content"] as? [[String: Any]])?.first?["text"] as? String)
        let textObj = try JSONSerialization.jsonObject(with: Data(textText.utf8)) as? [String: Any]
        XCTAssertNotNil(textObj?["pages"] as? [Any])
        XCTAssertEqual(textObj?["source"] as? String, "pdf")
        XCTAssertEqual(textObj?["available"] as? [String], ["pdf"])

        // pdf_page_image → TWO content blocks: text meta + an image block.
        let imgResult = try XCTUnwrap(response(responses, id: 3)?["result"] as? [String: Any])
        XCTAssertNil(imgResult["isError"], "page-image should render, not error")
        let blocks = try XCTUnwrap(imgResult["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2, "page-image must split into text-meta + image blocks")
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
        XCTAssertEqual(blocks[1]["type"] as? String, "image")
        let mime = try XCTUnwrap(blocks[1]["mimeType"] as? String)
        XCTAssertTrue(mime.hasPrefix("image/"), "unexpected image mimeType: \(mime)")
        XCTAssertFalse((blocks[1]["data"] as? String ?? "").isEmpty, "image block must carry base64 data")
        // The metadata text must not carry the raw base64 payload.
        XCTAssertFalse((blocks[0]["text"] as? String ?? "").contains(blocks[1]["data"] as? String ?? "MISSING"))
    }
    #endif
}
