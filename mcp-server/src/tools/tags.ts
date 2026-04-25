import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { flagsFromOptions, runCliAsTool } from "../toolHelpers.js";

export function registerTagTools(server: McpServer): void {
  server.registerTool(
    "rubien_tags_list",
    {
      title: "List tags",
      description: "List all tags. Returns [{ id, name, color }].",
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () => runCliAsTool(["tags"]),
  );

  server.registerTool(
    "rubien_tags_create",
    {
      title: "Create tag",
      description: "Create a new tag.",
      inputSchema: {
        name: z.string().describe("Tag name (unique)"),
        color: z
          .string()
          .optional()
          .describe("Hex color (e.g. '#007AFF'). Defaults to blue."),
      },
    },
    async ({ name, color }) =>
      runCliAsTool(
        [
          "tags",
          "--create",
          ...flagsFromOptions({ "--name": name, "--color": color }),
        ],
      ),
  );

  server.registerTool(
    "rubien_tags_delete",
    {
      title: "Delete tag",
      description: "Delete a tag by ID. References keep their other tags.",
      inputSchema: { id: z.number().int() },
      annotations: { destructiveHint: true },
    },
    async ({ id }) => runCliAsTool(["tags", "--delete", "--id", String(id)]),
  );

  server.registerTool(
    "rubien_tags_rename",
    {
      title: "Rename tag",
      description: "Rename an existing tag.",
      inputSchema: {
        id: z.number().int(),
        name: z.string().describe("New tag name"),
      },
    },
    async ({ id, name }) =>
      runCliAsTool(["tags", "--rename", "--id", String(id), "--name", name]),
  );

  server.registerTool(
    "rubien_tags_assign",
    {
      title: "Assign tags to reference",
      description:
        "Assign one or more tag IDs to a reference. Does not clear existing tags — use rubien_tags_remove for that.",
      inputSchema: {
        reference: z.number().int().describe("Reference ID"),
        tags: z
          .array(z.number().int())
          .min(1)
          .describe("Tag IDs to assign"),
      },
    },
    async ({ reference, tags }) =>
      runCliAsTool([
        "tags",
        "--assign",
        "--reference",
        String(reference),
        "--tags",
        tags.join(","),
      ]),
  );

  server.registerTool(
    "rubien_tags_remove",
    {
      title: "Remove tags from reference",
      description: "Remove one or more tag assignments from a reference.",
      inputSchema: {
        reference: z.number().int().describe("Reference ID"),
        tags: z
          .array(z.number().int())
          .min(1)
          .describe("Tag IDs to unassign"),
      },
      annotations: { destructiveHint: true },
    },
    async ({ reference, tags }) =>
      runCliAsTool([
        "tags",
        "--remove-tags",
        "--reference",
        String(reference),
        "--tags",
        tags.join(","),
      ]),
  );
}
