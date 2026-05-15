import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { flagsFromOptions, runCliAsTool } from "../toolHelpers.js";

export function registerWebTools(server: McpServer): void {
  server.registerTool(
    "rubien_web_get",
    {
      title: "Read the extracted body of a clipped web reference",
      description:
        "Return the extracted readable text of a clipped web page reference that is already in the library. This is library-only — it does NOT fetch from the network; it returns the same text the in-app WebReader shows. Use `start` (character offset) and `maxChars` (default 50000) to paginate long pages — `contentLength` tells you the total decoded body length. The `contentFormat` field is `\"markdown\"` (most pages, post-extraction) or `\"html\"` (a small number of pages where the clipper preserved markup). For HTML, treat `content` as a fragment, not a full document. To see the user's highlights/notes on the page, call `rubien_web_annotations` for the same reference. Errors when the reference doesn't exist or has no web content (e.g. PDF-only references).",
      inputSchema: {
        referenceId: z.number().int().describe("Reference ID"),
        maxChars: z
          .number()
          .int()
          .positive()
          .optional()
          .describe(
            "Cap returned characters (default 50000). Truncation is at the character boundary.",
          ),
        start: z
          .number()
          .int()
          .nonnegative()
          .optional()
          .describe(
            "Character offset into the decoded body (default 0). Past end-of-content returns content=\"\" with truncated=false.",
          ),
      },
      annotations: { readOnlyHint: true },
    },
    async (args) => {
      const cliArgs: string[] = ["web", "get", String(args.referenceId)];
      cliArgs.push(
        ...flagsFromOptions({
          "--max-chars": args.maxChars,
          "--start": args.start,
        }),
      );
      return runCliAsTool(cliArgs);
    },
  );

  server.registerTool(
    "rubien_web_annotations",
    {
      title: "List web-page annotations for a reference",
      description:
        "Return the highlights, underlines, and anchored notes the user has made on a clipped web reference. This is the web-page counterpart to `rubien_annotations_list` (which covers PDF annotations only). Each annotation carries `anchorText` (the highlighted string — also what the sidebar displays), `noteText` (the user's attached note, if any), and `prefixText` / `suffixText` (the surrounding text that disambiguates the location). Together `prefixText` / `anchorText` / `suffixText` form a W3C TextQuoteSelector — use them to locate each highlight inside the body returned by `rubien_web_get`. Empty array when the reference has no web annotations or the reference ID doesn't exist (not an error).",
      inputSchema: {
        referenceId: z.number().int().describe("Reference ID"),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ referenceId }) =>
      runCliAsTool(["web", "annotations", String(referenceId)]),
  );
}
