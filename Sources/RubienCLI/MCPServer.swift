import ArgumentParser
import Foundation
import RubienCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - `mcp` subcommand
//
// A Model Context Protocol server over stdio, exposing Rubien's library APIs
// as MCP tools. This is the in-app content channel for the Assistant sidebar
// and a native, Node-free replacement for the `rubien-mcp-server` npm package.
//
// Design — re-entrant proxy: each `tools/call` maps the tool + arguments to a
// `rubien-cli <subcommand>` invocation (the exact same translation the npm
// proxy performs) and spawns *this same binary* as a child, passing the
// child's JSON stdout through verbatim. That guarantees the tool output is
// byte-identical to the shipped CLI contract (the child *is* the CLI) with no
// refactor of the read subcommands, and keeps `rubien-mcp-server` and this
// server drop-in interchangeable. `rubien_render_pdf_page` is the sole special
// case: its JSON is re-split into an MCP text-meta block + an `image` block,
// mirroring the npm server's two-block shape (the metadata block is an
// equivalent JSON object, not a byte-for-byte copy of npm's key order).
//
// Per-call subprocess spawn is negligible for an interactive assistant; an
// in-process dispatch is a future optimization if it ever matters.

struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run a Model Context Protocol (MCP) server over stdio, exposing Rubien's library tools."
    )

    @Flag(
        name: .long,
        help: "Register only read-only tools. Without this flag, the full read/write catalog is exposed."
    )
    var readOnly = false

    func run() throws {
        var tools = readOnly ? MCPToolCatalog.readOnlyTools : MCPToolCatalog.allTools
        if ProcessInfo.processInfo.environment["RUBIEN_APP_PRESENTATION"] == "1" {
            tools += MCPAppPresentationToolCatalog.tools
        }
        if !readOnly,
           ProcessInfo.processInfo.environment[RubienAppSchedulingContract.environmentKey]
            == RubienAppSchedulingContract.environmentValue {
            tools += MCPAppSchedulingToolCatalog.tools
        }
        let server = MCPServer(tools: tools)
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
        // The server has no notification side effects (initialized / cancelled),
        // so all notifications are simply ignored.
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
        let arguments: [String: Any]
        if let rawArguments = params["arguments"] {
            guard let object = rawArguments as? [String: Any] else {
                writeResponse(id: id, result: Self.errorResult("`arguments` must be an object"))
                return
            }
            arguments = object
        } else {
            arguments = [:]
        }

        // Argument problems surface as in-band `isError` tool results (visible
        // to the agent), not protocol errors.
        let argv: [String]
        do {
            try tool.validate(arguments)
            argv = try tool.buildArgv(arguments)
        } catch let err as MCPToolError {
            writeResponse(id: id, result: Self.errorResult(err.message))
            return
        } catch {
            writeResponse(id: id, result: Self.errorResult(String(describing: error)))
            return
        }

        if let directHandler = tool.directHandler {
            do {
                writeResponse(id: id, result: try directHandler(arguments))
            } catch let err as MCPToolError {
                writeResponse(id: id, result: Self.errorResult(err.message))
            } catch {
                writeResponse(id: id, result: Self.errorResult(String(describing: error)))
            }
            return
        }

        let outcome = runChild(argv, timeout: tool.timeout)
        switch outcome {
        case .spawnFailure(let message):
            // Could not run the CLI at all: a protocol-level error.
            writeResponse(id: id, error: (code: -32603, message: message))
        case .timedOut(let seconds):
            // A wedged child is a tool failure surfaced in-band to the agent.
            writeResponse(id: id, result: Self.errorResult("rubien-cli timed out after \(Int(seconds))s"))
        case .outputTooLarge(let bytes):
            writeResponse(id: id, result: Self.errorResult(
                "rubien-cli output exceeded the \(bytes / 1_048_576) MiB MCP limit"
            ))
        case .completed(let stdout, let stderr, let exitCode):
            if exitCode == 0 {
                writeResponse(id: id, result: tool.shapeSuccess(stdout, argv: argv))
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
        case outputTooLarge(Int)
    }

    private static let maximumCapturedBytes = 32 * 1_024 * 1_024

    /// Spawn `rubien-cli <argv>` and capture its output. The child inherits our
    /// environment (so `RUBIEN_LIBRARY_ROOT` etc. resolve the same library) but
    /// crucially gets a *null* stdin — it must never read from our JSON-RPC
    /// input stream — and pipes for stdout/stderr so it can't pollute our
    /// JSON-RPC output stream.
    private func runChild(_ argv: [String], timeout: TimeInterval) -> ChildOutcome {
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
        let childEvent = DispatchSemaphore(value: 0)
        let outputLimit = OutputLimitSignal(event: childEvent)
        let outCapture = BoundedPipeCapture(
            limit: Self.maximumCapturedBytes,
            onLimitExceeded: { outputLimit.trip() }
        )
        let errCapture = BoundedPipeCapture(
            limit: Self.maximumCapturedBytes,
            onLimitExceeded: { outputLimit.trip() }
        )
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        group.enter()
        queue.async {
            outCapture.drain(outPipe.fileHandleForReading)
            group.leave()
        }
        group.enter()
        queue.async {
            errCapture.drain(errPipe.fileHandleForReading)
            group.leave()
        }

        // Bound the wait so one wedged child can't hang the whole (single-
        // threaded) server. On timeout, escalate SIGTERM → SIGKILL; the child's
        // death closes the pipes, so the drain workers then reach EOF.
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
            childEvent.signal()
        }
        if childEvent.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            group.wait()
            return .timedOut(timeout)
        }
        if outputLimit.wasTripped {
            // Match Node's maxBuffer behavior: stop the child as soon as either
            // stream crosses the cap instead of discarding output until the
            // ordinary (potentially five-minute) tool timeout.
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            group.wait()
            return .outputTooLarge(Self.maximumCapturedBytes)
        }
        group.wait()
        guard !outCapture.exceeded, !errCapture.exceeded else {
            return .outputTooLarge(Self.maximumCapturedBytes)
        }
        return .completed(
            stdout: outCapture.data,
            stderr: errCapture.data,
            exitCode: process.terminationStatus
        )
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

    /// Preserve the CLI's complete stderr payload. Most failures are structured
    /// JSON envelopes whose fields (`code`, `details`, recovery hints, …) are
    /// part of the CLI contract and must remain available to MCP clients.
    static func extractCLIError(_ stderr: Data) -> String {
        let text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Coordinates the first output-limit event across stdout and stderr.
private final class OutputLimitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let event: DispatchSemaphore
    private var tripped = false

    init(event: DispatchSemaphore) {
        self.event = event
    }

    var wasTripped: Bool {
        lock.withLock { tripped }
    }

    func trip() {
        let isFirst = lock.withLock { () -> Bool in
            guard !tripped else { return false }
            tripped = true
            return true
        }
        if isFirst { event.signal() }
    }
}

/// Drains a child pipe to EOF while retaining at most `limit` bytes. Crossing
/// the cap wakes the process runner so it can terminate the verbose child.
private final class BoundedPipeCapture: @unchecked Sendable {
    private let limit: Int
    private let onLimitExceeded: @Sendable () -> Void
    private(set) var data = Data()
    private(set) var exceeded = false

    init(limit: Int, onLimitExceeded: @escaping @Sendable () -> Void) {
        self.limit = limit
        self.onLimitExceeded = onLimitExceeded
        data.reserveCapacity(min(limit, 64 * 1_024))
    }

    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.readData(ofLength: 64 * 1_024)
            guard !chunk.isEmpty else { return }
            let remaining = limit - data.count
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining, !exceeded {
                exceeded = true
                onLimitExceeded()
            }
        }
    }
}

