import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { runCliAsTool } from "../toolHelpers.js";

export function registerAnnotationTools(server: McpServer): void {
  server.registerTool(
    "rubien_annotations_list",
    {
      title: "List PDF annotations for a reference",
      description:
        "Return all PDF annotations (highlights, underlines, anchored notes) on a single reference's attached PDF. PDF references only — for clipped web pages, use `rubien_web_annotations` instead. Returns [{ id, type, color, pageIndex, selectedText, noteText }].",
      inputSchema: {
        referenceId: z.number().int(),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ referenceId }) =>
      runCliAsTool(["annotations", String(referenceId)]),
  );
}
