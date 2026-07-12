import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

// MARK: - Tool catalog
//
// The read-only tool set exposed by `rubien-cli mcp`. Names, descriptions, and
// input schemas mirror the `rubien-mcp-server` npm package
// (`mcp-server/src/tools/*.ts`) so the two servers are drop-in interchangeable;
// keep them in lockstep. Each tool maps to the identical `rubien-cli`
// subcommand invocation the npm proxy uses — cross-argument validation (e.g.
// read_text's pages/sections and pages/start exclusivity, its maxChars bounds)
// is left to the CLI, the single source of truth, rather than duplicated here.

enum MCPToolCatalog {
    static let readOnlyTools: [MCPTool] = [
        searchTool,
        listTool,
        getTool,
        pdfInfoTool,
        pdfPageImageTool,
        readTextTool,
        readAnnotationsTool,
    ]

    // MARK: references

    private static let searchTool = MCPTool(
        name: "rubien_search",
        description: "Full-text search across the Rubien library. By default searches all 12 indexed FTS columns (title, authors, abstract, notes, journal, doi, publisher, isbn, issn, institution, webContent, siteName). Use `in` to constrain to specific columns — e.g. `in: ['title','abstract']` for topic searches that should ignore notes/web content. Use `op: 'or'` when looking for any of several alternative terms instead of all of them. Returns an array of ReferenceDTO.",
        inputSchema: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Search query (space-separated tokens)"],
                "limit": ["type": "integer", "exclusiveMinimum": 0, "maximum": 500, "description": "Maximum results (default 20)"],
                "in": [
                    "type": "array",
                    "items": ["type": "string", "enum": ["title", "abstract", "notes", "authors", "journal", "doi", "publisher", "isbn", "issn", "institution", "webContent", "siteName"]],
                    "description": "Restrict FTS to these columns (default: all 12 indexed columns).",
                ],
                "op": ["type": "string", "enum": ["and", "or"], "description": "Combine multiple query tokens with AND (every token must match) or OR (any token). Default: and."],
            ],
            "required": ["query"],
        ],
        isImage: false,
        buildArgv: { args in
            guard let query = try mcpString(args, "query") else {
                throw MCPToolError.invalidArguments("Missing required argument: query")
            }
            var argv = ["search", query]
            mcpAppendInt(&argv, "--limit", try mcpInt(args, "limit"))
            if let inFields = try mcpStringArray(args, "in"), !inFields.isEmpty {
                argv += ["--in", inFields.joined(separator: ",")]
            }
            mcpAppendString(&argv, "--op", try mcpString(args, "op"))
            return argv
        }
    )

    private static let listTool = MCPTool(
        name: "rubien_list",
        description: "List references with filters and sorting. Returns ReferenceDTO[]. Use this for 'most recent', 'by author', 'by year range' queries.",
        inputSchema: [
            "type": "object",
            "properties": [
                "limit": ["type": "integer", "minimum": 0, "description": "Maximum results (0 = all)"],
                "offset": ["type": "integer", "minimum": 0, "description": "Skip first N"],
                "tag": ["type": "integer", "description": "Filter by tag ID"],
                "author": ["type": "string", "description": "Filter by author name (fuzzy)"],
                "yearFrom": ["type": "integer"],
                "yearTo": ["type": "integer"],
                "journal": ["type": "string", "description": "Filter by journal name (fuzzy)"],
                "type": ["type": "string", "description": "Reference type, e.g. 'Journal Article'"],
                "hasPdf": ["type": "boolean"],
                "keyword": ["type": "string", "description": "Keyword across title/abstract/notes"],
                "readingStatus": ["type": "string", "enum": ["unread", "reading", "skimmed", "read"]],
                "sortBy": ["type": "string", "enum": ["year", "dateAdded", "title"]],
                "asc": ["type": "boolean", "description": "Sort ascending (default is descending)"],
            ],
        ],
        isImage: false,
        buildArgv: { args in
            var argv = ["list"]
            mcpAppendInt(&argv, "--limit", try mcpInt(args, "limit"))
            mcpAppendInt(&argv, "--offset", try mcpInt(args, "offset"))
            mcpAppendInt(&argv, "--tag", try mcpInt(args, "tag"))
            mcpAppendString(&argv, "--author", try mcpString(args, "author"))
            mcpAppendInt(&argv, "--year-from", try mcpInt(args, "yearFrom"))
            mcpAppendInt(&argv, "--year-to", try mcpInt(args, "yearTo"))
            mcpAppendString(&argv, "--journal", try mcpString(args, "journal"))
            mcpAppendString(&argv, "--type", try mcpString(args, "type"))
            mcpAppendFlag(&argv, "--has-pdf", try mcpBool(args, "hasPdf"))
            mcpAppendString(&argv, "--keyword", try mcpString(args, "keyword"))
            mcpAppendString(&argv, "--reading-status", try mcpString(args, "readingStatus"))
            mcpAppendString(&argv, "--sort-by", try mcpString(args, "sortBy"))
            mcpAppendFlag(&argv, "--asc", try mcpBool(args, "asc"))
            return argv
        }
    )

    private static let getTool = MCPTool(
        name: "rubien_get",
        description: "Fetch a single reference by ID. Returns ReferenceDTO.",
        inputSchema: [
            "type": "object",
            "properties": ["id": ["type": "integer", "description": "Reference ID"]],
            "required": ["id"],
        ],
        isImage: false,
        buildArgv: { args in
            guard let id = try mcpInt(args, "id") else {
                throw MCPToolError.invalidArguments("Missing required argument: id")
            }
            return ["get", String(id)]
        }
    )

    // MARK: pdf

    private static let pdfInfoTool = MCPTool(
        name: "rubien_pdf_info",
        description: "Return page count, hasTextLayer (sampled across first/middle/last page), file size, isEncrypted, documentTitle, and the flattened outline `sections` (or null when the PDF has no outline). Each section carries title, level (1=top), startPage, and endPage; parent ranges span their descendants. Call this before `rubien_read_text` when you plan to select by `sections` or page ranges.",
        inputSchema: [
            "type": "object",
            "properties": ["id": ["type": "integer", "description": "Reference ID"]],
            "required": ["id"],
        ],
        isImage: false,
        buildArgv: { args in
            guard let id = try mcpInt(args, "id") else {
                throw MCPToolError.invalidArguments("Missing required argument: id")
            }
            return ["pdf", "info", String(id)]
        }
    )

    private static let pdfPageImageTool = MCPTool(
        name: "rubien_pdf_page_image",
        description: "Render a single PDF page (1-indexed) and return it as an MCP image content block. Use this when text extraction is empty/garbled (scanned page, dense math) or when a figure/table is referenced in the surrounding text. Defaults: JPEG at scale=2.0 (~192 DPI) with quality stepdown to honor maxBytes. PNG mode is opt-in for lossless output but hard-fails on maxBytes.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "integer", "description": "Reference ID"],
                "page": ["type": "integer", "exclusiveMinimum": 0, "description": "Page number (1-indexed)"],
                "scale": ["type": "number", "exclusiveMinimum": 0, "maximum": 8, "description": "Render scale (default 2.0; 1.0 ≈ 96 DPI)"],
                "maxBytes": ["type": "integer", "exclusiveMinimum": 0, "description": "Hard cap on rendered image bytes (default 2000000)"],
                "format": ["type": "string", "enum": ["jpeg", "png"], "description": "Output format (default jpeg)"],
            ],
            "required": ["id", "page"],
        ],
        isImage: true,
        buildArgv: { args in
            guard let id = try mcpInt(args, "id") else {
                throw MCPToolError.invalidArguments("Missing required argument: id")
            }
            guard let page = try mcpInt(args, "page") else {
                throw MCPToolError.invalidArguments("Missing required argument: page")
            }
            var argv = ["pdf", "page-image", String(id), "--page", String(page)]
            if let scale = try mcpDouble(args, "scale") { argv += ["--scale", mcpFormatDouble(scale)] }
            mcpAppendInt(&argv, "--max-bytes", try mcpInt(args, "maxBytes"))
            mcpAppendString(&argv, "--format", try mcpString(args, "format"))
            return argv
        }
    )

    // MARK: read (kind-agnostic)

    private static let readTextTool = MCPTool(
        name: "rubien_read_text",
        description: "Return the readable body text of any reference — its attached PDF or its clipped web page — without needing to know which it has. Source selection when `source` is omitted: `pages`/`sections` imply pdf, `start` implies web, otherwise PDF wins when both exist. Every response carries `source` (what was read) and `available` (which sources are readable now, e.g. [\"pdf\",\"web\"]). PDF responses are page-keyed: each `pages[]` item carries `text` and `sectionPath`, selected via `pages` ('1-3' or '1-3,8-10') or `sections` (title substrings, case-insensitive; errors `no-outline` when the PDF has no outline — fall back to `pages`). Web responses are one flat windowed body: `content` + `contentLength`, paginated via `start`/`maxChars`; `contentFormat` is \"markdown\" or \"html\" (treat html as a fragment). Library-only — never fetches from the network. Use `rubien_read_annotations` for the user's highlights/notes, and `rubien_pdf_info` first when you plan to select by `sections`.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "integer", "description": "Reference ID"],
                "source": ["type": "string", "enum": ["pdf", "web"], "description": "Force a source. Default: pages/sections imply pdf, start implies web, else PDF wins."],
                "pages": ["type": "string", "description": "PDF page range, e.g. '1-3' or '1-3,8-10' or '12-'. Implies pdf. Mutually exclusive with `sections`."],
                "sections": [
                    "type": "array",
                    "items": ["type": "string", "minLength": 1],
                    "description": "PDF section title substrings (case-insensitive). Implies pdf. Mutually exclusive with `pages`.",
                ],
                "start": ["type": "integer", "minimum": 0, "description": "Character offset into the web body (default 0). Implies web."],
                "maxChars": ["type": "integer", "exclusiveMinimum": 0, "maximum": 500000, "description": "Cap returned characters (default 50000). PDF truncates at page boundary (always ≥ 1 page); web at the character boundary."],
            ],
            "required": ["id"],
        ],
        isImage: false,
        buildArgv: { args in
            guard let id = try mcpInt(args, "id") else {
                throw MCPToolError.invalidArguments("Missing required argument: id")
            }
            // Match the Node catalog (read.ts): an empty `pages` string is
            // treated as absent (Node's `Boolean(args.pages)` is false for ""),
            // so it neither implies a PDF source nor emits `--pages ""`. Without
            // this coalesce the two servers route `pages:""` differently.
            let pages = (try mcpString(args, "pages")).flatMap { $0.isEmpty ? nil : $0 }
            let sections = try mcpStringArray(args, "sections")
            let start = try mcpInt(args, "start")
            if pages != nil, let sections, !sections.isEmpty {
                throw MCPToolError.invalidArguments("`pages` and `sections` are mutually exclusive")
            }
            let pdfParams = pages != nil || !(sections ?? []).isEmpty
            if pdfParams, start != nil {
                throw MCPToolError.invalidArguments("`pages`/`sections` and `start` are mutually exclusive")
            }
            var argv = ["read", "text", String(id)]
            mcpAppendString(&argv, "--pages", pages)
            if let sections {
                for section in sections { argv += ["--section", section] }
            }
            mcpAppendInt(&argv, "--start", start)
            mcpAppendInt(&argv, "--max-chars", try mcpInt(args, "maxChars"))
            mcpAppendString(&argv, "--source", try mcpString(args, "source"))
            return argv
        }
    )

    private static let readAnnotationsTool = MCPTool(
        name: "rubien_read_annotations",
        description: "Return the user's annotations (highlights, underlines, anchored notes) on a reference — PDF and web-clip annotations in one array, each item tagged `source`: \"pdf\" | \"web\" (optional `source` param filters to one kind). PDF items carry `pageIndex` + `selectedText`; web items carry a W3C TextQuoteSelector (`prefixText`/`anchorText`/`suffixText`) — use it to locate the highlight inside the body returned by `rubien_read_text`. All items carry `type`, `color`, `noteText`, `dateCreated`, `dateModified`. Ordered: PDF items first (by pageIndex), then web items (by dateCreated). Empty array when the reference doesn't exist or has no annotations (not an error).",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "integer", "description": "Reference ID"],
                "source": ["type": "string", "enum": ["pdf", "web"], "description": "Filter to one kind."],
            ],
            "required": ["id"],
        ],
        isImage: false,
        buildArgv: { args in
            guard let id = try mcpInt(args, "id") else {
                throw MCPToolError.invalidArguments("Missing required argument: id")
            }
            var argv = ["read", "annotations", String(id)]
            mcpAppendString(&argv, "--source", try mcpString(args, "source"))
            return argv
        }
    )
}

