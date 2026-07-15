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
/// `defaultFieldKey == "tags"`. The option tools below treat Tags options as
/// Tag rows — `create_option` creates a new Tag from a name + color,
/// `update_option` / `delete_option` address tags by stringified tag ID.
/// ASSIGNING values to a reference is rubien_update_reference's `properties`
/// payload, not these tools.
function tagsContractNote(extra = ""): string {
  return (
    "For the built-in Tags property (defaultFieldKey == 'tags'): options are " +
    "Tag rows addressed by stringified tag ID. Create new tags via " +
    "rubien_create_option (value=name, color=hex)." +
    (extra ? " " + extra : "")
  );
}

/// The column-vs-cell boundary, stated on every option tool: these tools
/// edit the CHOICES; update_reference edits a reference's chosen VALUES.
const assignmentPointer =
  " (These tools edit the available choices themselves. To assign/unassign values on a specific reference, use rubien_update_reference's `properties` payload.)";

export function registerPropertyTools(server: McpServer): void {
  server.registerTool(
    "rubien_list_properties",
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
    "rubien_create_property",
    {
      title: "Create custom property (column)",
      description:
        "Create a new custom property definition (a column). All-digit names are rejected — they would shadow id selectors in rubien_update_reference's payload. To create a new tag instead, use rubien_create_option against the built-in Tags property." +
        assignmentPointer,
      inputSchema: {
        name: z.string().describe("Property name (must not be all digits)"),
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
    "rubien_update_property",
    {
      title: "Update property (rename and/or visibility)",
      description:
        "Update a property definition: rename it and/or change its UI visibility, in one transaction. At least one of `name` / `visible` is required. Built-in properties (incl. Tags) cannot be renamed; visibility can be changed on any property. All-digit names are rejected.",
      inputSchema: {
        id: z.string().describe("Property ID"),
        name: z.string().optional().describe("New display name"),
        visible: z.boolean().optional().describe("Show (true) or hide (false) in the app UI"),
      },
    },
    async ({ id, name, visible }) => {
      const args = ["properties", "--update", "--id", id];
      if (name !== undefined) args.push("--name", name);
      if (visible !== undefined) args.push("--set-visible", String(visible));
      return runCliAsTool(args);
    },
  );

  server.registerTool(
    "rubien_delete_property",
    {
      title: "Delete custom property",
      description:
        "Remove a property definition and all its values on references. Cannot delete default/built-in properties (Tags included — use rubien_delete_option to remove individual tags).",
      inputSchema: { id: z.string() },
      annotations: { destructiveHint: true },
    },
    async ({ id }) =>
      runCliAsTool(["properties", "--delete", id]),
  );

  server.registerTool(
    "rubien_create_option",
    {
      title: "Create select option (creates a Tag for the Tags property)",
      description:
        "Append an option to a singleSelect/multiSelect property. " +
        "For the built-in Tags property, this creates a new Tag row with `value` as the tag name " +
        "and `color` as the tag color; the returned option's `value` is the new tag's stable id." +
        assignmentPointer,
      inputSchema: {
        propertyId: z.string().describe("Property ID"),
        value: z
          .string()
          .describe("Option label (or, for Tags, the new tag's display name)"),
        color: z.string().optional().describe("Optional hex color (#RRGGBB)"),
      },
    },
    async ({ propertyId, value, color }) =>
      runCliAsTool([
        "properties",
        "--add-option",
        "--id",
        propertyId,
        ...flagsFromOptions({ "--value": value, "--color": color }),
      ]),
  );

  server.registerTool(
    "rubien_update_option",
    {
      title: "Update a select option (rename and/or recolor)",
      description:
        "Rename and/or recolor an existing option on a singleSelect/multiSelect property, in one transaction. `option` addresses the option by its original identity; at least one of `name` / `color` is required. Renames bulk-update affected references. " +
        "For Tags: `option` is the stringified tag id (identity-stable), `name` is the new display name, recolor updates the Tag row. `color` accepts #RRGGBB only. The built-in Type property's options are fully immutable (recolor included)." +
        assignmentPointer,
      inputSchema: {
        propertyId: z.string().describe("Property ID"),
        option: z.string().describe("Existing option value (stringified tag id for Tags)"),
        name: z.string().optional().describe("New option value (new tag name for Tags)"),
        color: z.string().optional().describe("New hex color (#RRGGBB)"),
      },
    },
    async ({ propertyId, option, name, color }) =>
      runCliAsTool([
        "properties",
        "--update-option",
        "--id",
        propertyId,
        "--option",
        option,
        ...flagsFromOptions({ "--to": name, "--color": color }),
      ]),
  );

  server.registerTool(
    "rubien_delete_option",
    {
      title: "Delete a select option (deletes the underlying Tag for Tags)",
      description:
        "Remove a select option from a property. " + tagsContractNote(
          "For Tags, deleting a tag with attached references requires `replaceWith` (the stringified id of another tag) — affected references are re-tagged before the old tag is removed. Without `replaceWith`, in-use options surface an `optionInUse` error.",
        ) +
        " To delete an in-use option without migrating, set `clearInUse: true` — affected references have the option cleared from their value (singleSelect loses its value; multiSelect drops just this option). `clearInUse` and `replaceWith` are mutually exclusive." +
        assignmentPointer,
      inputSchema: {
        propertyId: z.string().describe("Property ID"),
        value: z.string().describe("Option value to delete (stringified tag id for Tags)"),
        replaceWith: z
          .string()
          .optional()
          .describe(
            "Replacement option value for affected rows (required when the option is in use)",
          ),
        clearInUse: z
          .boolean()
          .optional()
          .describe(
            "Clear the option from affected references instead of migrating. Mutually exclusive with replaceWith.",
          ),
      },
      annotations: { destructiveHint: true },
    },
    async ({ propertyId, value, replaceWith, clearInUse }) =>
      runCliAsTool([
        "properties",
        "--delete-option",
        "--id",
        propertyId,
        "--value",
        value,
        ...flagsFromOptions({
          "--replace-with": replaceWith,
          "--clear-in-use": clearInUse,
        }),
      ]),
  );
}
