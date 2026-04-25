import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { flagsFromOptions, runCliAsTool } from "../toolHelpers.js";

export function registerIOTools(server: McpServer): void {
  server.registerTool(
    "rubien_import",
    {
      title: "Import from BibTeX/RIS/Zotero folder",
      description:
        "Import references from a file (BibTeX .bib / RIS .ris) or a Zotero-exported folder. For folder imports you can stamp a single-/multi-select property value on every imported reference via property + value.",
      inputSchema: {
        file: z
          .string()
          .describe(
            "Absolute path on the host. Stdin piping ('-') is not supported through the MCP wrapper; if you need it, invoke rubien-cli directly.",
          ),
        format: z
          .enum(["bib", "ris"])
          .optional()
          .describe("Override the format inferred from the file extension."),
        property: z
          .string()
          .optional()
          .describe("(Zotero folder only) Property name to stamp on imported refs"),
        value: z
          .string()
          .optional()
          .describe("(Zotero folder only) Value for --property on imported refs"),
      },
      annotations: { destructiveHint: true },
    },
    async ({ file, format, property, value }) =>
      runCliAsTool(
        [
          "import",
          file,
          ...flagsFromOptions({
            "--format": format,
            "--property": property,
            "--value": value,
          }),
        ],
        { timeoutMs: 180_000 }, // folder imports with PDF copies can be slow
      ),
  );

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