/// The subset of JSON Schema used by Rubien's MCP catalog. Keeping validation
/// next to the advertised schemas prevents clients from bypassing bounds merely
/// because the native server is a thin CLI proxy.
private enum MCPJSONSchemaValidator {
    static func validate(_ value: Any, against schema: [String: Any], path: String) throws {
        if let alternatives = schema["oneOf"] as? [[String: Any]] {
            let matchCount = alternatives.reduce(into: 0) { count, alternative in
                if (try? validate(value, against: alternative, path: path)) != nil {
                    count += 1
                }
            }
            guard matchCount == 1 else {
                throw MCPToolError.invalidArguments(
                    "`\(path)` must match exactly one allowed shape"
                )
            }
        }

        if let alternatives = schema["anyOf"] as? [[String: Any]] {
            if alternatives.contains(where: { (try? validate(value, against: $0, path: path)) != nil }) {
                return
            }
            throw MCPToolError.invalidArguments("`\(path)` does not match any allowed shape")
        }

        if let allowed = schema["enum"] as? [String] {
            guard let string = value as? String, allowed.contains(string) else {
                throw MCPToolError.invalidArguments("`\(path)` must be one of: \(allowed.joined(separator: ", "))")
            }
        }

        guard let type = schema["type"] as? String else { return }
        switch type {
        case "null":
            guard value is NSNull else { throw typeError(path, expected: "null") }

        case "boolean":
            guard mcpIsJSONBool(value) else { throw typeError(path, expected: "a boolean") }

        case "integer":
            guard let integer = mcpExactInt(value) else {
                throw typeError(path, expected: "an integer")
            }
            try validateNumber(Double(integer), schema: schema, path: path)

        case "number":
            guard !mcpIsJSONBool(value), let number = value as? NSNumber,
                  number.doubleValue.isFinite else {
                throw typeError(path, expected: "a number")
            }
            try validateNumber(number.doubleValue, schema: schema, path: path)

        case "string":
            guard let string = value as? String else { throw typeError(path, expected: "a string") }
            if let minimum = schema["minLength"] as? NSNumber, string.count < minimum.intValue {
                throw MCPToolError.invalidArguments("`\(path)` must contain at least \(minimum) character(s)")
            }
            if let maximum = schema["maxLength"] as? NSNumber, string.count > maximum.intValue {
                throw MCPToolError.invalidArguments("`\(path)` must contain at most \(maximum) character(s)")
            }

        case "array":
            guard let array = value as? [Any] else { throw typeError(path, expected: "an array") }
            if let minimum = schema["minItems"] as? NSNumber, array.count < minimum.intValue {
                throw MCPToolError.invalidArguments("`\(path)` must contain at least \(minimum) item(s)")
            }
            if let maximum = schema["maxItems"] as? NSNumber, array.count > maximum.intValue {
                throw MCPToolError.invalidArguments("`\(path)` must contain at most \(maximum) item(s)")
            }
            if let itemSchema = schema["items"] as? [String: Any] {
                for (index, item) in array.enumerated() {
                    try validate(item, against: itemSchema, path: "\(path)[\(index)]")
                }
            }

        case "object":
            guard let object = value as? [String: Any] else { throw typeError(path, expected: "an object") }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil {
                throw MCPToolError.invalidArguments("Missing required argument: \(key)")
            }
            for (key, item) in object {
                if let childSchema = properties[key] as? [String: Any] {
                    try validate(item, against: childSchema, path: key)
                } else if let additionalSchema = schema["additionalProperties"] as? [String: Any] {
                    try validate(item, against: additionalSchema, path: key)
                } else if schema["additionalProperties"] as? Bool == false {
                    throw MCPToolError.invalidArguments("Unknown argument: \(key)")
                }
            }

        default:
            return
        }
    }

