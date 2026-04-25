import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { flagsFromOptions, runCliAsTool } from "../toolHelpers.js";

const PROPERTY_TYPES = [
  "string",
  "url",
  "number",
  "singleSelect",
  "multiSelect",
  "date",
  "checkbox",
] as const;

export function registerPropertyTools(server: McpServer): void {
  server.registerTool(
    "rubien_properties_list",
    {
      title: "List custom properties",
      description:
        "List all property definitions (default + user-defined). Returns PropertyDefinitionDTO[].",
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () => runCliAsTool(["properties"]),
  );

  server.registerTool(
    "rubien_properties_create",
    {
      title: "Create custom property",
      description: "Create a new custom property definition.",
      inputSchema: {
        name: z.string(),
        type: z.enum(PROPERTY_TYPES),
        options: z
          .string()
          .optional()
          .describe(
            "For singleSelect/multiSelect, comma-separated option labels.",
          ),
      },
    },
    async ({ name, type, options }) =>
      runCliAsTool(
        [
          "properties",
          "--create",
          ...flagsFromOptions({
            "--name": name,
            "--type": type,
            "--options": options,
          }),
        ],
      ),
  );

  server.registerTool(
    "rubien_properties_delete",
    {
      title: "Delete custom property",
      description:
        "Remove a property definition and all its values on references. Cannot delete default/built-in properties.",
      inputSchema: { id: z.string() },
      annotations: { destructiveHint: true },
    },
    async ({ id }) =>
      runCliAsTool(["properties", "--delete", "--id", id]),
  );

  server.registerTool(
    "rubien_properties_rename",
    {
      title: "Rename custom property",
      description: "Change a property's display name.",
      inputSchema: { id: z.string(), name: z.string() },
    },
    async ({ id, name }) =>
      runCliAsTool(["properties", "--rename", "--id", id, "--name", name]),
  );

  server.registerTool(
    "rubien_properties_show",
    {
      title: "Show property in UI",
      description: "Mark a property as visible in the app UI.",
      inputSchema: { id: z.string() },
    },
    async ({ id }) =>
      runCliAsTool(["properties", "--show", "--id", id]),
  );

  server.registerTool(
    "rubien_properties_hide",
    {
      title: "Hide property in UI",
      description: "Mark a property as hidden in the app UI.",
      inputSchema: { id: z.string() },
    },
    async ({ id }) =>
      runCliAsTool(["properties", "--hide", "--id", id]),
  );

  server.registerTool(
    "rubien_properties_add_option",
    {
      title: "Add option to select property",
      description:
        "Append an option to a singleSelect/multiSelect property.",
      inputSchema: {
        id: z.string().describe("Property ID"),
        value: z.string().describe("Option label"),
        color: z.string().optional().describe("Optional hex color"),
      },
    },
    async ({ id, value, color }) =>
      runCliAsTool([
        "properties",
        "--add-option",
        "--id",
        id,
        ...flagsFromOptions({ "--value": value, "--color": color }),
      ]),
  );

  server.registerTool(
    "rubien_properties_set",
    {
      title: "Set property value on reference",
      description:
        "Assign a property value to a reference. For multiSelect, pass comma-separated values.",
      inputSchema: {
        reference: z.number().int(),
        id: z.string().describe("Property ID"),
        value: z.string(),
      },
    },
    async ({ reference, id, value }) =>
      runCliAsTool([
        "properties",
        "--set",
        "--reference",
        String(reference),
        "--id",
        id,
        "--value",
        value,
      ]),
  );

  server.registerTool(
    "rubien_properties_clear",
    {
      title: "Clear property value on reference",
      description: "Remove a property value from a reference.",
      inputSchema: {
        reference: z.number().int(),
        id: z.string().describe("Property ID"),
      },
      annotations: { destructiveHint: true },
    },
    async ({ reference, id }) =>
      runCliAsTool([
        "properties",
        "--clear",
        "--reference",
        String(reference),
        "--id",
        id,
      ]),
  );
}
