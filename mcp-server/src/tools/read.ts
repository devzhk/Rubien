import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { flagsFromOptions, runCliAsTool } from "../toolHelpers.js";

export function registerReadTools(server: McpServer): void {
  server.registerTool(
    "rubien_read_text",
    {
      title: "Read the body text of any reference",
      description:
        "Return the readable body text of any reference — its attached PDF or its clipped web page — without needing to know which it has. Source selection when `source` is omitted: `pages`/`sections` imply pdf, `start` implies web, otherwise PDF wins when both exist. Every response carries `source` (what was read) and `available` (which sources are readable now, e.g. [\"pdf\",\"web\"]). PDF responses are page-keyed: each `pages[]` item carries `text` and `sectionPath`, selected via `pages` ('1-3' or '1-3,8-10') or `sections` (title substrings, case-insensitive; errors `no-outline` when the PDF has no outline — fall back to `pages`). Web responses are one flat windowed body: `content` + `contentLength`, paginated via `start`/`maxChars`; `contentFormat` is \"markdown\" or \"html\" (treat html as a fragment). To find WHERE the body mentions something before reading, use `rubien_grep_text`. Library-only — never fetches from the network. Use `rubien_read_annotations` for the user's highlights/notes, and `rubien_pdf_info` first when you plan to select by `sections`.",
      inputSchema: {
        id: z.number().int().describe("Reference ID"),
        source: z.enum(["pdf", "web"]).optional()
          .describe("Force a source. Default: pages/sections imply pdf, start implies web, else PDF wins."),
        pages: z.string().optional()
          .describe("PDF page range, e.g. '1-3' or '1-3,8-10' or '12-'. Implies pdf. Mutually exclusive with `sections`."),
        sections: z.array(z.string().min(1)).optional()
          .describe("PDF section title substrings (case-insensitive). Implies pdf. Mutually exclusive with `pages`."),
        start: z.number().int().nonnegative().optional()
          .describe("Character offset into the web body (default 0). Implies web."),
        maxChars: z.number().int().positive().max(500_000).optional()
          .describe("Cap returned characters (default 50000). PDF truncates at page boundary (always ≥ 1 page); web at the character boundary."),
      },
      annotations: { readOnlyHint: true },
    },
    async (args) => {
      if (args.pages && args.sections && args.sections.length > 0) {
        return {
          content: [{ type: "text" as const, text: JSON.stringify({ error: "pages-and-sections-mutually-exclusive" }) }],
          isError: true,
        };
      }
      const pdfParams = Boolean(args.pages) || Boolean(args.sections && args.sections.length > 0);
      if (pdfParams && args.start !== undefined) {
        return {
          content: [{ type: "text" as const, text: JSON.stringify({ error: "pages/sections-and-start-mutually-exclusive" }) }],
          isError: true,
        };
      }
      const cliArgs: string[] = ["read", "text", String(args.id)];
      if (args.pages) cliArgs.push("--pages", args.pages);
      if (args.sections) for (const s of args.sections) cliArgs.push("--section", s);
      cliArgs.push(
        ...flagsFromOptions({
          "--start": args.start,
          "--max-chars": args.maxChars,
          "--source": args.source,
        }),
      );
      return runCliAsTool(cliArgs);
    },
  );

  server.registerTool(
    "rubien_read_annotations",
    {
      title: "List a reference's annotations (PDF + web merged)",
      description:
        "Return the user's annotations (highlights, underlines, anchored notes) on a reference — PDF and web-clip annotations in one array, each item tagged `source`: \"pdf\" | \"web\" (optional `source` param filters to one kind). PDF items carry `pageIndex` + `selectedText`; web items carry a W3C TextQuoteSelector (`prefixText`/`anchorText`/`suffixText`) — use it to locate the highlight inside the body returned by `rubien_read_text`. All items carry `type`, `color`, `noteText`, `dateCreated`, `dateModified`. Ordered: PDF items first (by pageIndex), then web items (by dateCreated). Empty array when the reference doesn't exist or has no annotations (not an error).",
      inputSchema: {
        id: z.number().int().describe("Reference ID"),
        source: z.enum(["pdf", "web"]).optional().describe("Filter to one kind."),
      },
      annotations: { readOnlyHint: true },
    },
    async (args) => {
      const cliArgs: string[] = ["read", "annotations", String(args.id)];
      cliArgs.push(...flagsFromOptions({ "--source": args.source }));
      return runCliAsTool(cliArgs);
    },
  );

  server.registerTool(
    "rubien_grep_text",
    {
      title: "Find where a reference's body says something",
      description:
        "Find WHERE a phrase or regex occurs inside one reference's body text — its attached PDF or its clipped web page — without retrieving the body. Returns anchored locations, not text: PDF hits are page-grouped (`pages[]` with `page`, `sectionPath` breadcrumbs, `matchCount`, snippets) — drill in with `rubien_read_text` + `pages`; web hits carry exact character offsets (`matches[].start`, same coordinates as `rubien_read_text`'s `start`) — drill in with `rubien_read_text` + `start`. Matching is case-insensitive (`regex: true` treats the query as a regular expression; `(?-i:…)` restores case). Source selection mirrors `rubien_read_text`: explicit `source` wins; `pages`/`maxPages`/`snippetsPerPage` imply pdf and `maxMatches` implies web; otherwise PDF wins when both exist. Every response carries `source` and `available`. A scanned PDF returns success with `hasTextLayer: false` and no hits — fall back to `rubien_pdf_page_image`. To find which REFERENCES match, use `rubien_search` (library metadata) instead. Library-only — never fetches from the network.",
      inputSchema: {
        id: z.number().int().describe("Reference ID"),
        query: z.string().min(1).describe("Literal phrase (default) or regex (`regex: true`). Case-insensitive."),
        regex: z.boolean().optional().describe("Treat `query` as a regular expression."),
        source: z.enum(["pdf", "web"]).optional()
          .describe("Force a source. Default: pdf-scoped params imply pdf, maxMatches implies web, else PDF wins."),
        contextChars: z.number().int().positive().max(2_000).optional()
          .describe("Snippet window width (default 160)."),
        pages: z.string().optional()
          .describe("PDF page range scope, e.g. '1-3,8-10'. Implies pdf."),
        maxPages: z.number().int().positive().max(200).optional()
          .describe("Cap returned PDF page-hits (default 30). Implies pdf."),
        snippetsPerPage: z.number().int().positive().max(20).optional()
          .describe("Cap snippets per PDF page (default 3). Implies pdf."),
        maxMatches: z.number().int().positive().max(200).optional()
          .describe("Cap returned web match entries (default 20). Implies web."),
      },
      annotations: { readOnlyHint: true },
    },
    async (args) => {
      const pdfParams =
        Boolean(args.pages) || args.maxPages !== undefined || args.snippetsPerPage !== undefined;
      if (pdfParams && args.maxMatches !== undefined) {
        return {
          content: [{ type: "text" as const, text: JSON.stringify({ error: "pdf-scoped-and-maxMatches-mutually-exclusive" }) }],
          isError: true,
        };
      }
      const cliArgs: string[] = ["grep", String(args.id), args.query];
      if (args.regex) cliArgs.push("--regex");
      if (args.pages) cliArgs.push("--pages", args.pages);
      cliArgs.push(
        ...flagsFromOptions({
          "--source": args.source,
          "--context-chars": args.contextChars,
          "--max-pages": args.maxPages,
          "--snippets-per-page": args.snippetsPerPage,
          "--max-matches": args.maxMatches,
        }),
      );
      return runCliAsTool(cliArgs);
    },
  );
}
