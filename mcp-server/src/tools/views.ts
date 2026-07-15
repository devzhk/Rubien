import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { flagsFromOptions, runCliAsTool } from "../toolHelpers.js";

export function registerViewTools(server: McpServer): void {
  server.registerTool(
    "rubien_list_views",
    {
      title: "List saved views",
      description:
        "List saved database views (persisted filter/sort/group configurations). Returns DatabaseViewDTO[]. To run a view (get its matching references), pass its id as `view` to rubien_list_references.",
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () => runCliAsTool(["views"]),
  );

  server.registerTool(
    "rubien_create_view",
    {
      title: "Create saved view",
      description:
        "Create a new saved view. filters / sorts / groupBy must be valid JSON matching the view configuration schema (mirrors what the GUI editor produces). Use rubien_list_views first to see the shape.",
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
      annotations: { readOnlyHint: false, destructiveHint: false },
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
    "rubien_update_view",
    {
      title: "Update saved view (rename)",
      description: "Change a saved view's name.",
      inputSchema: { id: z.number().int(), name: z.string() },
      annotations: { readOnlyHint: false, destructiveHint: false },
    },
    async ({ id, name }) =>
      runCliAsTool([
        "views",
        "--rename",
        String(id),
        "--name",
        name,
      ]),
  );

  server.registerTool(
    "rubien_delete_view",
    {
      title: "Delete saved view",
      description: "Remove a saved view by ID.",
      inputSchema: { id: z.number().int() },
      annotations: { readOnlyHint: false, destructiveHint: true },
    },
    // NB: `--delete` takes the id as its value (`views --delete <id>`) — the
    // 0.2.0 wrapper's `--delete --id <id>` form never parsed.
    async ({ id }) =>
      runCliAsTool(["views", "--delete", String(id)]),
  );
}
