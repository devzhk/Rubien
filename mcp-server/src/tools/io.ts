import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { flagsFromOptions, runCliAsTool } from "../toolHelpers.js";

export function registerIOTools(server: McpServer): void {
  server.registerTool(
    "rubien_import",
    {
      title: "Import from BibTeX/RIS/markdown or a folder",
      description:
        "Import references from a file (BibTeX .bib / RIS .ris / markdown .md — Obsidian Web Clipper frontmatter is mapped, plain notes import too) or a folder (Zotero export, or a folder of .md files). Folder imports stamp a single-/multi-select property value on every imported reference via property + value (default: Tags = folder basename). A folder containing both .bib and .md needs format to disambiguate.",
      inputSchema: {
        file: z
          .string()
          .describe(
            "Absolute path on the host. Stdin piping ('-') is not supported through the MCP wrapper; if you need it, invoke rubien-cli directly.",
          ),
        format: z
          .enum(["bib", "ris", "md"])
          .optional()
          .describe(
            "Override the format inferred from the file extension; also disambiguates folders containing both .bib and .md.",
          ),
        property: z
          .string()
          .optional()
          .describe("(Folder imports) Property name to stamp on imported refs"),
        value: z
          .string()
          .optional()
          .describe("(Folder imports) Value for --property on imported refs"),
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