// MARK: - Argument extraction helpers
//
// `tools/call` arguments arrive parsed by JSONSerialization, so JSON numbers
// are NSNumber and JSON booleans are NSNumber-backed CFBoolean. Each argument's
// expected type is known per-tool. These accessors return nil when the key is
// *absent* (an omitted optional) but THROW `invalidArguments` when the key is
// present with the wrong type — mirroring the Node server's Zod validation, so
// e.g. `{"id":true}` or `{"limit":"10"}` are rejected as tool errors rather
// than silently coerced (a bool bridges to NSNumber → would become an int) or
// silently dropped.

/// Distinguish a JSON boolean from a JSON number. `value is Bool` is NOT usable
/// here: JSONSerialization decodes both `true` and `1` to `NSNumber`, and on
/// Apple platforms `NSNumber(1) is Bool` returns `true` (the lenient bridge).
/// The only reliable test is the CFBoolean type id — JSON `true`/`false` are
/// backed by CFBoolean, numbers by CFNumber.
private func mcpIsJSONBool(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

private func mcpInt(_ args: [String: Any], _ key: String) throws -> Int? {
    guard let value = args[key], !(value is NSNull) else { return nil }
    guard !mcpIsJSONBool(value), let number = value as? NSNumber else {
        throw MCPToolError.invalidArguments("`\(key)` must be an integer")
    }
    // Reject non-integral numbers (Zod `.int()`): a JSON `1.5` would truncate.
    guard number.doubleValue.rounded() == number.doubleValue else {
        throw MCPToolError.invalidArguments("`\(key)` must be an integer")
    }
    return number.intValue
}

private func mcpDouble(_ args: [String: Any], _ key: String) throws -> Double? {
    guard let value = args[key], !(value is NSNull) else { return nil }
    guard !mcpIsJSONBool(value), let number = value as? NSNumber else {
        throw MCPToolError.invalidArguments("`\(key)` must be a number")
    }
    return number.doubleValue
}

private func mcpString(_ args: [String: Any], _ key: String) throws -> String? {
    guard let value = args[key], !(value is NSNull) else { return nil }
    guard let string = value as? String else {
        throw MCPToolError.invalidArguments("`\(key)` must be a string")
    }
    return string
}

private func mcpBool(_ args: [String: Any], _ key: String) throws -> Bool? {
    guard let value = args[key], !(value is NSNull) else { return nil }
    guard mcpIsJSONBool(value), let flag = value as? Bool else {
        throw MCPToolError.invalidArguments("`\(key)` must be a boolean")
    }
    return flag
}

private func mcpStringArray(_ args: [String: Any], _ key: String) throws -> [String]? {
    guard let value = args[key], !(value is NSNull) else { return nil }
    guard let array = value as? [String] else {
        throw MCPToolError.invalidArguments("`\(key)` must be an array of strings")
    }
    return array
}

private func mcpAppendInt(_ argv: inout [String], _ flag: String, _ value: Int?) {
    if let value { argv += [flag, String(value)] }
}

private func mcpAppendString(_ argv: inout [String], _ flag: String, _ value: String?) {
    if let value { argv += [flag, value] }
}

private func mcpAppendFlag(_ argv: inout [String], _ flag: String, _ value: Bool?) {
    if value == true { argv.append(flag) }
}

/// Render a Double for the CLI without a trailing `.0`-less integer surprise:
/// `2.0` → "2.0", `1.5` → "1.5". ArgumentParser parses either form, but a
/// clean, locale-independent rendering avoids surprises.
private func mcpFormatDouble(_ value: Double) -> String {
    if value == value.rounded() && abs(value) < 1e15 {
        return String(format: "%.1f", value)
    }
    return String(value)
}
