import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - `mcp` subcommand
//
// A Model Context Protocol server over stdio, exposing Rubien's read APIs as
// MCP tools. This is the in-app content channel for the Assistant sidebar
// (the agent reads the document being discussed through these tools) and a
// native, Node-free replacement for the `rubien-mcp-server` npm package.
//
// Design — re-entrant proxy: each `tools/call` maps the tool + arguments to a
// `rubien-cli <subcommand>` invocation (the exact same translation the npm
// proxy performs) and spawns *this same binary* as a child, passing the
// child's JSON stdout through verbatim. That guarantees the tool output is
// byte-identical to the shipped CLI contract (the child *is* the CLI) with no
// refactor of the read subcommands, and keeps `rubien-mcp-server` and this
// server drop-in interchangeable. `rubien_pdf_page_image` is the sole special
// case: its JSON is re-split into an MCP text-meta block + an `image` block,
// mirroring the npm server's two-block shape (the metadata block is an
// equivalent JSON object, not a byte-for-byte copy of npm's key order).
//
// Per-call subprocess spawn is negligible for an interactive assistant; an
// in-process dispatch is a future optimization if it ever matters.

struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run a Model Context Protocol (MCP) server over stdio, exposing Rubien's read APIs as tools."
    )

    @Flag(
        name: .long,
        help: "Register only read-only tools. This is currently the only supported mode — writes are not yet exposed over MCP."
    )
    var readOnly = false

    func run() throws {
        // v1 serves the read-only tool set regardless of the flag (no write
        // tools exist yet); `--read-only` is accepted for forward-compatibility
        // with the app's invocation `mcp --read-only`.
        let server = MCPServer(tools: MCPToolCatalog.readOnlyTools)
        server.serve()
    }
}

// MARK: - Server

/// A minimal, synchronous MCP-over-stdio server. Reads newline-delimited
/// JSON-RPC 2.0 requests from stdin, writes single-line JSON-RPC responses to
/// stdout, and never writes anything but protocol messages to stdout
/// (diagnostics go to stderr) so the stream stays clean for the MCP client.
final class MCPServer {
    private let tools: [MCPTool]
    private let toolsByName: [String: MCPTool]
    private let selfExecutablePath: String

    /// The MCP protocol version we default to when a client's `initialize`
    /// omits one. We otherwise echo the client's requested version.
    private static let defaultProtocolVersion = "2024-11-05"

    /// Upper bound on a single child read. A wedged child (a pathological PDF
    /// render, a stalled SQLite read) must not hang the single-threaded server
    /// forever; mirrors the npm proxy's default 60s CLI timeout.
    private static let childTimeout: TimeInterval = 60

    init(tools: [MCPTool], selfExecutablePath: String = MCPServer.resolveSelfExecutablePath()) {
        self.tools = tools
        self.toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.selfExecutablePath = selfExecutablePath
    }

    /// Blocking serve loop. Returns when stdin reaches EOF (the client closed
    /// the connection / the turn ended).
    func serve() {
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Parse error — id is unknown, so respond with null id per JSON-RPC.
            writeResponse(id: NSNull(), error: (code: -32700, message: "Parse error"))
            return
        }

