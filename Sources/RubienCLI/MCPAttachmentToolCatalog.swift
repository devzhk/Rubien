import Foundation
import RubienCore

enum MCPAttachmentToolCatalog {
    private static let id: [String: Any] = ["type": "string", "minLength": 1, "description": "Attachment UUID"]
    private static let path: [String: Any] = ["type": "string", "minLength": 1]

    static let tools: [MCPTool] = [
        MCPTool(name: "rubien_attachment_list", description: "List a reference's supplementary attachments with local existence and size checks. Use attachment status to verify contents. Reports the active sync session’s transfer state.",
            inputSchema: ["type": "object", "properties": ["referenceId": ["type": "integer"]], "required": ["referenceId"]],
            isImage: false, buildArgv: { args in
                ["attachment", "list", String(try mcpInt(args, "referenceId")!)]
            }),
        MCPTool(name: "rubien_attachment_add", description: "Attach local PDF or UTF-8 Markdown files to a reference. Returns one added, duplicate, or error result per input. Limits: PDF 250 MiB; Markdown 50 MiB.",
            inputSchema: ["type": "object", "properties": ["referenceId": ["type": "integer"], "files": ["type": "array", "items": path, "minItems": 1]], "required": ["referenceId", "files"]],
            access: .write, isImage: false, buildArgv: { args in
                ["attachment", "add", String(try mcpInt(args, "referenceId")!), "--"] + (try mcpStringArray(args, "files")!)
            }),
        MCPTool(name: "rubien_attachment_status", description: "Verify an attachment's local bytes and report availability, removal, pending upload intent, and errors. Pending intent does not mean uploaded.",
            inputSchema: ["type": "object", "properties": ["id": id], "required": ["id"]],
            isImage: false, buildArgv: { ["attachment", "status", try requiredID($0)] }),
        MCPTool(name: "rubien_attachment_retry", description: "Retry pending attachment downloads and recovery lookups. Does not recreate missing previously synced annotations. Requires an enabled sync session.",
            inputSchema: ["type": "object", "properties": ["id": id], "required": ["id"]],
            access: .write, isImage: false, buildArgv: { ["attachment", "retry", try requiredID($0)] }),
        MCPTool(name: "rubien_attachment_read", description: "Read this attachment by UUID, never its parent paper. PDF uses pages (1-based ranges) and truncates at page boundaries, always returning at least one page. Markdown uses start (character offset) and maxChars. Default maxChars 50000; maximum 500000. No network downloads.",
            inputSchema: ["type": "object", "properties": ["id": id, "pages": path,
                "start": ["type": "integer", "minimum": 0],
                "maxChars": ["type": "integer", "exclusiveMinimum": 0, "maximum": 500000]], "required": ["id"]],
            isImage: false, buildArgv: { args in
                var argv = ["attachment", "read", try requiredID(args)]
                mcpAppendString(&argv, "--pages", try mcpString(args, "pages"))
                mcpAppendInt(&argv, "--start", try mcpInt(args, "start"))
                mcpAppendInt(&argv, "--max-chars", try mcpInt(args, "maxChars"))
                return argv
            }),
        MCPTool(name: "rubien_attachment_export", description: "Write an attachment's original bytes to a new local output path. Existing files and library-owned paths are never overwritten.",
            inputSchema: ["type": "object", "properties": ["id": id, "output": path], "required": ["id", "output"]],
            access: .write, isImage: false, buildArgv: { args in
                ["attachment", "export", try requiredID(args), "--output", try mcpString(args, "output")!]
            }),
        MCPTool(name: "rubien_attachment_rename", description: "Change an attachment's display name. Original bytes and filename are retained.",
            inputSchema: ["type": "object", "properties": ["id": id, "name": ["type": "string", "minLength": 1, "maxLength": 255]], "required": ["id", "name"]],
            access: .write, isImage: false, buildArgv: { args in
                ["attachment", "rename", try requiredID(args), "--name", try mcpString(args, "name")!]
            }),
        MCPTool(name: "rubien_attachment_remove", description: "Remove an attachment and close its reader. Retains removal markers; managed bytes are cleaned after iCloud acknowledges removal. Does not remove the parent paper.",
            inputSchema: ["type": "object", "properties": ["id": id], "required": ["id"]],
            access: .write, destructive: true, isImage: false,
            buildArgv: { ["attachment", "remove", try requiredID($0)] }),
    ]

    private static func requiredID(_ args: [String: Any]) throws -> String {
        guard let value = try mcpString(args, "id") else {
            throw MCPToolError.invalidArguments("Expected an attachment UUID")
        }
        return value
    }
}
