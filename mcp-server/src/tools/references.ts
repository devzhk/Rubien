import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { flagsFromOptions, runCliAsTool } from "../toolHelpers.js";

export function registerReferenceTools(server: McpServer): void {
  server.registerTool(
    "rubien_search_references",
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
    "rubien_list_references",
    {
      title: "List references",
      description:
        "List references with filters and sorting, or run a saved view. Returns ReferenceDTO[]. Use this for 'most recent', 'by author', 'by year range' queries. Pass `view` (a saved-view id from rubien_list_views) to run that view's persisted filter/sort config instead — `view` is mutually exclusive with the inline filter/sort params (limit/offset still apply).",
      inputSchema: {
        limit: z.number().int().nonnegative().optional()
          .describe("Maximum results (0 = all)"),
        offset: z.number().int().nonnegative().optional().describe("Skip first N"),
        view: z.number().int().optional()
          .describe("Saved view ID — rows filtered/sorted by that view. Mutually exclusive with the inline filter/sort params below. Discover ids via rubien_list_views."),
        tag: z.number().int().optional().describe("Filter by tag ID"),
        author: z.string().optional().describe("Filter by author name (fuzzy)"),
        yearFrom: z.number().int().optional(),
        yearTo: z.number().int().optional(),
        journal: z.string().optional().describe("Filter by journal name (fuzzy)"),
        type: z.string().optional().describe("Reference type, e.g. 'Journal Article'"),
        hasPdf: z.boolean().optional(),
        keyword: z.string().optional().describe("Keyword across title/abstract/notes"),
        readingStatus: z
          .string()
          .optional()
          .describe(
            "Filter by reading status. Validated live against the user-extensible Status options (case-sensitive) — see rubien_list_properties for the current set.",
          ),
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
          "--view": args.view,
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
    "rubien_get_reference",
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
    "rubien_create_reference",
    {
      title: "Create reference (one door: locator, BibTeX, or title)",
      description:
        "Create reference(s) — one door for every input. Pass exactly one of: `source` (ANY locator — DOI / arXiv / PMID / PMCID / ISBN, paper URL, PDF/Markdown file URL, local file path, or folder path; the CLI routes it), `bibtex` (inline BibTeX, can hold multiple entries), or `title` (minimal manual row). May return MULTIPLE items (multi-entry BibTeX, folders) and may return `status: 'existing'` instead of creating — the input matched an existing row (deduped by normalized DOI / PMID / PMCID / ISBN / URL / ISSN+title+year) and non-empty incoming fields were folded into it. Output envelope: `{ items: [{ reference?, status: 'created'|'existing'|'queued'|'failed', intakeId?, input, pdfDownload?, error? }], summary: {created, existing, queued, failed}, diagnostics? }`. Routing notes: an existing local path wins over an identifier-shaped string (escape a DOI as https://doi.org/…); a registered-host .pdf URL resolves metadata AND attaches the PDF (implied downloadPdf); an unregistered .pdf/.md URL is downloaded and imported directly. To fetch a PDF for a reference that already exists, use rubien_download_pdf instead.",
      inputSchema: {
        source: z
          .string()
          .optional()
          .describe(
            "Any locator: identifier (DOI/arXiv/PMID/PMCID/ISBN), paper URL, PDF/Markdown file URL, absolute file path, or folder path. Stdin ('-') is not supported over MCP.",
          ),
        bibtex: z
          .string()
          .optional()
          .describe("Inline BibTeX source (can hold multiple entries; persists per entry, continuing past entry failures)"),
        title: z.string().optional().describe("Title for a minimal manual entry"),
        downloadPdf: z
          .boolean()
          .optional()
          .describe(
            "Resolver routes only (identifier / paper-URL source). true = fetch the open-access PDF after resolution; false = explicitly skip (overrides the implied fetch on registered .pdf URLs); absent = the router decides. The reference is saved even if the fetch fails. Adds up to ~3min.",
          ),
        format: z
          .enum(["bib", "ris", "md"])
          .optional()
          .describe(
            "File/stdin routes only: format hint; disambiguates a folder holding both .bib and .md.",
          ),
        property: z
          .string()
          .optional()
          .describe("Folder route only: property to stamp on every imported reference (default: Tags)"),
        value: z
          .string()
          .optional()
          .describe("Folder route only: value to stamp on `property` (default: folder basename)"),
      },
      annotations: { readOnlyHint: false, destructiveHint: false },
    },
    async ({ source, bibtex, title, downloadPdf, format, property, value }) => {
      const inputs = [source, bibtex, title].filter((v) => v !== undefined);
      if (inputs.length !== 1) {
        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                error: "provide exactly one of source / bibtex / title",
              }),
            },
          ],
          isError: true,
        };
      }
      // Trim before comparing: the CLI trims the source, so a bare " - "
      // would otherwise slip past this guard and reach stdin routing (which
      // hangs over MCP — the wrapper closes the child's stdin).
      if (source?.trim() === "-") {
        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                error:
                  "stdin ('-') is not supported over MCP — pass a file path, URL, or identifier, or invoke rubien-cli directly",
              }),
            },
          ],
          isError: true,
        };
      }
      const args: string[] = ["add"];
      if (source !== undefined) args.push("--source", source);
      if (bibtex !== undefined) args.push("--bibtex", bibtex);
      if (title !== undefined) args.push("--title", title);
      // Tri-state: absent = router decides; the inversion pair makes
      // "explicitly false" representable (overrides implied fetch).
      if (downloadPdf === true) args.push("--download-pdf");
      else if (downloadPdf === false) args.push("--no-download-pdf");
      args.push(
        ...flagsFromOptions({
          "--format": format,
          "--property": property,
          "--value": value,
        }),
      );
      // Route-independent 300s: a thin wrapper can't pick per-route before
      // the CLI routes (max of identity-add 120-300s and import 180s).
      return runCliAsTool(args, { timeoutMs: 300_000 });
    },
  );

  server.registerTool(
    "rubien_update_reference",
    {
      title: "Update reference fields and property cells",
      description:
        "Modify an existing reference: metadata fields (pass only what changes), `clearFields` to null fields out, and/or `properties` — a cell payload editing built-in and custom property values in ONE atomic call. Payload keys are property names (exact, case-sensitive) or ids (digit-only strings); values: scalar = replace, array = replace multiSelect set, {add:[…], remove:[…]} = incremental multiSelect edit (idempotent), null = clear. For the built-in Tags property, values are stringified tag ids. This edits the VALUES on this reference — to create/rename/delete the choices themselves (options/tags), use rubien_create_option / rubien_update_option / rubien_delete_option. Unknown keys, read-only built-ins (Last Read, Read Count), and type mismatches fail the whole call with a structured error — nothing is partially applied.",
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
          .string()
          .optional()
          .describe(
            "New reading status. Validated live against the user-extensible Status options (case-sensitive).",
          ),
        clearFields: z.array(z.string()).optional()
          .describe("Field names to clear (set to NULL)."),
        properties: z
          .record(
            z.union([
              z.string(),
              z.number(),
              z.boolean(),
              z.null(),
              z.array(z.string()),
              z
                .object({
                  add: z.array(z.string()).optional(),
                  remove: z.array(z.string()).optional(),
                })
                .strict(),
            ]),
          )
          .optional()
          .describe(
            "Property-cell edits keyed by property name or id: scalar/array = replace, {add/remove} = incremental multiSelect edit, null = clear. Example: {\"Status\": \"Reading\", \"Tags\": {\"add\": [\"12\"]}, \"7\": [\"ml\", \"nlp\"], \"Themes\": null}",
          ),
      },
      annotations: { readOnlyHint: false, destructiveHint: true },
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
      if (args.clearFields) {
        for (const f of args.clearFields) flags.push("--clear-field", f);
      }
      // Forward even an empty `{}`: the CLI routes any `--properties` through
      // the unified applyReferenceEdit no-op path (writes nothing when the
      // payload is empty), whereas dropping it would fall to the legacy
      // update that unconditionally saves + notifies.
      if (args.properties !== undefined) {
        flags.push("--properties", JSON.stringify(args.properties));
      }
      return runCliAsTool(["update", String(args.id), ...flags]);
    },
  );

  server.registerTool(
    "rubien_delete_reference",
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
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
      },
    },
    // Always passes --force: the MCP client's permission layer is the user
    // confirmation point for destructive tools, not the CLI's TTY prompt.
    async ({ ids }) =>
      runCliAsTool(["delete", "--force", ...ids.map((n) => String(n))]),
  );
}
