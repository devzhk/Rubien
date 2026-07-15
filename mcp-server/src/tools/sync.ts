import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { runCliAsTool } from "../toolHelpers.js";

export function registerSyncTools(server: McpServer): void {
  server.registerTool(
    "rubien_get_sync_status",
    {
      title: "CloudKit sync status",
      description:
        "Report the current CloudKit sync state without starting the engine. Shows entitlement presence, iCloud account availability, dirty counts per entity type, tombstones, and engine state snapshot.",
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () => runCliAsTool(["sync", "status"]),
  );
}
