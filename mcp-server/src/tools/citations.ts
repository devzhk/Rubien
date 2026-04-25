import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { runCliAsTool } from "../toolHelpers.js";

const BUILTIN_STYLES = [
  "apa",
  "mla",
  "chicago",
  "ieee",
  "harvard",
  "vancouver",
  "nature",
] as const;

const CITE_FORMATS = ["text", "bibliography", "docx-cc"] as const;

export function registerCitationTools(server: McpServer): void {
  server.registerTool(
    "rubien_cite",
    {
      title: "Format citations",
      description:
        "Generate formatted citations for one or more references. Output shape varies by format: `text` → { style, inline, bibliography }, `bibliography` → { style, entries }, `docx-cc` → { tag, text, style, isShortTag?, fallbackPayload? }. Use arbitrary CSL style IDs from `rubien_styles_list` if needed.",
      inputSchema: {
        ids: z.array(z.number().int()).min(1).describe("Reference IDs to cite"),
        style: z
          .string()
          .optional()
          .describe(
            `Citation style (default apa). Built-ins: ${BUILTIN_STYLES.join(", ")}. Any CSL ID from rubien_styles_list also works.`,
          ),
        format: z
          .enum(CITE_FORMATS)
          .optional()
          .describe(
            "Output format (default text). 'bibliography' for reference-list entries only; 'docx-cc' for Word content-control tags.",
          ),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ ids, style, format }) => {
      const args: string[] = ["cite", ...ids.map((n) => String(n))];
      if (style) args.push("--style", style);
      if (format) args.push("--format", format);
      return runCliAsTool(args);
    },
  );

  server.registerTool(
    "rubien_styles_list",
    {
      title: "List citation styles",
      description:
        "List all available citation styles (built-in + installed CSL). Use the returned `id` as the `style` argument to rubien_cite.",
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () => runCliAsTool(["styles"]),
  );
}