    private static func validateNumber(
        _ value: Double,
        schema: [String: Any],
        path: String
    ) throws {
        if let minimum = schema["minimum"] as? NSNumber, value < minimum.doubleValue {
            throw MCPToolError.invalidArguments("`\(path)` must be at least \(minimum)")
        }
        if let minimum = schema["exclusiveMinimum"] as? NSNumber, value <= minimum.doubleValue {
            throw MCPToolError.invalidArguments("`\(path)` must be greater than \(minimum)")
        }
        if let maximum = schema["maximum"] as? NSNumber, value > maximum.doubleValue {
            throw MCPToolError.invalidArguments("`\(path)` must be at most \(maximum)")
        }
        if let maximum = schema["exclusiveMaximum"] as? NSNumber, value >= maximum.doubleValue {
            throw MCPToolError.invalidArguments("`\(path)` must be less than \(maximum)")
        }
    }

    private static func typeError(_ path: String, expected: String) -> MCPToolError {
        .invalidArguments("`\(path)` must be \(expected)")
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
    let access: RubienMCPToolAccess
    let destructive: Bool
    let idempotent: Bool?
    let timeout: TimeInterval
    let wrapsTextExport: Bool
    /// Whether the CLI's JSON stdout is re-split into a text-meta + `image`
    /// block (true only for `rubien_render_pdf_page`).
    let isImage: Bool
    let buildArgv: ([String: Any]) throws -> [String]
    /// App-private tools can execute in the MCP host without introducing a
    /// standalone CLI command. Public tools keep using the re-entrant child.
    let directHandler: (([String: Any]) throws -> [String: Any])?

    init(
        name: String,
        description: String,
        inputSchema: [String: Any],
        access: RubienMCPToolAccess = .read,
        destructive: Bool = false,
        idempotent: Bool? = nil,
        timeout: TimeInterval = 60,
        wrapsTextExport: Bool = false,
        isImage: Bool,
        buildArgv: @escaping ([String: Any]) throws -> [String],
        validatesPublicPolicy: Bool = true,
        directHandler: (([String: Any]) throws -> [String: Any])? = nil
    ) {
        if validatesPublicPolicy {
            precondition(
                RubienMCPToolPolicy.access(for: name) == access,
                "MCP tool \(name) is missing from, or disagrees with, RubienMCPToolPolicy"
            )
        }
        self.name = name
        self.description = description
        var normalizedSchema = inputSchema
        if normalizedSchema["type"] as? String == "object",
           let properties = normalizedSchema["properties"] as? [String: Any],
           !properties.isEmpty,
           normalizedSchema["additionalProperties"] == nil {
            normalizedSchema["additionalProperties"] = false
        }
        self.inputSchema = normalizedSchema
        self.access = access
        self.destructive = destructive
        self.idempotent = idempotent
        self.timeout = timeout
        self.wrapsTextExport = wrapsTextExport
        self.isImage = isImage
        self.buildArgv = buildArgv
        self.directHandler = directHandler
    }

    var definition: [String: Any] {
        var annotations: [String: Any] = ["readOnlyHint": access == .read]
        if access == .write { annotations["destructiveHint"] = destructive }
        if let idempotent { annotations["idempotentHint"] = idempotent }
        return [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
            "annotations": annotations,
        ]
    }

    func validate(_ arguments: [String: Any]) throws {
        try MCPJSONSchemaValidator.validate(arguments, against: inputSchema, path: "arguments")
    }

    /// Turn the child's successful stdout into an MCP tool result.
    func shapeSuccess(_ stdout: Data, argv: [String]) -> [String: Any] {
        if isImage {
            return Self.shapeImageResult(stdout)
        }
        if wrapsTextExport,
           let formatIndex = argv.firstIndex(of: "--format"),
           formatIndex + 1 < argv.count,
           ["bibtex", "ris"].contains(argv[formatIndex + 1]) {
            let format = argv[formatIndex + 1]
            let envelope: [String: Any] = [
                "format": format,
                "text": String(decoding: stdout, as: UTF8.self),
            ]
            let data = try? JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            let text = data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return ["content": [["type": "text", "text": text]]]
        }
        var text = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = "null" }  // mirror the npm server's empty→null
        return ["content": [["type": "text", "text": text]]]
    }

    /// `rubien_render_pdf_page`: split the CLI JSON `{id,page,mimeType,data,...}`
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
