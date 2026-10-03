import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { flagsFromOptions, runCliAsTool } from "../toolHelpers.js";

const id = z.string().min(1).describe("Attachment UUID");
const path = z.string().min(1);

export function registerAttachmentTools(server: McpServer): void {
  server.registerTool("rubien_attachment_list", {
    description: "List a reference's supplementary attachments with local existence and size checks. Use attachment status to verify contents. Reports the active sync session’s transfer state.",
    inputSchema: { referenceId: z.number().int() },
    annotations: { readOnlyHint: true },
  }, async (args) => runCliAsTool(["attachment", "list", String(args.referenceId)]));

  server.registerTool("rubien_attachment_add", {
    description: "Attach local PDF or UTF-8 Markdown files to a reference. Returns one added, duplicate, or error result per input. Limits: PDF 250 MiB; Markdown 50 MiB.",
    inputSchema: { referenceId: z.number().int(), files: z.array(path).min(1) },
    annotations: { readOnlyHint: false, destructiveHint: false },
  }, async (args) => runCliAsTool(["attachment", "add", String(args.referenceId), "--", ...args.files]));

  server.registerTool("rubien_attachment_status", {
    description: "Verify an attachment's local bytes and report availability, removal, pending upload intent, and errors. Pending intent does not mean uploaded.",
    inputSchema: { id }, annotations: { readOnlyHint: true },
  }, async (args) => runCliAsTool(["attachment", "status", args.id]));

  server.registerTool("rubien_attachment_retry", {
    description: "Retry pending attachment downloads and recovery lookups. Does not recreate missing previously synced annotations. Requires an enabled sync session.",
    inputSchema: { id }, annotations: { readOnlyHint: false, destructiveHint: false },
  }, async (args) => runCliAsTool(["attachment", "retry", args.id]));

  server.registerTool("rubien_attachment_read", {
    description: "Read this attachment by UUID, never its parent paper. PDF uses pages (1-based ranges) and truncates at page boundaries, always returning at least one page. Markdown uses start (character offset) and maxChars. Default maxChars 50000; maximum 500000. No network downloads.",
    inputSchema: { id, pages: path.optional(), start: z.number().int().nonnegative().optional(),
      maxChars: z.number().int().positive().max(500_000).optional() },
    annotations: { readOnlyHint: true },
  }, async (args) => runCliAsTool(["attachment", "read", args.id, ...flagsFromOptions({
    "--pages": args.pages, "--start": args.start, "--max-chars": args.maxChars,
  })]));

  server.registerTool("rubien_attachment_export", {
    description: "Write an attachment's original bytes to a new local output path. Existing files and library-owned paths are never overwritten.",
    inputSchema: { id, output: path }, annotations: { readOnlyHint: false, destructiveHint: false },
  }, async (args) => runCliAsTool(["attachment", "export", args.id, "--output", args.output]));

  server.registerTool("rubien_attachment_rename", {
    description: "Change an attachment's display name. Original bytes and filename are retained.",
    inputSchema: { id, name: z.string().min(1).max(255) },
    annotations: { readOnlyHint: false, destructiveHint: false },
  }, async (args) => runCliAsTool(["attachment", "rename", args.id, "--name", args.name]));

  server.registerTool("rubien_attachment_remove", {
    description: "Remove an attachment and close its reader. Retains removal markers; managed bytes are cleaned after iCloud acknowledges removal. Does not remove the parent paper.",
    inputSchema: { id }, annotations: { readOnlyHint: false, destructiveHint: true },
  }, async (args) => runCliAsTool(["attachment", "remove", args.id]));
}
