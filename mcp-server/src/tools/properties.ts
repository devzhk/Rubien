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

/// Tags are exposed as the seeded built-in PropertyDefinition with
/// `defaultFieldKey == "tags"`. All operations below treat Tags as a regular
/// multiSelect property — `set` / `add_values` / `remove_values` accept tag
/// IDs (stringified), `add_option` creates a new Tag from a name + color,
/// `rename_option` / `delete_option` operate by tag ID. The retired
/// rubien_tags_* tool family folded into this surface.
function tagsContractNote(extra = ""): string {
  return (
    "For the built-in Tags property (defaultFieldKey == 'tags'): values are " +
    "tag IDs (stringified). Create new tags via rubien_properties_add_option " +
    "(value=name, color=hex)." +
    (extra ? " " + extra : "")
  );
}

export function registerPropertyTools(server: McpServer): void {
  server.registerTool(
    "rubien_properties_list",
    {
      title: "List property definitions (incl. Tags)",
      description:
        "List property definitions. Returns PropertyDefinitionDTO[] with options inlined: " +
        "{value, label, color}. For the built-in Tags property each option is one Tag row " +
        "(value = stringified tag id, label = name). " +
        "Pass `ids` and/or `names` to filter; selectors are unioned, exact case-sensitive on names, " +
        "and override `visible`. Unresolved selectors fail loudly with an `unresolved-selectors` error envelope.",
      inputSchema: {
        ids: z
          .array(z.string())
          .optional()
          .describe("Repeatable property IDs to include. Errors if any ID does not exist."),
        names: z
          .array(z.string())
          .optional()
          .describe(
            "Repeatable property names (exact, case-sensitive) to include. Errors if any name does not exist.",
          ),
        visible: z
          .boolean()
          .optional()
          .describe("Restrict to user-visible properties. Ignored when ids/names are supplied."),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ ids, names, visible }) => {
      const args: string[] = ["properties"];
      if (visible) args.push("--visible");
      for (const id of ids ?? []) args.push("--id", id);
      for (const n of names ?? []) args.push("--name", n);
      return runCliAsTool(args);
    },
  );

  server.registerTool(
    "rubien_properties_create",
    {
      title: "Create custom property",
      description:
        "Create a new custom property definition. To create a new tag instead, use rubien_properties_add_option against the built-in Tags property.",
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
        "Remove a property definition and all its values on references. Cannot delete default/built-in properties (Tags included — use rubien_properties_delete_option to remove individual tags).",
      inputSchema: { id: z.string() },
      annotations: { destructiveHint: true },
    },
    async ({ id }) =>
      runCliAsTool(["properties", "--delete", id]),
  );

  server.registerTool(
    "rubien_properties_rename",
    {
      title: "Rename custom property",
      description:
        "Change a property's display name. Built-in properties (incl. Tags) cannot be renamed.",
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
      title: "Add option to select property (creates a Tag for the Tags property)",
      description:
        "Append an option to a singleSelect/multiSelect property. " +
        "For the built-in Tags property, this creates a new Tag row with `value` as the tag name " +
        "and `color` as the tag color; the returned option's `value` is the new tag's stable id.",
      inputSchema: {
        id: z.string().describe("Property ID"),
        value: z
          .string()
          .describe("Option label (or, for Tags, the new tag's display name)"),
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
    "rubien_properties_rename_option",
    {
      title: "Rename a select option (renames the underlying Tag for Tags)",
      description:
        "Rename an existing option on a singleSelect/multiSelect property and bulk-update affected references. " +
        "For Tags: `from` is the stringified tag id (identity-stable), `to` is the new display name. " +
        "Pivots are not touched. For other multiSelect: rewrites the JSON arrays in every affected propertyValue row.",
      inputSchema: {
        id: z.string().describe("Property ID"),
        from: z.string().describe("Existing option value (tag id for Tags)"),
        to: z.string().describe("New option value (new tag name for Tags)"),
      },
    },
    async ({ id, from, to }) =>
      runCliAsTool([
        "properties",
        "--rename-option",
        "--id",
        id,
        "--from",
        from,
        "--to",
        to,
      ]),
  );

  server.registerTool(
    "rubien_properties_delete_option",
    {
      title: "Delete a select option (deletes the underlying Tag for Tags)",
      description:
        "Remove a select option from a property. " + tagsContractNote(
          "For Tags, deleting a tag with attached references requires `replaceWith` (the stringified id of another tag) — affected references are re-tagged before the old tag is removed. Without `replaceWith`, in-use options surface an `optionInUse` error.",
        ),
      inputSchema: {
        id: z.string().describe("Property ID"),
        value: z.string().describe("Option value to delete (tag id for Tags)"),
        replaceWith: z
          .string()
          .optional()
          .describe(
            "Replacement option value for affected rows (required when the option is in use)",
          ),
      },
      annotations: { destructiveHint: true },
    },
    async ({ id, value, replaceWith }) =>
      runCliAsTool([
        "properties",
        "--delete-option",
        "--id",
        id,
        "--value",
        value,
        ...flagsFromOptions({ "--replace-with": replaceWith }),
      ]),
  );

  server.registerTool(
    "rubien_properties_set",
    {
      title: "Set property value on reference (replace semantics)",
      description:
        "Assign a property value to a reference using replace semantics. For multiSelect (incl. Tags), pass comma-separated values — the existing set is overwritten. " +
        "Use rubien_properties_add_values / rubien_properties_remove_values for incremental edits. " +
        tagsContractNote(),
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
    "rubien_properties_add_values",
    {
      title: "Add values to a multiSelect property (additive, idempotent)",
      description:
        "Append one or more values to a multiSelect property on a reference without disturbing existing selections. " +
        "Idempotent: re-adding a present value is a no-op (no sync churn). " +
        tagsContractNote("For Tags this inserts ReferenceTag pivots."),
      inputSchema: {
        reference: z.number().int(),
        id: z.string().describe("Property ID"),
        value: z.string().describe("Comma-separated values (tag IDs for Tags)"),
      },
    },
    async ({ reference, id, value }) =>
      runCliAsTool([
        "properties",
        "--set",
        "--add-value",
        "--reference",
        String(reference),
        "--id",
        id,
        "--value",
        value,
      ]),
  );

  server.registerTool(
    "rubien_properties_remove_values",
    {
      title: "Remove values from a multiSelect property (subtractive, idempotent)",
      description:
        "Remove one or more values from a multiSelect property on a reference without disturbing other selections. " +
        "Idempotent: removing an absent value is a no-op. " +
        tagsContractNote("For Tags this deletes ReferenceTag pivots."),
      inputSchema: {
        reference: z.number().int(),
        id: z.string().describe("Property ID"),
        value: z.string().describe("Comma-separated values (tag IDs for Tags)"),
      },
      annotations: { destructiveHint: true },
    },
    async ({ reference, id, value }) =>
      runCliAsTool([
        "properties",
        "--set",
        "--remove-value",
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
      description:
        "Remove a property value from a reference. " +
        tagsContractNote("For Tags this removes all of the reference's tag assignments."),
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