        // A JSON-RPC message with no `id` is a *notification* and must never
        // receive a response — for ANY method, not just `notifications/*`. Our
        // read-only server has no notification side effects (initialized /
        // cancelled), so all notifications are simply ignored.
        guard obj.index(forKey: "id") != nil else { return }
        let method = obj["method"] as? String
        let id = obj["id"] ?? NSNull()
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? Self.defaultProtocolVersion
            writeResponse(id: id, result: [
                "protocolVersion": requested,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": [
                    "name": "rubien-cli-mcp",
                    "version": RubienCLIVersion.marketing,
                ],
            ])

        case "ping":
            writeResponse(id: id, result: [String: Any]())

        case "tools/list":
            writeResponse(id: id, result: ["tools": tools.map(\.definition)])

        case "tools/call":
            handleToolCall(id: id, params: params)

        default:
            writeResponse(id: id, error: (code: -32601, message: "Method not found: \(method ?? "<none>")"))
        }
    }

    private func handleToolCall(id: Any, params: [String: Any]) {
        guard let name = params["name"] as? String else {
            writeResponse(id: id, error: (code: -32602, message: "Missing tool name"))
            return
        }
        guard let tool = toolsByName[name] else {
            writeResponse(id: id, error: (code: -32602, message: "Unknown tool: \(name)"))
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        // Argument problems surface as in-band `isError` tool results (visible
        // to the agent), not protocol errors.
        let argv: [String]
        do {
            argv = try tool.buildArgv(arguments)
        } catch let err as MCPToolError {
            writeResponse(id: id, result: Self.errorResult(err.message))
            return
        } catch {
            writeResponse(id: id, result: Self.errorResult(String(describing: error)))
            return
        }

        let outcome = runChild(argv)
        switch outcome {
        case .spawnFailure(let message):
            // Could not run the CLI at all: a protocol-level error.
            writeResponse(id: id, error: (code: -32603, message: message))
        case .timedOut(let seconds):
            // A wedged child is a tool failure surfaced in-band to the agent.
            writeResponse(id: id, result: Self.errorResult("rubien-cli timed out after \(Int(seconds))s"))
        case .completed(let stdout, let stderr, let exitCode):
            if exitCode == 0 {
                writeResponse(id: id, result: tool.shapeSuccess(stdout))
            } else {
                writeResponse(id: id, result: Self.errorResult(Self.extractCLIError(stderr)))
            }
        }
    }

    // MARK: Child process (the re-entrant CLI call)

    private enum ChildOutcome {
        case completed(stdout: Data, stderr: Data, exitCode: Int32)
        case spawnFailure(String)
        case timedOut(TimeInterval)
    }

    /// Spawn `rubien-cli <argv>` and capture its output. The child inherits our
    /// environment (so `RUBIEN_LIBRARY_ROOT` etc. resolve the same library) but
    /// crucially gets a *null* stdin — it must never read from our JSON-RPC
    /// input stream — and pipes for stdout/stderr so it can't pollute our
    /// JSON-RPC output stream.
    private func runChild(_ argv: [String]) -> ChildOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: selfExecutablePath)
        process.arguments = argv
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Launch BEFORE starting the drain workers: if `run()` throws (bad self
        // path, permissions, deleted binary) we return immediately without ever
        // parking a reader on a pipe whose write end will never close.
        do {
            try process.run()
        } catch {
            return .spawnFailure("Failed to launch rubien-cli: \(error.localizedDescription)")
        }

        // Drain both pipes concurrently: a large payload (a rendered page image
        // is ~MBs, far past the ~64KB pipe buffer) would deadlock if we waited
        // for exit before reading.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        group.enter()
        queue.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        queue.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        // Bound the wait so one wedged child can't hang the whole (single-
        // threaded) server. On timeout, escalate SIGTERM → SIGKILL; the child's
        // death closes the pipes, so the drain workers then reach EOF.
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        if exited.wait(timeout: .now() + Self.childTimeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            group.wait()
            return .timedOut(Self.childTimeout)
        }
        group.wait()
        return .completed(stdout: outData, stderr: errData, exitCode: process.terminationStatus)
    }

    // MARK: Response writing

    private func writeResponse(id: Any, result: [String: Any]) {
        writeEnvelope(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func writeResponse(id: Any, error: (code: Int, message: String)) {
        writeEnvelope([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": error.code, "message": error.message],
        ])
    }

    /// Serialize one JSON-RPC message and write it as a single newline-delimited
    /// line directly to fd 1 (no stdio buffering, so no flush races). Embedded
    /// newlines inside string values are JSON-escaped by JSONSerialization, so
    /// the on-wire message never contains a literal newline until our delimiter.
    private func writeEnvelope(_ envelope: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: envelope, options: [.withoutEscapingSlashes]) else {
            // Should be unreachable — every value we insert is JSON-encodable.
            let fallback = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Failed to serialize response"}}"#
            FileHandle.standardOutput.write(Data((fallback + "\n").utf8))
            return
        }
        data.append(0x0A)  // '\n'
        FileHandle.standardOutput.write(data)
    }

    // MARK: Helpers

    /// Build the standard MCP `isError` tool result carrying a text message.
    static func errorResult(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    /// Mirror `rubien-mcp-server`'s CLI error extraction: the CLI prints
    /// `{"error":"..."}` to stderr on a non-zero exit; surface `.error`,
    /// falling back to the raw stderr text.
    static func extractCLIError(_ stderr: Data) -> String {
        let text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty,
           let data = text.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let message = obj["error"] as? String {
            return message
        }
        return text.isEmpty ? "rubien-cli invocation failed" : text
    }

    /// Resolve the absolute path to *this* executable so the child re-entrant
    /// call runs the same binary the app launched.
    static func resolveSelfExecutablePath() -> String {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let raw = String(cString: buffer)
                if let resolved = realpath(raw, nil) {
                    defer { free(resolved) }
                    return String(cString: resolved)
                }
                return raw
            }
        }
        #elseif canImport(Glibc)
        if let resolved = realpath("/proc/self/exe", nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        #endif
        return CommandLine.arguments.first ?? "rubien-cli"
    }
}

// MARK: - Tool definitions

enum MCPToolError: Error {
    case invalidArguments(String)
    var message: String {
        switch self {
        case .invalidArguments(let m): return m
        }
    }
}

/// One MCP tool: its advertised definition (name / description / input schema)
/// and the logic to turn a `tools/call` into a `rubien-cli` argv + to shape the
/// CLI's stdout into an MCP tool result.
struct MCPTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    /// Whether the CLI's JSON stdout is re-split into a text-meta + `image`
    /// block (true only for `rubien_pdf_page_image`).
    let isImage: Bool
    let buildArgv: ([String: Any]) throws -> [String]

    var definition: [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
            "annotations": ["readOnlyHint": true],
        ]
    }

    /// Turn the child's successful stdout into an MCP tool result.
    func shapeSuccess(_ stdout: Data) -> [String: Any] {
        if isImage {
            return Self.shapeImageResult(stdout)
        }
        var text = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = "null" }  // mirror the npm server's empty→null
        return ["content": [["type": "text", "text": text]]]
    }

    /// `rubien_pdf_page_image`: split the CLI JSON `{id,page,mimeType,data,...}`
    /// into a human-readable metadata text block + an MCP `image` block, as
    /// `rubien-mcp-server` does. The metadata block is an equivalent JSON object
    /// (keys sorted for determinism, not npm's insertion order).
    private static func shapeImageResult(_ stdout: Data) -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any],
              let data = obj["data"] as? String,
              let mimeType = obj["mimeType"] as? String else {
            // Unexpected shape — fall back to passing the raw text through.
            let raw = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return ["content": [["type": "text", "text": raw.isEmpty ? "null" : raw]]]
        }
        var meta: [String: Any] = ["mimeType": mimeType]
        for key in ["id", "page", "widthPx", "heightPx", "qualityUsed"] {
            if let value = obj[key] { meta[key] = value }
        }
        let metaText = (try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return [
            "content": [
                ["type": "text", "text": metaText],
                ["type": "image", "data": data, "mimeType": mimeType],
            ],
        ]
    }
}
