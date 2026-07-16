import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { runCliAsTool } from "../toolHelpers.js";

export function registerActivityTools(server: McpServer): void {
  server.registerTool(
    "rubien_reading_activity",
    {
      title: "Reading activity",
      description:
        "Return Rubien's tracked reading and Assistant activity. A paper-day qualifies after at least 60 estimated foreground-reader seconds; only yearActivity is limited by year.",
      inputSchema: {
        year: z.number().int().min(1970).max(9999).optional(),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ year }) => {
      const args = ["stats"];
      if (year !== undefined) args.push("--year", String(year));
      return runCliAsTool(args);
    },
  );
}
