import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { flagsFromOptions, runCliAsTool } from "../toolHelpers.js";

export function registerViewTools(server: McpServer): void {
  server.registerTool(
    "rubien_views_list",
    {
      title: "List saved views",
      description:
        "List saved database views (persisted filter/sort/group configurations). Returns DatabaseViewDTO[].",
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () => runCliAsTool(["views"]),
  );

  server.registerTool(
    "rubien_views_create",
    {
      title: "Create saved view",
      description:
        "Create a new saved view. filters / sorts / groupBy must be valid JSON matching the view configuration schema (mirrors what the GUI editor produces). Use rubien_views_list first to see the shape.",
      inputSchema: {
        name: z.string(),
        filters: z
          .string()
          .optional()
          .describe("JSON string: ViewFilter[]"),
        sorts: z
          .string()
          .optional()
          .describe("JSON string: ViewSort[]"),
        groupBy: z
          .string()
          .optional()
          .describe("JSON string: GroupConfig"),
      },
    },
    async ({ name, filters, sorts, groupBy }) =>
      runCliAsTool(
        [
          "views",
          "--create",
          ...flagsFromOptions({
            "--name": name,
            "--filters": filters,
            "--sorts": sorts,
            "--group-by": groupBy,
          }),
        ],
      ),
  );

  server.registerTool(
    "rubien_views_delete",
    {
      title: "Delete saved view",
      description: "Remove a saved view by ID.",
      inputSchema: { id: z.number().int() },
      annotations: { destructiveHint: true },
    },
    async ({ id }) =>
      runCliAsTool(["views", "--delete", "--id", String(id)]),
  );

  server.registerTool(
    "rubien_views_rename",
    {
      title: "Rename saved view",
      description: "Change a saved view's name.",
      inputSchema: { id: z.number().int(), name: z.string() },
    },
    async ({ id, name }) =>
      runCliAsTool([
        "views",
        "--rename",
        "--id",
        String(id),
        "--name",
        name,
      ]),
  );

  server.registerTool(
    "rubien_views_query",
    {
      title: "Query a saved view",
      description:
        "Run a saved view's filter/sort config and return the matching references. Equivalent to opening the view in the GUI.",
      inputSchema: {
        id: z.number().int(),
        limit: z
          .number()
          .int()
          .positive()
          .max(1000)
          .optional()
          .describe("Result cap (default 100)"),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ id, limit }) =>
      runCliAsTool([
        "views",
        "--query",
        "--id",
        String(id),
        ...flagsFromOptions({ "--limit": limit }),
      ]),
  );
}
