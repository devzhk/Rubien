import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { flagsFromOptions, runCliAsTool } from "../toolHelpers.js";

export function registerReferenceTools(server: McpServer): void {
  server.registerTool(
    "rubien_search",
    {
      title: "Full-text search",
      description:
        "Full-text search across the Rubien library. By default searches all 12 indexed FTS columns (title, authors, abstract, notes, journal, doi, publisher, isbn, issn, institution, webContent, siteName). Use `in` to constrain to specific columns — e.g. `in: ['title','abstract']` for topic searches that should ignore notes/web content. Use `op: 'or'` when looking for any of several alternative terms instead of all of them. Returns an array of ReferenceDTO.",
      inputSchema: {
        query: z.string().describe("Search query (space-separated tokens)"),
        limit: z.number().int().positive().max(500).optional()
          .describe("Maximum results (default 20)"),
        in: z
          .array(
            z.enum([
              "title",
              "abstract",
              "notes",
              "authors",
              "journal",
              "doi",
              "publisher",
              "isbn",
              "issn",
              "institution",
              "webContent",
              "siteName",
            ]),
          )
          .optional()
          .describe(
            "Restrict FTS to these columns (default: all 12 indexed columns).",
          ),
        op: z
          .enum(["and", "or"])
          .optional()
          .describe(
            "Combine multiple query tokens with AND (every token must match) or OR (any token). Default: and.",
          ),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ query, limit, in: inFields, op }) =>
      runCliAsTool([
        "search",
        query,
        ...flagsFromOptions({
          "--limit": limit,
          "--in": inFields && inFields.length > 0 ? inFields.join(",") : undefined,
          "--op": op,
        }),
      ]),
  );

  server.registerTool(
    "rubien_list",
    {
      title: "List references",
      description:
        "List references with filters and sorting. Returns ReferenceDTO[]. Use this for 'most recent', 'by author', 'by year range' queries.",
      inputSchema: {
        limit: z.number().int().nonnegative().optional()
          .describe("Maximum results (0 = all)"),
        offset: z.number().int().nonnegative().optional().describe("Skip first N"),
        tag: z.number().int().optional().describe("Filter by tag ID"),
        author: z.string().optional().describe("Filter by author name (fuzzy)"),
        yearFrom: z.number().int().optional(),
        yearTo: z.number().int().optional(),
        journal: z.string().optional().describe("Filter by journal name (fuzzy)"),
        type: z.string().optional().describe("Reference type, e.g. 'Journal Article'"),
        hasPdf: z.boolean().optional(),
        keyword: z.string().optional().describe("Keyword across title/abstract/notes"),
        readingStatus: z
          .enum(["unread", "reading", "skimmed", "read"])
          .optional(),
        sortBy: z
          .enum(["year", "dateAdded", "title"])
          .optional(),
        asc: z.boolean().optional().describe("Sort ascending (default is descending)"),
      },
      annotations: { readOnlyHint: true },
    },
    async (args) =>
      runCliAsTool([
        "list",
        ...flagsFromOptions({
          "--limit": args.limit,
          "--offset": args.offset,
          "--tag": args.tag,
          "--author": args.author,
          "--year-from": args.yearFrom,
          "--year-to": args.yearTo,
          "--journal": args.journal,
          "--type": args.type,
          "--has-pdf": args.hasPdf,
          "--keyword": args.keyword,
          "--reading-status": args.readingStatus,
          "--sort-by": args.sortBy,
          "--asc": args.asc,
        }),
      ]),
  );

  server.registerTool(
    "rubien_get",
    {
      title: "Get reference by ID",
      description: "Fetch a single reference by ID. Returns ReferenceDTO.",
      inputSchema: {
        id: z.number().int().describe("Reference ID"),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ id }) => runCliAsTool(["get", String(id)]),
  );

  server.registerTool(
    "rubien_add",
    {
      title: "Add reference",
      description:
        "Create a new reference. Choose one input method: identifier (DOI/arXiv/PMID/ISBN, triggers metadata lookup, slow), bibtex (inline BibTeX/BibLaTeX string, may return array for multi-entry), or title (minimal manual entry).",
      inputSchema: {
        method: z.enum(["identifier", "bibtex", "title"]),
        value: z
          .string()
          .describe(
            "The identifier / BibTeX source / title, depending on method.",
          ),
      },
    },
    async ({ method, value }) => {
      const flag =
        method === "identifier"
          ? "--identifier"
          : method === "bibtex"
            ? "--bibtex"
            : "--title";
      return runCliAsTool(["add", flag, value], {
        timeoutMs: method === "identifier" ? 120_000 : undefined,
      });
    },
  );

  server.registerTool(
    "rubien_update",
    {
      title: "Update reference fields",
      description:
        "Modify fields on an existing reference. Pass only the fields to change. Use `clearField` (repeatable) to null out a field entirely.",
      inputSchema: {
        id: z.number().int(),
        title: z.string().optional(),
        year: z.number().int().optional(),
        authors: z.string().optional(),
        type: z.string().optional(),
        journal: z.string().optional(),
        volume: z.string().optional(),
        issue: z.string().optional(),
        pages: z.string().optional(),
        doi: z.string().optional(),
        url: z.string().optional(),
        abstract: z.string().optional(),
        notes: z.string().optional(),
        publisher: z.string().optional(),
        isbn: z.string().optional(),
        issn: z.string().optional(),
        language: z.string().optional(),
        edition: z.string().optional(),
        readingStatus: z
          .enum(["unread", "reading", "skimmed", "read"])
          .optional(),
        clearField: z.array(z.string()).optional()
          .describe("Field names to clear (set to NULL). Repeatable."),
      },
      annotations: { destructiveHint: true },
    },
    async (args) => {
      const flags = flagsFromOptions({
        "--title": args.title,
        "--year": args.year,
        "--authors": args.authors,
        "--type": args.type,
        "--journal": args.journal,
        "--volume": args.volume,
        "--issue": args.issue,
        "--pages": args.pages,
        "--doi": args.doi,
        "--url": args.url,
        "--abstract": args.abstract,
        "--notes": args.notes,
        "--publisher": args.publisher,
        "--isbn": args.isbn,
        "--issn": args.issn,
        "--language": args.language,
        "--edition": args.edition,
        "--reading-status": args.readingStatus,
      });
      if (args.clearField) {
        for (const f of args.clearField) flags.push("--clear-field", f);
      }
      return runCliAsTool(["update", String(args.id), ...flags]);
    },
  );

  server.registerTool(
    "rubien_delete",
    {
      title: "Delete references",
      description:
        "Permanently delete references by ID. Accepts one or many IDs. Returns { deleted: 'id1,id2,...' }.",
      inputSchema: {
        ids: z
          .array(z.number().int())
          .min(1)
          .describe("One or more reference IDs to delete"),
      },
      annotations: { destructiveHint: true, idempotentHint: false },
    },
    // Always passes --force: the MCP client's permission layer is the user
    // confirmation point for destructive tools, not the CLI's TTY prompt.
    async ({ ids }) =>
      runCliAsTool(["delete", "--force", ...ids.map((n) => String(n))]),
  );
}
