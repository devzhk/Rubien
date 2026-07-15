import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerReferenceTools } from "./tools/references.js";
import { registerCitationTools } from "./tools/citations.js";
import { registerIOTools } from "./tools/io.js";
import { registerPropertyTools } from "./tools/properties.js";
import { registerViewTools } from "./tools/views.js";
import { registerSyncTools } from "./tools/sync.js";
import { registerPdfTools } from "./tools/pdf.js";
import { registerReadTools } from "./tools/read.js";

export const SERVER_INFO = {
  name: "rubien-mcp-server",
  version: "0.3.0",
} as const;

export function buildServer(): McpServer {
  const server = new McpServer(SERVER_INFO, {
    capabilities: { tools: {} },
  });

  registerReferenceTools(server);
  registerCitationTools(server);
  registerIOTools(server);
  // Tags are exposed through the `properties` family against the built-in
  // Tags PropertyDefinition (defaultFieldKey == "tags"). The standalone
  // rubien_tags_* tool family was retired — see properties.ts.
  registerPropertyTools(server);
  registerViewTools(server);
  registerPdfTools(server);
  registerReadTools(server);
  registerSyncTools(server);

  return server;
}
