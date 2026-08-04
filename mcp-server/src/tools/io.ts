import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { errorResult, runCliAsTool } from "../toolHelpers.js";

// `rubien_import` was folded into `rubien_create_reference` (references.ts) in
// the 0.3.0 catalog — one door for every input; the CLI routes the locator.

export function registerIOTools(server: McpServer): void {
  server.registerTool(
    "rubien_export",
    {
      title: "Export references",
      description:
        "Export the library (or a subset) as JSON, BibTeX, or RIS. BibTeX/RIS output is plain text; JSON is a ReferenceDTO[] array.",
      inputSchema: {
        format: z.enum(["json", "bibtex", "ris"]).optional()
          .describe("Default is json"),
        ids: z.array(z.number().int()).min(1).optional()
          .describe("Reference IDs in output order"),
        view: z.number().int().optional().describe("Saved view ID"),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ format, ids, view }) => {
      if (ids && view !== undefined) {
        return errorResult("provide at most one of ids / view");
      }
      const args = ["export", ...(ids ?? []).map(String)];
      if (view !== undefined) args.push("--view", String(view));
      if (format) args.push("--format", format);
      const textMode = format === "bibtex" || format === "ris";
      return runCliAsTool(args, { textMode });
    },
  );
}
