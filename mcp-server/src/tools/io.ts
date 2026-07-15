import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { runCliAsTool } from "../toolHelpers.js";

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
      },
      annotations: { readOnlyHint: true },
    },
    async ({ format }) => {
      const args = ["export"];
      if (format) args.push("--format", format);
      const textMode = format === "bibtex" || format === "ris";
      return runCliAsTool(args, { textMode });
    },
  );
}
