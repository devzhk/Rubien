import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerReferenceTools } from "./tools/references.js";
import { registerCitationTools } from "./tools/citations.js";
import { registerIOTools } from "./tools/io.js";
import { registerTagTools } from "./tools/tags.js";
import { registerPropertyTools } from "./tools/properties.js";
import { registerViewTools } from "./tools/views.js";
import { registerAnnotationTools } from "./tools/annotations.js";
import { registerSyncTools } from "./tools/sync.js";
import { registerPdfTools } from "./tools/pdf.js";

export const SERVER_INFO = {
  name: "rubien-mcp-server",
  version: "0.1.0",
} as const;

export function buildServer(): McpServer {
  const server = new McpServer(SERVER_INFO, {
    capabilities: { tools: {} },
  });

  registerReferenceTools(server);
  registerCitationTools(server);
  registerIOTools(server);
  registerTagTools(server);
  registerPropertyTools(server);
  registerViewTools(server);
  registerAnnotationTools(server);
  registerPdfTools(server);
  registerSyncTools(server);

  return server;
}
