import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { CliError, invokeCliTyped } from "../cli.js";
import { flagsFromOptions, runCliAsTool } from "../toolHelpers.js";

interface PdfPageImageResult {
  id: number;
  page: number;
  mimeType: string;
  data: string;
  widthPx: number;
  heightPx: number;
  qualityUsed: number | null;
}

export function registerPdfTools(server: McpServer): void {
  server.registerTool(
    "rubien_pdf_info",
    {
      title: "Probe PDF metadata + outline",
      description:
        "Return page count, hasTextLayer (sampled across first/middle/last page), file size, isEncrypted, documentTitle, and the flattened outline `sections` (or null when the PDF has no outline). Each section carries title, level (1=top), startPage, and endPage; parent ranges span their descendants. Call this before `rubien_pdf_text` so you know whether to use sections or page ranges.",
      inputSchema: {
        id: z.number().int().describe("Reference ID"),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ id }) => runCliAsTool(["pdf", "info", String(id)]),
  );

  server.registerTool(
    "rubien_pdf_text",
    {
      title: "Extract text from a PDF",
      description:
        "Extract page-keyed text from a reference's attached PDF. Two mutually-exclusive selection modes: `pages` (e.g. '1-3' or '1-3,8-10') or `sections` (array of section title substrings; case-insensitive). When neither is provided the whole document is returned (subject to maxChars). Each returned page carries `text` and `sectionPath` (breadcrumb of containing sections). Errors with `no-outline` when `sections` is requested but the PDF has no outline — fall back to `pages` in that case.",
      inputSchema: {
        id: z.number().int().describe("Reference ID"),
        pages: z
          .string()
          .optional()
          .describe(
            "Page range string, e.g. '1-3' or '1-3,8-10' or '12-'. Mutually exclusive with `sections`.",
          ),
        sections: z
          .array(z.string().min(1))
          .optional()
          .describe(
            "Section title substrings (case-insensitive, repeatable). Mutually exclusive with `pages`. Use after `rubien_pdf_info` confirms `sections != null`.",
          ),
        maxChars: z
          .number()
          .int()
          .positive()
          .max(500_000)
          .optional()
          .describe(
            "Cap total returned characters (default 50000). Truncation is at page boundary.",
          ),
      },
      annotations: { readOnlyHint: true },
    },
    async (args) => {
      if (args.pages && args.sections && args.sections.length > 0) {
        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                error: "pages-and-sections-mutually-exclusive",
              }),
            },
          ],
          isError: true,
        };
      }
      const cliArgs: string[] = ["pdf", "text", String(args.id)];
      if (args.pages) cliArgs.push("--pages", args.pages);
      if (args.sections) {
        for (const s of args.sections) cliArgs.push("--section", s);
      }
      cliArgs.push(
        ...flagsFromOptions({
          "--max-chars": args.maxChars,
        }),
      );
      return runCliAsTool(cliArgs);
    },
  );

  server.registerTool(
    "rubien_pdf_page_image",
    {
      title: "Render a PDF page as an image",
      description:
        "Render a single PDF page (1-indexed) and return it as an MCP image content block. Use this when text extraction is empty/garbled (scanned page, dense math) or when a figure/table is referenced in the surrounding text. Defaults: JPEG at scale=2.0 (~192 DPI) with quality stepdown to honor maxBytes. PNG mode is opt-in for lossless output but hard-fails on maxBytes.",
      inputSchema: {
        id: z.number().int().describe("Reference ID"),
        page: z.number().int().positive().describe("Page number (1-indexed)"),
        scale: z
          .number()
          .positive()
          .max(8)
          .optional()
          .describe("Render scale (default 2.0; 1.0 ≈ 96 DPI)"),
        maxBytes: z
          .number()
          .int()
          .positive()
          .optional()
          .describe("Hard cap on rendered image bytes (default 2000000)"),
        format: z
          .enum(["jpeg", "png"])
          .optional()
          .describe("Output format (default jpeg)"),
      },
      annotations: { readOnlyHint: true },
    },
    async (args) => {
      const cliArgs: string[] = [
        "pdf",
        "page-image",
        String(args.id),
        "--page",
        String(args.page),
        ...flagsFromOptions({
          "--scale": args.scale,
          "--max-bytes": args.maxBytes,
          "--format": args.format,
        }),
      ];
      try {
        const result = await invokeCliTyped<PdfPageImageResult>(cliArgs);
        const meta = JSON.stringify(
          {
            id: result.id,
            page: result.page,
            widthPx: result.widthPx,
            heightPx: result.heightPx,
            qualityUsed: result.qualityUsed,
            mimeType: result.mimeType,
          },
          null,
          2,
        );
        return {
          content: [
            { type: "text" as const, text: meta },
            {
              type: "image" as const,
              data: result.data,
              mimeType: result.mimeType,
            },
          ],
        };
      } catch (err: unknown) {
        if (err instanceof CliError) {
          return {
            content: [{ type: "text" as const, text: err.message }],
            isError: true,
          };
        }
        throw err;
      }
    },
  );
}
